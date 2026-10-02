import CoreML
import Foundation
import XCTest
@testable import CosyVoice3Core

final class ReferenceDSPExternalParityTests: XCTestCase {
    func testExternalUpstreamReferenceParityWhenFixtureIsProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootValue = environment["COSYVOICE3_REFERENCE_PARITY_FIXTURE"], !rootValue.isEmpty else {
            throw XCTSkip("COSYVOICE3_REFERENCE_PARITY_FIXTURE is not set")
        }
        let root = URL(fileURLWithPath: rootValue, isDirectory: true)
        let wav = root.appendingPathComponent("reference-parity.wav")
        let audio = try CosyVoice3ReferenceAudio.load(url: wav)

        let whisperBank = try CosyVoice3MelBank(
            url: root.appendingPathComponent("whisper_mel_128.f32"),
            rows: 128,
            columns: 201
        )
        let kaldiBank = try CosyVoice3MelBank(
            url: root.appendingPathComponent("kaldi_mel_80.f32"),
            rows: 80,
            columns: 256
        )
        let matchaBank = try CosyVoice3MelBank(
            url: root.appendingPathComponent("matcha_mel_80.f32"),
            rows: 80,
            columns: 961
        )
        let dsp = CosyVoice3ReferenceDSP(
            whisper128: whisperBank,
            kaldi80: kaldiBank,
            matcha80: matchaBank
        )

        var checks: [[String: Any]] = []
        checks.append(try compare(
            name: "samples24k",
            observed: audio.samples24k,
            expectedURL: root.appendingPathComponent("samples24k.f32"),
            maxTolerance: 2e-7,
            meanTolerance: 2e-8,
            p99Tolerance: 2e-7
        ))
        checks.append(try compare(
            name: "samples16k",
            observed: audio.samples16k,
            expectedURL: root.appendingPathComponent("samples16k.f32"),
            maxTolerance: 3e-5,
            meanTolerance: 1e-6,
            p99Tolerance: 3e-5
        ))

        let whisper = try dsp.whisperFeatures(audio.samples16k)
        checks.append(try compare(
            name: "whisper128",
            observed: flatten(whisper),
            expectedURL: root.appendingPathComponent("whisper128.f32"),
            maxTolerance: 8e-4,
            meanTolerance: 1e-4,
            p99Tolerance: 2e-4
        ))

        let camp = try dsp.campPlusFeatures(audio.samples16k)
        if let campPath = environment["COSYVOICE3_SWIFT_CAMPPLUS_FBANK"], !campPath.isEmpty {
            try writeFloat32(
                flatten(camp),
                to: URL(fileURLWithPath: campPath)
            )
        }
        checks.append(try compare(
            name: "campplusFbank",
            observed: flatten(camp),
            expectedURL: root.appendingPathComponent("campplus_fbank.f32"),
            maxTolerance: 4e-3,
            meanTolerance: 1.5e-4,
            p99Tolerance: 1.5e-3
        ))

        let prompt = try dsp.promptMel(audio.samples24k)
        var promptTransposed = [Float](repeating: 0, count: 302 * 80)
        for frame in 0..<302 {
            for mel in 0..<80 {
                promptTransposed[frame * 80 + mel] = prompt[mel * 302 + frame].floatValue
            }
        }
        checks.append(try compare(
            name: "promptMel",
            observed: promptTransposed,
            expectedURL: root.appendingPathComponent("prompt_mel.f32"),
            maxTolerance: 8e-3,
            meanTolerance: 5e-4,
            p99Tolerance: 3e-3
        ))

        let passed = checks.allSatisfy { ($0["pass"] as? Bool) == true }
        if let receiptPath = environment["COSYVOICE3_REFERENCE_PARITY_RECEIPT"], !receiptPath.isEmpty {
            let receipt: [String: Any] = [
                "schemaVersion": 1,
                "status": passed ? "PASS" : "FAIL",
                "checks": checks
            ]
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: receiptPath), options: .atomic)
        }
        XCTAssertTrue(passed, "Swift reference DSP differs from upstream oracle: \(checks)")
    }

    private func flatten(_ value: MLMultiArray) -> [Float] {
        (0..<value.count).map { value[$0].floatValue }
    }

    private func writeFloat32(_ values: [Float], to url: URL) throws {
        let data = values.withUnsafeBytes { Data($0) }
        try data.write(to: url, options: .atomic)
    }

    private func compare(
        name: String,
        observed: [Float],
        expectedURL: URL,
        maxTolerance: Float,
        meanTolerance: Double,
        p99Tolerance: Float
    ) throws -> [String: Any] {
        let data = try Data(contentsOf: expectedURL)
        let expected: [Float] = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        guard observed.count == expected.count else {
            return [
                "name": name,
                "pass": false,
                "observedCount": observed.count,
                "expectedCount": expected.count
            ]
        }

        var maxAbs: Float = 0
        var sumAbs = 0.0
        var finite = true
        var differences = [Float]()
        differences.reserveCapacity(observed.count)

        for i in observed.indices {
            finite = finite && observed[i].isFinite
            let difference = abs(observed[i] - expected[i])
            maxAbs = max(maxAbs, difference)
            sumAbs += Double(difference)
            differences.append(difference)
        }

        differences.sort()
        let p99Index = max(
            0,
            min(
                differences.count - 1,
                Int((Double(differences.count - 1) * 0.99).rounded(.up))
            )
        )
        let p99Abs = differences.isEmpty ? 0 : differences[p99Index]
        let meanAbs = sumAbs / Double(max(1, observed.count))
        let passed = finite
            && maxAbs <= maxTolerance
            && meanAbs <= meanTolerance
            && p99Abs <= p99Tolerance

        return [
            "name": name,
            "pass": passed,
            "maxAbs": maxAbs,
            "meanAbs": meanAbs,
            "p99Abs": p99Abs,
            "maxTolerance": maxTolerance,
            "meanTolerance": meanTolerance,
            "p99Tolerance": p99Tolerance,
            "finite": finite
        ]
    }
}
