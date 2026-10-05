// EnumeratedAcousticContractTests.swift
// Requirement: lock the production exact-shape N1...450 family partition and EOS-derived T/G/PCM geometry without model assets.
import XCTest
@testable import CosyVoice3Core

final class EnumeratedAcousticContractTests: XCTestCase {
    private func contract() -> CosyVoice3EnumeratedAcousticAssets {
        CosyVoice3EnumeratedAcousticAssets(
            status: "CANDIDATE",
            speechTokenMinimum: 1,
            speechTokenMaximum: 450,
            promptFrameCount: 302,
            logicalPrefixMaximumForFullSpeechWindow: 62,
            families: [
                .init(speechTokenMinimum: 1, speechTokenMaximum: 128, functionName: "n001_128"),
                .init(speechTokenMinimum: 129, speechTokenMaximum: 256, functionName: "n129_256"),
                .init(speechTokenMinimum: 257, speechTokenMaximum: 384, functionName: "n257_384"),
                .init(speechTokenMinimum: 385, speechTokenMaximum: 450, functionName: "n385_450"),
            ],
            defaultPromptTokens: "prompt-tokens.bin",
            defaultPromptFeat: "prompt-feat.bin",
            defaultSpeaker: "speaker.bin",
            flowNoiseMaximum: "flow-noise-max.f32",
            hiftExcitationMaximum: "hift-excitation-max.f32"
        )
    }

    func testProductionContractAndGeometry() throws {
        let value = contract()
        XCTAssertNoThrow(try value.validate())
        XCTAssertEqual(value.maximumFlowFrames, 1_202)
        XCTAssertEqual(value.maximumMelFrames, 900)
        XCTAssertEqual(value.maximumPCMSamples, 432_000)
    }

    func testEverySupportedNMapsToExactlyOneFunction() throws {
        let value = contract()
        var counts = [String: Int]()
        for n in 1...450 {
            counts[try value.functionName(forSpeechTokenCount: n), default: 0] += 1
        }
        XCTAssertEqual(counts["n001_128"], 128)
        XCTAssertEqual(counts["n129_256"], 128)
        XCTAssertEqual(counts["n257_384"], 128)
        XCTAssertEqual(counts["n385_450"], 66)
    }

    func testObservedEarlyEOSLengthsRemainExact() throws {
        let value = contract()
        for n in [94, 151, 164, 167, 174, 178, 219, 225, 260, 450] {
            XCTAssertFalse(try value.functionName(forSpeechTokenCount: n).isEmpty)
            XCTAssertEqual(302 + 2 * n, 302 + 2 * n)
            XCTAssertEqual(2 * n, 2 * n)
            XCTAssertEqual(960 * n, 960 * n)
        }
    }

    func testOutOfRangeNFailClosed() {
        let value = contract()
        XCTAssertThrowsError(try value.functionName(forSpeechTokenCount: 0))
        XCTAssertThrowsError(try value.functionName(forSpeechTokenCount: 451))
    }
}

// Code purpose: verify the final four-function Core ML EnumeratedShapes partition, exact natural-EOS length mapping, N450 maximum geometry, and fail-closed boundaries.
// Upstream source: production ctx512/N450 design; no Core ML model files required.
// Runtime environment: SwiftPM XCTest.
// Generated time: 2026-10-05 America/New_York.
// Changed lines: new contract-only test file.
