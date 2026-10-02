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
        // vDSP's split-complex DFT supports only specific factorizations.
        // Whisper's exact n_fft=400 (25 * 16) is not one of them, while
        // CAMPPlus n_fft=512 and Matcha n_fft=1920 are supported. Preserve
        // the exact requested DFT length and use a BLAS-backed direct DFT
        // only when vDSP cannot create a setup.
        let dft = try? vDSP.DiscreteFourierTransform(
            previous: nil,
            count: nFFT,
            direction: .forward,
            transformType: .complexComplex,
            ofType: Float.self
        )
        let directDFT = dft == nil ? DirectRealDFT(count: nFFT) : nil

        let zeros = [Float](repeating: 0, count: nFFT)
        var input = [Float](repeating: 0, count: nFFT)
        var real = [Float](repeating: 0, count: nFFT)
        var imag = [Float](repeating: 0, count: nFFT)
        var output = [[Float]]()
        output.reserveCapacity(frameCount)
        for frameIndex in 0..<frameCount {
            let start = frameIndex * hop
            for i in 0..<nFFT { input[i] = padded[start + i] * window[i] }
            if let dft {
                dft.transform(
                    inputReal: input,
                    inputImaginary: zeros,
                    outputReal: &real,
                    outputImaginary: &imag
                )
            } else if let directDFT {
                directDFT.transform(input, real: &real, imaginary: &imag)
            } else {
                throw CosyVoice3ReferenceDSPError.dftUnavailable(nFFT)
            }
            var bins = [Float](repeating: 0, count: nFFT / 2 + 1)
            for k in bins.indices {
                let magnitude2 = real[k] * real[k] + imag[k] * imag[k]
                bins[k] = power ? magnitude2 : sqrt(magnitude2 + 1e-9)
            }
            output.append(bins)
        }
        return output
    }

    private struct DirectRealDFT {
        let count: Int
        let binCount: Int
        let cosine: [Float]
        let negativeSine: [Float]

        init(count: Int) {
            self.count = count
            self.binCount = count / 2 + 1

            var cosine = [Float](repeating: 0, count: binCount * count)
            var negativeSine = [Float](repeating: 0, count: binCount * count)
            let scale = 2.0 * Double.pi / Double(count)

            for k in 0..<binCount {
                let row = k * count
                for n in 0..<count {
                    let angle = scale * Double(k * n)
                    cosine[row + n] = Float(Foundation.cos(angle))
                    negativeSine[row + n] = -Float(Foundation.sin(angle))
                }
            }

            self.cosine = cosine
            self.negativeSine = negativeSine
        }

        func transform(
            _ input: [Float],
            real: inout [Float],
            imaginary: inout [Float]
        ) {
            precondition(input.count == count)
            precondition(real.count >= count)
            precondition(imaginary.count >= count)

            cosine.withUnsafeBufferPointer { cosinePointer in
                negativeSine.withUnsafeBufferPointer { sinePointer in
                    input.withUnsafeBufferPointer { inputPointer in
                        real.withUnsafeMutableBufferPointer { realPointer in
                            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                                cblas_sgemv(
                                    CblasRowMajor,
                                    CblasNoTrans,
                                    Int32(binCount),
                                    Int32(count),
                                    1,
                                    cosinePointer.baseAddress!,
                                    Int32(count),
                                    inputPointer.baseAddress!,
                                    1,
                                    0,
                                    realPointer.baseAddress!,
                                    1
                                )
                                cblas_sgemv(
                                    CblasRowMajor,
                                    CblasNoTrans,
                                    Int32(binCount),
                                    Int32(count),
                                    1,
                                    sinePointer.baseAddress!,
                                    Int32(count),
                                    inputPointer.baseAddress!,
                                    1,
                                    0,
                                    imaginaryPointer.baseAddress!,
                                    1
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    static func periodicHann(_ count: Int) -> [Float] {
        (0..<count).map { index in
            let angle = 2.0 * Double.pi * Double(index) / Double(count)
            return Float(0.5 - 0.5 * Foundation.cos(angle))
        }
    }

    static func povey(_ count: Int) -> [Float] {
        (0..<count).map { index in
            let angle = 2.0 * Double.pi * Double(index) / Double(count - 1)
            let hann = max(0.0, 0.5 - 0.5 * Foundation.cos(angle))
            return Float(Foundation.pow(hann, 0.85))
        }
    }

    private static func preciseMean(_ values: [Float]) -> Float {
        precondition(!values.isEmpty)
        var sum = 0.0
        for value in values {
            sum += Double(value)
        }
        return Float(sum / Double(values.count))
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
            let mean = CosyVoice3Spectrum.preciseMean(frame)
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
            var sum = 0.0
            for f in 0..<frameCount {
                sum += Double(features[f * 80 + m])
            }
            let mean = Float(sum / Double(frameCount))
            for f in 0..<frameCount {
                features[f * 80 + m] -= mean
            }
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
// Runtime: Accelerate/CoreML. vDSP handles supported DFT factorizations; exact-length BLAS direct DFT is used for unsupported Whisper n_fft=400.
// Generated: 2026-10-02 America/New_York.
