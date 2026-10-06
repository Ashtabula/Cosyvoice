// BorrowedEmbeddingTests.swift
// Requirement: compare scoped row and real input memcpy to independent original Data.subdata, including fail-closed bounds.
import CoreML
import XCTest
@testable import CosyVoice3Core

@available(iOS 18.0, macOS 15.0, *)
final class BorrowedEmbeddingTests: XCTestCase {
    func testAllRowsMatchOriginalAndCopyExactBytes() throws {
        let count=6761*896*2
        var bytes=Data(repeating:0,count:count)
        bytes.withUnsafeMutableBytes { (b:UnsafeMutableRawBufferPointer) in
            for i in 0..<count { b[i]=UInt8(truncatingIfNeeded:(i &* 17) ^ (i >> 8)) }
        }
        let conditioner=try CosyVoice3TokenConditioner(embeddingData:bytes,rope:.init(theta:1_000_000))
        let input=try MLMultiArray(shape:[1,1,896],dataType:.float16)
        for token in 0..<6761 {
            let old=try conditioner.embeddingFP16(token:token)
            try conditioner.withEmbeddingFP16(token:token) { borrowed in
                XCTAssertEqual(Data(borrowed),old)
                try CosyVoice3FP16StatefulLLMSession.copyEmbeddingBytes(borrowed,to:input)
            }
            XCTAssertEqual(Data(bytes:input.dataPointer,count:1792),old)
        }
        XCTAssertThrowsError(try conditioner.withEmbeddingFP16(token:-1) { _ in XCTFail("invalid token body") })
        XCTAssertThrowsError(try conditioner.withEmbeddingFP16(token:6761) { _ in XCTFail("invalid token body") })
        XCTAssertThrowsError(try Data([0]).withUnsafeBytes { try CosyVoice3FP16StatefulLLMSession.copyEmbeddingBytes($0,to:input) })
    }
}
// Purpose: independent byte-level original-row/control and actual decoder input-copy parity for all6761 rows.
// Upstream original conditioner and session; Swift6/macOS15+/iOS18+ XCTest; generated2026-10-06 08:14 EDT.
// New test file; no assertion weakened or model math changed.
