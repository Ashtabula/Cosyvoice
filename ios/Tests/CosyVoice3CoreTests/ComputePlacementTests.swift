// ComputePlacementTests.swift
// Requirement: lock the physically accepted mixed Core ML placement so stateful LLM prefill/decode can never silently inherit the acoustic CPU_AND_NE default.
import CoreML
import XCTest
@testable import CosyVoice3Core

final class ComputePlacementTests: XCTestCase {
    func testStatefulLLMRequestsCPUAndNE() {
        XCTAssertEqual(CosyVoice3ModelComputePlacement.llm, .cpuAndNeuralEngine)
        XCTAssertEqual(CosyVoice3ModelWarmSpec.llm("prefill.mlpackage").computeUnits, .cpuAndNeuralEngine)
        XCTAssertEqual(CosyVoice3ModelWarmSpec.llm("decode.mlpackage").computeUnits, .cpuAndNeuralEngine)
    }

    func testAcousticDefaultRequestsCPUAndGPU() {
        XCTAssertEqual(CosyVoice3ModelComputePlacement.acoustic, .cpuAndGPU)
        XCTAssertEqual(CosyVoice3ModelWarmSpec("flow.mlpackage").computeUnits, .cpuAndGPU)
        XCTAssertFalse(CosyVoice3ModelWarmSpec("flow.mlpackage").reshapeFrequencyInfrequent)
    }

    func testDynamicAcousticProfilePinsInfrequentReshapeHint() {
        let spec = CosyVoice3ModelWarmSpec.dynamicAcoustic("flow.mlpackage")
        XCTAssertEqual(spec.computeUnits, .cpuAndGPU)
        XCTAssertTrue(spec.reshapeFrequencyInfrequent)
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

// Changes 2026-10-04: dynamic-acoustic warm specs must pin reshapeFrequencyInfrequent=true, matching the physical sweep configuration; generic/fixed acoustic default remains unchanged.

// Changes2026-10-05: existing regression assertions updated to accepted FullLLM requestedNE placement; no claimactualANEresidency. Prior CPUexpectations stale against77e7334 baseline. XCTest/macOS; exactlines via gitdiff.
