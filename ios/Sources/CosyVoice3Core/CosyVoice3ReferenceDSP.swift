// CosyVoice3ReferenceDSP.swift
// Requirement: native spectral frontends matching Whisper128, Kaldi80/CAMPPlus and Matcha80 prompt-mel preprocessing.
import Accelerate
import CoreML
import Foundation

enum CosyVoice3ReferenceDSPError: Error {
    case invalidFilterBank(String)
    case insufficientSamples(Int)
    case dftUnavailable(Int)
}

struct CosyVoice3MelBank: Sendable {
    let rows: Int
    let columns: Int
    let values: [Float]

    init(url: URL, rows: Int, columns: Int) throws {
        let data = try Data(contentsOf: url)
        guard data.count == rows * columns * MemoryLayout<Float>.size else {
            throw CosyVoice3ReferenceDSPError.invalidFilterBank(url.lastPathComponent)
        }
        self.rows = rows
        self.columns = columns
        self.values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func project(_ spectrum: [Float]) -> [Float] {
        precondition(spectrum.count == columns)
        var result = [Float](repeating: 0, count: rows)
        values.withUnsafeBufferPointer { matrix in
            spectrum.withUnsafeBufferPointer { vector in
                result.withUnsafeMutableBufferPointer { output in
                    cblas_sgemv(
                        CblasRowMajor, CblasNoTrans,
                        Int32(rows), Int32(columns),
                        1, matrix.baseAddress!, Int32(columns),
                        vector.baseAddress!, 1,
                        0, output.baseAddress!, 1
                    )
                }
            }
        }
        return result
    }
}

struct CosyVoice3Spectrum {
    static func frames(
        samples: [Float],
        nFFT: Int,
        hop: Int,
        window: [Float],
        reflectPad: Int = 0,
        dropLastFrame: Bool = false,
        power: Bool
    ) throws -> [[Float]] {
        let padded = reflectPad > 0 ? reflect(samples, by: reflectPad) : samples
        guard padded.count >= nFFT else { throw CosyVoice3ReferenceDSPError.insufficientSamples(padded.count) }
        let count0 = 1 + (padded.count - nFFT) / hop
        let frameCount = max(0, count0 - (dropLastFrame ? 1 : 0))
        let dft: vDSP.DiscreteFourierTransform<Float>
        do {
            dft = try vDSP.DiscreteFourierTransform(
                previous: nil,
                count: nFFT,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Float.self
            )
        } catch {
            throw CosyVoice3ReferenceDSPError.dftUnavailable(nFFT)
        }
        let zeros = [Float](repeating: 0, count: nFFT)
        var input = [Float](repeating: 0, count: nFFT)
        var real = [Float](repeating: 0, count: nFFT)
        var imag = [Float](repeating: 0, count: nFFT)
        var output = [[Float]]()
        output.reserveCapacity(frameCount)
        for frameIndex in 0..<frameCount {
            let start = frameIndex * hop
            for i in 0..<nFFT { input[i] = padded[start + i] * window[i] }
            dft.transform(inputReal: input, inputImaginary: zeros, outputReal: &real, outputImaginary: &imag)
            var bins = [Float](repeating: 0, count: nFFT / 2 + 1)
            for k in bins.indices {
                let magnitude2 = real[k] * real[k] + imag[k] * imag[k]
                bins[k] = power ? magnitude2 : sqrt(magnitude2 + 1e-9)
            }
            output.append(bins)
        }
        return output
    }

    static func periodicHann(_ count: Int) -> [Float] {
        (0..<count).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(count)) }
    }

    static func povey(_ count: Int) -> [Float] {
        (0..<count).map {
            pow(0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(count - 1)), 0.85)
        }
    }

    private static func reflect(_ values: [Float], by pad: Int) -> [Float] {
        precondition(values.count > pad)
        var result = [Float]()
        result.reserveCapacity(values.count + 2 * pad)
        for i in stride(from: pad, through: 1, by: -1) { result.append(values[i]) }
        result.append(contentsOf: values)
        let last = values.count - 1
        for i in 1...pad { result.append(values[last - i]) }
        return result
    }
}

struct CosyVoice3ReferenceDSP: Sendable {
    let whisper128: CosyVoice3MelBank
    let kaldi80: CosyVoice3MelBank
    let matcha80: CosyVoice3MelBank

