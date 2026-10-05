// GenerationPolicyTests.swift
// Requirement: lock production ctx512 generation capacity to upstream 20x text-token semantics, hard N450 acoustic support, and the remaining logical context.
import XCTest
@testable import CosyVoice3Core

final class GenerationPolicyTests: XCTestCase {
    func testTwentyTimesRuleWinsForShortTarget() {
        XCTAssertEqual(
            CosyVoice3GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: 8,
                logicalPrefixLength: 50
            ),
            160
        )
    }

    func testProductionN450CapWinsWhenContextAllowsIt() {
        XCTAssertEqual(
            CosyVoice3GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: 32,
                logicalPrefixLength: 62
            ),
            450
        )
        XCTAssertEqual(CosyVoice3GenerationPolicy.productionSpeechTokenMaximum, 450)
        XCTAssertEqual(CosyVoice3GenerationPolicy.logicalPrefixMaximumForFullSpeechWindow, 62)
    }

    func testPrefixAbove62ReducesSpeechWindowInsteadOfOverflowingState() {
        XCTAssertEqual(
            CosyVoice3GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: 32,
                logicalPrefixLength: 63
            ),
            449
        )
        XCTAssertEqual(
            CosyVoice3GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: 32,
                logicalPrefixLength: 73
            ),
            439
        )
    }

    func testOldN479CapacityIsIntentionallyCappedAt450() {
        XCTAssertEqual(
            CosyVoice3GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: 24,
                logicalPrefixLength: 33
            ),
            450
        )
        XCTAssertEqual(
            CosyVoice3GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: 24,
                logicalPrefixLength: 53
            ),
            450
        )
    }

    func testContextCapacityRemainsFailClosed() {
        XCTAssertEqual(
            CosyVoice3GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: 32,
                logicalPrefixLength: 500
            ),
            12
        )
        XCTAssertEqual(
            CosyVoice3GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: 32,
                logicalPrefixLength: 512
            ),
            0
        )
    }
}

// Code purpose: pin the production N450 speech ceiling and the exact ctx512 62-position full-window prefix budget while preserving upstream 20x and fail-closed remaining-context semantics.
// Upstream: Qwen2LM/CosyVoice3LM 20x max_len semantics plus the physically proven fixed512 stateful session.
// Runtime: SwiftPM XCTest.
// Generated time: 2026-10-05 America/New_York.
// Changed lines: replace historical N479 expectations with production N450/62-prefix invariants and explicit >62 context reduction tests.
