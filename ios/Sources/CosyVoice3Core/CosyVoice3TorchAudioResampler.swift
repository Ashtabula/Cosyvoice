// CosyVoice3TorchAudioResampler.swift
// Requirement: reproduce torchaudio 2.3.1 transforms.Resample default sinc_interp_hann kernel on device.
import Foundation

enum CosyVoice3TorchAudioResamplerError: Error {
    case invalidRate(Int)
}

enum CosyVoice3TorchAudioResampler {
    static let lowpassFilterWidth = 6
    static let rolloff = 0.99

    static func resample(_ waveform: [Float], from originalRate: Int, to newRate: Int) throws -> [Float] {
        guard originalRate > 0 else { throw CosyVoice3TorchAudioResamplerError.invalidRate(originalRate) }
        guard newRate > 0 else { throw CosyVoice3TorchAudioResamplerError.invalidRate(newRate) }
        if originalRate == newRate { return waveform }

        let divisor = gcd(originalRate, newRate)
        let original = originalRate / divisor
        let target = newRate / divisor
        let baseFrequency = Double(min(original, target)) * rolloff
        let width = Int(ceil(Double(lowpassFilterWidth * original) / baseFrequency))
        let kernelLength = 2 * width + original
        let scale = baseFrequency / Double(original)

        var kernels = [[Float]](
            repeating: [Float](repeating: 0, count: kernelLength),
            count: target
        )
        for phase in 0..<target {
            for index in 0..<kernelLength {
                let sourceIndex = Double(index - width) / Double(original)
                var t = -Double(phase) / Double(target) + sourceIndex
                t *= baseFrequency
                t = min(Double(lowpassFilterWidth), max(-Double(lowpassFilterWidth), t))
                let windowArgument = t * Double.pi / Double(lowpassFilterWidth) / 2
                let window = cos(windowArgument) * cos(windowArgument)
                let radians = t * Double.pi
                let sinc = abs(radians) < 1e-15 ? 1.0 : sin(radians) / radians
                kernels[phase][index] = Float(sinc * window * scale)
            }
        }

        var padded = [Float](repeating: 0, count: width)
        padded.append(contentsOf: waveform)
        padded.append(contentsOf: repeatElement(0, count: width + original))

        let targetLength = Int(ceil(Double(target * waveform.count) / Double(original)))
        var output = [Float]()
        output.reserveCapacity(targetLength)
        var sourceOffset = 0
        while sourceOffset + kernelLength <= padded.count && output.count < targetLength {
            for phase in 0..<target where output.count < targetLength {
                let kernel = kernels[phase]
                var accumulator: Float = 0
                for tap in 0..<kernelLength {
                    accumulator += padded[sourceOffset + tap] * kernel[tap]
                }
                output.append(accumulator)
            }
            sourceOffset += original
        }
        if output.count != targetLength {
            throw CosyVoice3TorchAudioResamplerError.invalidRate(newRate)
        }
        return output
    }

    private static func gcd(_ lhs: Int, _ rhs: Int) -> Int {
        var a = abs(lhs)
        var b = abs(rhs)
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a
    }
}

// Code purpose: remove AVAudioConverter resampling variance from reference-enrollment parity.
// Upstream: torchaudio==2.3.1 _get_sinc_resample_kernel/_apply_sinc_resample_kernel defaults.
// Runtime: pure Swift.
// Generated: 2026-10-02 America/New_York.
