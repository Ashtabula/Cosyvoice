// DynamicAcousticContractTests.swift
// Requirement: lock manifest-derived N/T/G/PCM geometry independently of Core ML execution.
import XCTest
@testable import CosyVoice3Core

final class DynamicAcousticContractTests: XCTestCase {
    func testCurrentN3ToN479CandidateGeometry() throws {
        let contract = CosyVoice3DynamicAcousticAssets(
            status: "CANDIDATE",
            speechTokenMinimum: 3,
            speechTokenMaximum: 479,
            promptFrameCount: 302,
            defaultPromptTokens: "prompt-tokens.bin",
            defaultPromptFeat: "prompt-feat.bin",
            defaultSpeaker: "speaker.bin",
            flowNoiseMaximum: "flow-noise-max.f32",
            hiftExcitationMaximum: "hift-excitation-max.f32"
        )
        XCTAssertNoThrow(try contract.validate())
        XCTAssertEqual(contract.maximumFlowFrames, 1260)
        XCTAssertEqual(contract.maximumMelFrames, 958)
        XCTAssertEqual(contract.maximumPCMSamples, 459_840)
    }

    func testFutureN1LowerBoundIsContractValid() throws {
        let contract = CosyVoice3DynamicAcousticAssets(
            status: "CANDIDATE",
            speechTokenMinimum: 1,
            speechTokenMaximum: 479,
            promptFrameCount: 302,
            defaultPromptTokens: "prompt-tokens.bin",
            defaultPromptFeat: "prompt-feat.bin",
            defaultSpeaker: "speaker.bin",
            flowNoiseMaximum: "flow-noise-max.f32",
            hiftExcitationMaximum: "hift-excitation-max.f32"
        )
        XCTAssertNoThrow(try contract.validate())
    }
}

// Code purpose: pin dynamic acoustic envelope geometry and keep the runtime generic enough to lower the final validated minimum from N3 to N1 without another SDK architecture change.
// Runtime: SwiftPM XCTest, no model assets required.
// Generated time: 2026-10-04 America/New_York.
