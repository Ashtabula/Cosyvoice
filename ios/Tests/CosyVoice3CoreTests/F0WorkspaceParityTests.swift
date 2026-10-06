// F0WorkspaceParityTests.swift
// Requirement: FP64 workspace reuse must match the unchanged fresh-allocation oracle and keep storage stable across layers.
import CoreML
import Foundation
import XCTest
@testable import CosyVoice3Core

@available(iOS 18.0, macOS 15.0, *)
final class F0WorkspaceParityTests: XCTestCase {
    func testFrozenWeightsAcrossPaddingAndProductionLengths() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COSYVOICE3_F0_PARITY_FOLDER"] ?? "/Volumes/WD/Codes/Cosyvoice/ios/.work/enumerated-n1-n450/generated-ac31e117938ed50132365973a103cc8425942700/f0-double")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("f0-0-weight.bin").path) else {
            throw XCTSkip("Frozen FP64 F0 fixture absent; this is not physical-device evidence")
        }
        let model = try CosyVoice3HiFTDoubleF0(folder: folder)
        for frames in [1,3,17,128,520,900] {
            let mel = try MLMultiArray(shape: [1,80,NSNumber(value: frames)], dataType: .float32)
            let pointer = mel.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<mel.count { pointer[i] = Float(sin(Double(i) * 0.019) * 0.2) }
            let original = try model.prediction(mel: mel, reuseWorkspace: false)
            var addresses = [(UInt, UInt)]()
            let actual = try model.prediction(mel: mel, reuseWorkspace: true) { _, columns, output in addresses.append((columns, output)) }
            XCTAssertEqual(addresses.count, 5)
            XCTAssertTrue(addresses.allSatisfy { $0.0 == addresses[0].0 && $0.1 == addresses[0].1 }, "COW or workspace reallocation detected")
            XCTAssertEqual(Data(bytes: original.dataPointer, count: frames * 4), Data(bytes: actual.dataPointer, count: frames * 4), "Float result bits differ at frames=\(frames)")
            // A following request must not observe any previous workspace values.
            for i in 0..<mel.count { pointer[i] = Float(cos(Double(i) * 0.027) * -0.13) }
            let nextOriginal = try model.prediction(mel: mel, reuseWorkspace: false)
            let nextActual = try model.prediction(mel: mel, reuseWorkspace: true)
            XCTAssertEqual(Data(bytes: nextOriginal.dataPointer, count: frames * 4), Data(bytes: nextActual.dataPointer, count: frames * 4))
        }
    }
}
// Purpose: full frozen weights, independent original implementation and repeated-request byte/address identity.
// Upstream validated CosyVoice3HiFTDoubleF0 fresh allocation math; Swift6/CoreML/Accelerate macOS15+/iOS18+.
// Generated2026-10-06 America/New_York; no model/precision/BLAS configuration change.
