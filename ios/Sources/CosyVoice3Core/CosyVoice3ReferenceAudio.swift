// CosyVoice3ReferenceAudio.swift
// Requirement: decode and mono-mix user reference locally, then reproduce upstream torchaudio resampling.
import AVFoundation
import Foundation

enum CosyVoice3ReferenceAudioError: Error {
    case unsupportedSampleRate(Double)
    case missingSamples
    case tooLong(Double)
    case unsupportedProcessingFormat
}

struct CosyVoice3ReferenceAudio: Sendable {
    let samples16k: [Float]
    let samples24k: [Float]

    static func load(url: URL, maximumSeconds: Double = 30) throws -> Self {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate >= 16_000 else {
            throw CosyVoice3ReferenceAudioError.unsupportedSampleRate(sampleRate)
        }
        let duration = Double(file.length) / sampleRate
        guard duration <= maximumSeconds else {
            throw CosyVoice3ReferenceAudioError.tooLong(duration)
        }
        guard let source = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw CosyVoice3ReferenceAudioError.unsupportedProcessingFormat
        }
        try file.read(into: source)
        guard let channels = source.floatChannelData, source.frameLength > 0 else {
            throw CosyVoice3ReferenceAudioError.missingSamples
        }

        let frameCount = Int(source.frameLength)
        let channelCount = Int(source.format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            let values = channels[channel]
            for frame in 0..<frameCount {
                mono[frame] += values[frame]
            }
        }
        let inverseChannels = 1.0 / Float(channelCount)
        for frame in mono.indices { mono[frame] *= inverseChannels }

        let originalRate = Int(sampleRate.rounded())
        return .init(
            samples16k: try CosyVoice3TorchAudioResampler.resample(mono, from: originalRate, to: 16_000),
            samples24k: try CosyVoice3TorchAudioResampler.resample(mono, from: originalRate, to: 24_000)
        )
    }
}

// Code purpose: mirror upstream load_wav mono mean + torchaudio Resample behavior without Python runtime.
// Upstream: cosyvoice/utils/file_utils.py load_wav at CosyVoice3_NPU@8789402; torchaudio==2.3.1.
// Runtime: AVFoundation decode + pure Swift sinc resampler.
// Generated: 2026-10-02 America/New_York.
