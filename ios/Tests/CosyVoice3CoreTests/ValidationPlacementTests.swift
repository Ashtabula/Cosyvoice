// ValidationPlacementTests.swift
// Requirement: each diagnostic role is independently selectable; invalid requests fail closed.
import CoreML
import XCTest
@testable import CosyVoice3Core
final class ValidationPlacementTests: XCTestCase {
    func testAllRolesAndPolicies() throws {
        for policy in ["CPU_ONLY", "CPU_AND_GPU", "CPU_AND_NE"] {
            let args = CosyVoice3ValidationPlacement.roles.map { "--validation-placement=\($0):\(policy)" }
            let parsed = try CosyVoice3ValidationPlacement.overrides(arguments: args)
            XCTAssertEqual(parsed.count, 12)
            let expected: MLComputeUnits = policy == "CPU_ONLY" ? .cpuOnly : policy == "CPU_AND_GPU" ? .cpuAndGPU : .cpuAndNeuralEngine
            for units in parsed.values { XCTAssertEqual(units, expected) }
        }
        XCTAssertTrue(try CosyVoice3ValidationPlacement.overrides(arguments: []).isEmpty)
    }
    func testMalformedAndDuplicateFailClosed() {
        for value in ["unknown:CPU_ONLY", "flow0:ALL", "flow0", "flow0:CPU_ONLY:CPU_AND_NE", ":CPU_ONLY"] {
            XCTAssertThrowsError(try CosyVoice3ValidationPlacement.overrides(arguments: ["--validation-placement=\(value)"]))
        }
        XCTAssertThrowsError(try CosyVoice3ValidationPlacement.overrides(arguments: ["--validation-placement=flow0:CPU_ONLY", "--validation-placement=flow0:CPU_AND_NE"]))
    }
    func testExactFrozenPathsMapToRoles() {
        XCTAssertEqual(CosyVoice3ValidationPlacement.role(for: "models/llm-opt-perlayer-prefill.mlpackage"), "llmPrefill")
        XCTAssertEqual(CosyVoice3ValidationPlacement.role(for: "models/llm-opt-perlayer-decode-maskwrite512.mlpackage"), "llmDecode")
        for i in 0..<6 { XCTAssertEqual(CosyVoice3ValidationPlacement.role(for: "enumerated-acoustic/flow-shard-\(i).mlpackage"), "flow\(i)") }
        XCTAssertEqual(CosyVoice3ValidationPlacement.role(for: "reference/speech-tokenizer-fixed605.mlpackage"), "speechTokenizer")
        XCTAssertEqual(CosyVoice3ValidationPlacement.role(for: "reference/campplus-fixed604.mlpackage"), "campPlus")
        XCTAssertNil(CosyVoice3ValidationPlacement.role(for: "dynamic-acoustic/flow-shard-0.mlpackage"))
    }
}
// Purpose: validate independent placement grammar and frozen role mapping, especially fail-closed errors.
// Upstream: SDK AssetLoader; upstream purpose immutable Core ML loading. Runtime Swift XCTest macOS15+/iOS18+.
// Generated 2026-10-05 19:18 America/New_York; new file lines 1-39.
