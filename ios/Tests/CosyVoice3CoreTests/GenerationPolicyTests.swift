// GenerationPolicyTests.swift
// Requirement: lock request-dynamic fixed512 generation capacity to upstream 20x text-token semantics and the remaining logical context; acoustic-profile compatibility is handled by CosyVoice3Engine.
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

    func testRemainingContextWinsForLongerTarget() {
        XCTAssertEqual(
            CosyVoice3GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: 32,
                logicalPrefixLength: 73
            ),
            439
        )
    }

    func testObservedCapacityWalkContractReaches479() {
        XCTAssertEqual(
            CosyVoice3GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: 24,
                logicalPrefixLength: 33
            ),
            479
        )
    }

    func testReferenceOrPromptGrowthReducesCapacityThroughLogicalPrefix() {
        XCTAssertEqual(
            CosyVoice3GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: 24,
                logicalPrefixLength: 53
            ),
            459
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

// Code purpose: prevent reintroducing a global N225 LLM cap while proving reference/prompt growth dynamically reduces the per-request speech-token budget.
// Upstream: Qwen2LM/CosyVoice3LM 20x max_len semantics plus the physically proven fixed512 stateful session.
// Runtime: SwiftPM XCTest.
// Generated time: 2026-10-04 America/New_York.
// Changes: replace fixed225 assertions with dynamic 20x/context tests, including the physically proven textTokens24/logicalPrefix33 -> N479 case.
