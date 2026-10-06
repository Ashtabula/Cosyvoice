// OverlapAddNormTests.swift
// Requirement: direct norm output must match the independent original Float Array algorithm bit for bit at bucket boundaries.
import CoreML
import XCTest
@testable import CosyVoice3Core

@available(iOS 18.0, macOS 15.0, *)
final class OverlapAddNormTests: XCTestCase {
    func testOriginalWindowSummationBitsAtAllBucketBoundaries() throws {
        for n in [1,128,129,256,257,260,384,385,450] {
            let sampleCount=960*n
            let window=(0..<16).map { Float(0.5-0.5*cos(2*Double.pi*Double($0)/16)) }
            var expected=[Float](repeating:0,count:sampleCount)
            for sample in 0..<sampleCount {
                let position=sample+8
                let low=max(0,(position-12)/4),high=min(sampleCount/4,position/4)
                if low<=high {
                    for frame in low...high {
                        let index=position-4*frame
                        if index>=0,index<16 { expected[sample] += window[index]*window[index] }
                    }
                }
            }
            let actual=try CosyVoice3DynamicAcousticRuntime.overlapAddNorm(sampleCount:sampleCount)
            XCTAssertEqual(actual.shape.map(\.intValue),[1,1,sampleCount])
            XCTAssertEqual(actual.dataType,.float32)
            let pointer=actual.dataPointer.assumingMemoryBound(to:Float.self)
            for i in expected.indices { XCTAssertEqual(pointer[i].bitPattern,expected[i].bitPattern,"N=\(n) sample=\(i)") }
        }
    }
}
// Purpose: preserve exact window, edge handling and Float accumulation ordering with independent old implementation.
// Upstream: original DynamicAcousticRuntime.overlapAddNorm; environment Swift6 XCTest/macOS15+/iOS18+.
// Generated2026-10-06 07:27 EDT America/New_York; new file; existing tests unchanged.
