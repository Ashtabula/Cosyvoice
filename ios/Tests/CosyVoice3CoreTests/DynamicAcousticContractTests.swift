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

    func testN1LowerBoundGeometryIsArchitecturallySupported() throws {
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
        XCTAssertEqual(contract.maximumFlowFrames, 1260)
        XCTAssertEqual(contract.maximumMelFrames, 958)
        XCTAssertEqual(contract.maximumPCMSamples, 459_840)
        XCTAssertEqual(302 + 2 * contract.speechTokenMinimum, 304)
        XCTAssertEqual(2 * contract.speechTokenMinimum, 2)
        XCTAssertEqual(960 * contract.speechTokenMinimum, 960)
    }
}

// Code purpose: pin current N3 candidate geometry and the N1 lower-bound architecture so the focused physical extension changes validation evidence/range metadata rather than SDK tensor formulas.
// Runtime: SwiftPM XCTest, no model assets required.
// Generated time: 2026-10-04 America/New_York.

// Changes 2026-10-04: N1 test now pins exact lower-bound geometry T304/G2/PCM960 while retaining Nmax479 geometry.
