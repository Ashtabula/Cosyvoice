// FlowSpecializationParityTests.swift
// Requirement: rejected validation environment variables must not alter the frozen production compute policy.
import CoreML
import Darwin
import XCTest
@testable import CosyVoice3Core

final class FlowSpecializationParityTests: XCTestCase {
    func testRejectedEnvironmentOverridesDoNotChangeProductionPlacementContract() {
        setenv("COSYVOICE3_VALIDATION_ACOUSTIC_GPU","1",1)
        setenv("COSYVOICE3_VALIDATION_FLOW_FAST_PREDICTION","1",1)
        defer { unsetenv("COSYVOICE3_VALIDATION_ACOUSTIC_GPU"); unsetenv("COSYVOICE3_VALIDATION_FLOW_FAST_PREDICTION") }
        XCTAssertEqual(CosyVoice3ModelComputePlacement.acoustic,.cpuAndNeuralEngine)
        XCTAssertEqual(CosyVoice3ModelWarmSpec.dynamicAcoustic("dynamic-acoustic/flow.mlpackage").computeUnits,.cpuAndNeuralEngine)
        XCTAssertTrue(CosyVoice3ModelWarmSpec.dynamicAcoustic("dynamic-acoustic/flow.mlpackage").reshapeFrequencyInfrequent)
    }
}
// Purpose: lock the accepted production route after GPU/fastPrediction experiments were rejected or not promoted.
// Environment: Swift XCTest; generated 2026-10-05 America/New_York.