    func whisperFeatures(_ samples: [Float]) throws -> MLMultiArray {
        let spectra = try CosyVoice3Spectrum.frames(
            samples: samples, nFFT: 400, hop: 160,
            window: CosyVoice3Spectrum.periodicHann(400),
            reflectPad: 200, dropLastFrame: true, power: true
        )
        let frames = spectra.count
        var projected = [[Float]](); projected.reserveCapacity(frames)
        var globalMax = -Float.infinity
        for spectrum in spectra {
            let row = whisper128.project(spectrum).map { log10(max($0, 1e-10)) }
            globalMax = max(globalMax, row.max() ?? -Float.infinity)
            projected.append(row)
        }
        let floorValue = globalMax - 8
        let array = try MLMultiArray(shape: [1, 128, NSNumber(value: frames)], dataType: .float32)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        for t in 0..<frames {
            for m in 0..<128 {
                pointer[m * frames + t] = (max(projected[t][m], floorValue) + 4) / 4
            }
        }
        return array
    }

    func campPlusFeatures(_ samples: [Float]) throws -> MLMultiArray {
        let frameLength = 400, hop = 160, nFFT = 512
        guard samples.count >= frameLength else { throw CosyVoice3ReferenceDSPError.insufficientSamples(samples.count) }
        let frameCount = 1 + (samples.count - frameLength) / hop
        let dft = try vDSP.DiscreteFourierTransform(
            previous: nil, count: nFFT, direction: .forward,
            transformType: .complexComplex, ofType: Float.self
        )
        let window = CosyVoice3Spectrum.povey(frameLength)
        let zeros = [Float](repeating: 0, count: nFFT)
        var input = [Float](repeating: 0, count: nFFT)
        var real = [Float](repeating: 0, count: nFFT)
        var imag = [Float](repeating: 0, count: nFFT)
        var features = [Float](repeating: 0, count: frameCount * 80)
        for f in 0..<frameCount {
            let start = f * hop
            var frame = Array(samples[start..<(start + frameLength)])
            let mean = frame.reduce(0, +) / Float(frameLength)
            for i in frame.indices { frame[i] -= mean }
            for i in stride(from: frameLength - 1, through: 1, by: -1) { frame[i] -= 0.97 * frame[i - 1] }
            frame[0] -= 0.97 * frame[0]
            for i in 0..<frameLength { input[i] = frame[i] * window[i] }
            for i in frameLength..<nFFT { input[i] = 0 }
            dft.transform(inputReal: input, inputImaginary: zeros, outputReal: &real, outputImaginary: &imag)
            var powerBins = [Float](repeating: 0, count: kaldi80.columns)
            for k in 0..<kaldi80.columns { powerBins[k] = real[k] * real[k] + imag[k] * imag[k] }
            let mel = kaldi80.project(powerBins)
            for m in 0..<80 { features[f * 80 + m] = log(max(mel[m], Float.ulpOfOne)) }
        }
        for m in 0..<80 {
            var sum: Float = 0
            for f in 0..<frameCount { sum += features[f * 80 + m] }
            let mean = sum / Float(frameCount)
            for f in 0..<frameCount { features[f * 80 + m] -= mean }
        }
        let array = try MLMultiArray(shape: [1, NSNumber(value: frameCount), 80], dataType: .float32)
        features.withUnsafeBufferPointer {
            array.dataPointer.copyMemory(from: $0.baseAddress!, byteCount: features.count * MemoryLayout<Float>.size)
        }
        return array
    }

    func promptMel(_ samples: [Float]) throws -> MLMultiArray {
        let spectra = try CosyVoice3Spectrum.frames(
            samples: samples, nFFT: 1920, hop: 480,
            window: CosyVoice3Spectrum.periodicHann(1920),
            reflectPad: 720, power: false
        )
        let frames = spectra.count
        let array = try MLMultiArray(shape: [1, 80, NSNumber(value: frames)], dataType: .float32)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        for t in 0..<frames {
            let mel = matcha80.project(spectra[t])
            for m in 0..<80 { pointer[m * frames + t] = log(max(mel[m], 1e-5)) }
        }
        return array
    }
}

// Purpose: eliminate Python preprocessing from shipping reference enrollment.
// Upstream: Whisper log_mel_spectrogram; torchaudio.compliance.kaldi.fbank defaults used by frontend.py; Matcha-TTS audio.py at submodule dd9105b.
// Runtime: Accelerate/CoreML.
// Generated: 2026-10-02 America/New_York.
