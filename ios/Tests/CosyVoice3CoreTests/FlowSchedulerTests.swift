// FlowSchedulerTests.swift
// Requirement: production 6-step cosine Euler schedule and public 8/10 alternatives must stay bounded and monotonic; the legacy validated 10-step formula remains byte-for-byte equivalent.
@testable import CosyVoice3Core
import Foundation
import XCTest

@available(iOS 18.0, macOS 15.0, *)
final class FlowSchedulerTests: XCTestCase {
    func testValidatedTenStepScheduleMatchesPreviousFormula() throws {
        let actual = try CosyVoice3Fixed225AcousticRuntime.flowTimeSpan(stepCount: 10)
        let expected: [Float] = (0...10).map {
            1 - cos(Float($0) / 10 * Float.pi / 2)
        }
        XCTAssertEqual(actual.count, expected.count)
        for index in expected.indices {
            XCTAssertEqual(actual[index], expected[index])
        }
    }

    func testHeadToHeadSchedulesAreMonotonicAndEndAtOne() throws {
        for steps in [10, 8, 6] {
            let span = try CosyVoice3Fixed225AcousticRuntime.flowTimeSpan(stepCount: steps)
            XCTAssertEqual(span.count, steps + 1)
            XCTAssertEqual(span.first ?? -1, 0, accuracy: 1e-7)
            XCTAssertEqual(span.last ?? -1, 1, accuracy: 1e-6)
            for index in 1..<span.count {
                XCTAssertGreaterThan(span[index], span[index - 1])
            }
        }
    }

    func testUnsupportedFlowStepCountFailsClosed() {
        XCTAssertThrowsError(try CosyVoice3Fixed225AcousticRuntime.flowTimeSpan(stepCount: 5)) { error in
            XCTAssertEqual(error as? CosyVoice3AcousticError, .invalidFlowStepCount(5))
        }
    }
}

// Code purpose: protect the public production 6-step default, validated 8/10 alternatives, and the unchanged cosine-Euler scheduler formula.
// Upstream: CosyVoice3Fixed225AcousticRuntime.
// Runtime: Swift Package XCTest, macOS15+/iOS18+.
// Generated: 2026-10-02 America/New_York.
// Changes: 6/8/10 are the public validated Flow choices; production default is 6 while the legacy 10-step formula remains explicitly regression-tested.
