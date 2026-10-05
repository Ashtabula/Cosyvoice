// FixedDecodeMaskTests.swift
// Requirement: verify every fixed-width decode prefix matches the old FP16 attention mask bit for bit.
import CoreML
import XCTest
@testable import CosyVoice3Core
@available(iOS 18.0, macOS 15.0, *)
final class FixedDecodeMaskTests: XCTestCase {
    func testAllPrefixesMatchIndependentOriginalMasks() throws {
        for width in [449, 512] {
            for logical in [32, 151, 224] {
                let mask = try MLMultiArray(shape: [1,1,1,NSNumber(value:width)], dataType: .float16)
                try CosyVoice3FP16StatefulLLMSession.initializeFixedMask(mask, validLength: logical + 1)
                let bits = mask.dataPointer.assumingMemoryBound(to: UInt16.self)
                for position in logical..<width {
                    try CosyVoice3FP16StatefulLLMSession.advanceFixedMask(mask, absolutePosition: position)
                    for i in 0..<width { XCTAssertEqual(bits[i], i <= position ? 0 : 0xfc00, "width=\(width) position=\(position) index=\(i)") }
                }
                XCTAssertThrowsError(try CosyVoice3FP16StatefulLLMSession.advanceFixedMask(mask, absolutePosition: width))
            }
        }
    }
}
// Purpose: independent attention boundary equivalence plus overflow fail-closed; upstream: original per-prefix mask algorithm.
// Environment: Swift XCTest macOS15+/iOS18+; generated 2026-10-05 America/New_York; added lines 1-26.
