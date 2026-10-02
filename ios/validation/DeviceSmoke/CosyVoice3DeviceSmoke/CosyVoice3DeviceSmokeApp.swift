// CosyVoice3DeviceSmokeApp.swift
// Requirement: physical-device smoke may call only the public CosyVoice3Core API.

import AVFoundation
import SwiftUI
import UIKit
import CosyVoice3Core

@main
struct CosyVoice3DeviceSmokeApp: App {
    @StateObject private var model = CosyVoice3SmokeModel()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("CosyVoice3 Device Smoke")
                    .font(.title2.bold())

                Text(model.status)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)

                Button("Run public API reference smoke") {
                    Task { await model.run() }
                }
                .disabled(model.running)

                Button("Copy receipt JSON") {
                    UIPasteboard.general.string = model.receiptJSON
                }
                .disabled(model.receiptJSON.isEmpty)

                Spacer()
            }
            .padding()
            .task {
                guard !model.didAutoRun else { return }
                model.didAutoRun = true
                await model.run()
            }
        }
    }
}

@MainActor
final class CosyVoice3SmokeModel: ObservableObject {
    @Published var status = "READY"
    @Published var running = false
    @Published var receiptJSON = ""
    var didAutoRun = false

    private var player: AVAudioPlayer?

    func run() async {
        guard !running else { return }
        running = true
        status = "RUNNING public API custom-reference smoke..."
        defer { running = false }

        do {
            let resources = try Self.generatedAssets()
            let runtime = resources.appendingPathComponent("Runtime", isDirectory: true)
            let wav = resources.appendingPathComponent("reference.wav")
            let transcriptURL = resources.appendingPathComponent("reference.txt")
            let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reference = CosyVoice3VoiceReference(audioURL: wav, transcript: transcript)
            let text = "This is a CosyVoice3 public API reference voice validation."

            let engine = try CosyVoice3Engine(assetRoot: runtime)
            let capabilities = try await engine.capabilities()
            guard capabilities.supportsReferenceAudio,
                  capabilities.supportsInstruction,
                  capabilities.outputSampleRate == 24_000 else {
                throw SmokeError("unexpected capabilities")
            }

            try await engine.validateReference(reference, probeText: text)
            let started = ContinuousClock.now
            let audio = try await engine.synthesize(
                text,
                parameters: CosyVoice3Parameters(
                    reference: reference,
                    instruction: "You are a helpful assistant.<|endofprompt|>" + transcript
                )
            )
            let elapsed = started.duration(to: .now)
            try Self.validate(audio)

            let duration = Double(audio.samples.count) / Double(audio.sampleRate * audio.channels)
            let elapsedSeconds = elapsed.components.seconds
                + Double(elapsed.components.attoseconds) / 1e18
            let peak = audio.samples.reduce(Float.zero) { max($0, abs($1)) }
            let rms = sqrt(audio.samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(audio.samples.count))
            let receipt: [String: Any] = [
                "schemaVersion": 1,
                "status": "PASS_DEVICE_PUBLIC_API_REFERENCE_PCM",
                "sampleRate": audio.sampleRate,
                "channels": audio.channels,
                "samples": audio.samples.count,
                "durationSeconds": duration,
                "elapsedSeconds": elapsedSeconds,
                "rtf": elapsedSeconds / duration,
                "finite": true,
                "peakAbs": peak,
                "rms": rms,
                "referenceTranscriptCharacters": transcript.count,
                "device": UIDevice.current.model,
                "systemName": UIDevice.current.systemName,
                "systemVersion": UIDevice.current.systemVersion
            ]
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Self.receiptURL(), options: .atomic)
            receiptJSON = String(decoding: data, as: UTF8.self)
            try play(audio)
            status = String(
                format: "PASS samples=%d duration=%.3fs elapsed=%.3fs rtf=%.3f receipt=%@",
                audio.samples.count,
                duration,
                elapsedSeconds,
                elapsedSeconds / duration,
                Self.receiptURL().path
            )
        } catch {
            let receipt: [String: Any] = [
                "schemaVersion": 1,
                "status": "FAIL",
                "error": String(describing: error),
                "device": UIDevice.current.model,
                "systemVersion": UIDevice.current.systemVersion
            ]
            if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: Self.receiptURL(), options: .atomic)
                receiptJSON = String(decoding: data, as: UTF8.self)
            }
            status = "FAIL \(String(describing: error))"
        }
    }

    private static func generatedAssets() throws -> URL {
        guard let resourceRoot = Bundle.main.resourceURL else {
            throw SmokeError("bundle resource root unavailable")
        }
        let root = resourceRoot.appendingPathComponent("GeneratedAssets", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SmokeError("GeneratedAssets missing; run validation/prepare_device_smoke_assets.py")
        }
        return root
    }

    private static func receiptURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appendingPathComponent("reference-smoke-receipt.json")
    }

    private static func validate(_ audio: CosyVoice3Audio) throws {
        guard audio.sampleRate == 24_000 else { throw SmokeError("unexpected sample rate \(audio.sampleRate)") }
        guard audio.channels == 1 else { throw SmokeError("unexpected channel count \(audio.channels)") }
        guard !audio.samples.isEmpty else { throw SmokeError("empty PCM") }
        guard audio.samples.allSatisfy(\.isFinite) else { throw SmokeError("PCM contains NaN/Inf") }
        guard audio.samples.contains(where: { abs($0) > 1e-6 }) else { throw SmokeError("PCM is effectively silent") }
    }

    private func play(_ audio: CosyVoice3Audio) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        let player = try AVAudioPlayer(data: Self.wavData(audio))
        guard player.prepareToPlay(), player.play() else { throw SmokeError("playback could not start") }
        self.player = player
    }

    private static func wavData(_ audio: CosyVoice3Audio) -> Data {
        let channels = UInt16(audio.channels)
        let sampleRate = UInt32(audio.sampleRate)
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt16(bitsPerSample / 8)
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataBytes = UInt32(audio.samples.count) * UInt32(bytesPerSample)

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + dataBytes)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(dataBytes)
        for sample in audio.samples {
            let clipped = max(-1.0, min(1.0, sample))
            let scaled = clipped < 0 ? clipped * 32768.0 : clipped * 32767.0
            data.appendLittleEndian(Int16(max(-32768, min(32767, Int(scaled.rounded())))))
        }
        return data
    }
}

private struct SmokeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(value.data(using: .ascii)!)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

// Code purpose: clean-room physical-device public API custom-reference smoke and machine-readable receipt.
// Upstream: CosyVoice3Core public API only.
// Runtime: iOS18+, SwiftUI, AVFoundation.
// Generated: 2026-10-02 America/New_York.
