// GenerationPolicyTests.swift
// Requirement: lock the publication fixed225 max-length contract to upstream max_len semantics plus the current downstream bucket capacity.
import XCTest
@testable import CosyVoice3Core

final class GenerationPolicyTests: XCTestCase {
    func testPhase0LikeTargetIsCappedAtFixed225Bucket() {
        XCTAssertEqual(
            CosyVoice3Fixed225GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: 32,
                logicalPrefixLength: 73
            ),
            225
        )
    }

    func testShortTargetStillPreservesUpstreamTwentyTimesMaximum() {
        XCTAssertEqual(
            CosyVoice3Fixed225GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: 8,
                logicalPrefixLength: 50
            ),
            160
        )
    }

    func testContextCapacityRemainsFailClosed() {
        XCTAssertEqual(
            CosyVoice3Fixed225GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: 32,
                logicalPrefixLength: 500
            ),
            12
        )
    }
}

// Code purpose: prevent reintroducing decodeLimit-at-max behavior or allowing the fixed225 public lane to request more speech tokens than its acoustic bucket can consume.
// Upstream: Qwen2LM/CosyVoice3LM inference_wrapper max_len semantics at CosyVoice3_NPU@878940245562bcd1dd0231d78157ba78d70b39f6.
// Runtime: SwiftPM XCTest.
// Generated: 2026-10-02 America/New_York.
