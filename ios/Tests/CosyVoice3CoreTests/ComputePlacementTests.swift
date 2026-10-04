// ComputePlacementTests.swift
// Requirement: lock the physically accepted mixed Core ML placement so stateful LLM prefill/decode can never silently inherit the acoustic CPU_AND_NE default.
import CoreML
import XCTest
@testable import CosyVoice3Core

final class ComputePlacementTests: XCTestCase {
    func testStatefulLLMPlacementIsCPUOnly() {
        XCTAssertEqual(CosyVoice3ModelComputePlacement.llm, .cpuOnly)
        XCTAssertEqual(CosyVoice3ModelWarmSpec.llm("prefill.mlpackage").computeUnits, .cpuOnly)
        XCTAssertEqual(CosyVoice3ModelWarmSpec.llm("decode.mlpackage").computeUnits, .cpuOnly)
    }

    func testAcousticDefaultPlacementRemainsCPUAndNE() {
        XCTAssertEqual(CosyVoice3ModelComputePlacement.acoustic, .cpuAndNeuralEngine)
        XCTAssertEqual(CosyVoice3ModelWarmSpec("flow.mlpackage").computeUnits, .cpuAndNeuralEngine)
    }

    func testReferenceEncoderPlacementRemainsCPUOnly() {
        XCTAssertEqual(CosyVoice3ModelComputePlacement.referenceEncoder, .cpuOnly)
    }
}

// Code purpose: prevent regression from the accepted mixed placement contract: stateful LLM CPU_ONLY, acoustic CPU_AND_NE requested compute units, reference encoders CPU_ONLY.
// Upstream source: physical iPhone validation where LLM CPU_AND_NE execution-plan construction produced Core ML error -14.
// Runtime environment: SwiftPM XCTest with CoreML.
// Generated time: 2026-10-04 America/New_York.
// Changes: new placement regression test; requested compute units are not an accelerator residency claim.
