// CosyVoice3ReferenceAudio.swift
// Requirement: decode and resample a user reference locally; no host/Python runtime.
import AVFoundation
import Foundation

enum CosyVoice3ReferenceAudioError: Error {
    case unsupportedSampleRate(Double)
    case converterUnavailable
    case missingSamples
    case tooLong(Double)
}

struct CosyVoice3ReferenceAudio: Sendable {
    let samples16k: [Float]
    let samples24k: [Float]

    static func load(url: URL, maximumSeconds: Double = 30) throws -> Self {
        let file = try AVAudioFile(forReading: url)
        guard file.fileFormat.sampleRate >= 16_000 else {
            throw CosyVoice3ReferenceAudioError.unsupportedSampleRate(file.fileFormat.sampleRate)
        }
        let duration = Double(file.length) / file.fileFormat.sampleRate
        guard duration <= maximumSeconds else { throw CosyVoice3ReferenceAudioError.tooLong(duration) }
        let source = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: source)
        return .init(
            samples16k: try convert(source, sampleRate: 16_000),
            samples24k: try convert(source, sampleRate: 24_000)
        )
    }

    private static func convert(_ source: AVAudioPCMBuffer, sampleRate: Double) throws -> [Float] {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: source.format, to: format) else {
            throw CosyVoice3ReferenceAudioError.converterUnavailable
        }
        let ratio = sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * ratio) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw CosyVoice3ReferenceAudioError.converterUnavailable
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        if let error { throw error }
        guard status != .error, let channel = output.floatChannelData?[0] else {
            throw CosyVoice3ReferenceAudioError.missingSamples
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

// Purpose: mirror upstream load_wav mono-mix + resample at 16k/24k for local enrollment.
// Upstream: cosyvoice/utils/file_utils.py load_wav at CosyVoice3_NPU@8789402.
// Runtime: AVFoundation, iOS18+/macOS15+.
// Generated: 2026-10-02 America/New_York.
