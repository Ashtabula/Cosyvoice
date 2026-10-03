// FlowSchedulerTests.swift
// Requirement: production 10-step cosine Euler schedule must remain byte-for-byte formula equivalent while validation-only 8/6 step schedules stay bounded and monotonic.
@testable import CosyVoice3Core
import XCTest

@available(iOS 18.0, macOS 15.0, *)
final class FlowSchedulerTests: XCTestCase {
    func testProductionTenStepScheduleMatchesPreviousFormula() throws {
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

// Code purpose: protect the production 10-step schedule and validation-only 10/8/6 scheduler contract.
// Upstream: CosyVoice3Fixed225AcousticRuntime.
// Runtime: Swift Package XCTest, macOS15+/iOS18+.
// Generated: 2026-10-02 America/New_York.
// Changes: new validation coverage for generalized Flow step count without changing production default.
