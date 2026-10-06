// LogitsBufferTests.swift
// Requirement: original FP16/FP32 materialization bits and sampling draws must survive request-local buffer reuse.
import CoreML
import XCTest
@testable import CosyVoice3Core

private struct LogitsRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@available(iOS 18.0, macOS 15.0, *)
final class LogitsBufferTests: XCTestCase {
    func testBothDtypesMatchOriginalConversionAndReuseStorage() throws {
        for dtype: MLMultiArrayDataType in [.float16, .float32] {
            let array=try MLMultiArray(shape:[1,6761],dataType:dtype)
            let provider=try MLDictionaryFeatureProvider(dictionary:["logits":array])
            var scratch=[Float](repeating:0,count:6761)
            let address=scratch.withUnsafeBufferPointer { UInt(bitPattern:$0.baseAddress!) }
            for iteration in 0..<8 {
                let values=(0..<6761).map { Float(sin(Double($0+iteration)*0.0137)*2) }
                let expected:[Float]
                if dtype == .float16 {
                    let pointer=array.dataPointer.assumingMemoryBound(to:UInt16.self)
                    for i in values.indices { pointer[i]=Float16(values[i]).bitPattern }
                    expected=(0..<6761).map { Float(Float16(bitPattern:pointer[$0])) }
                } else {
                    values.withUnsafeBufferPointer { array.dataPointer.assumingMemoryBound(to:Float.self).update(from:$0.baseAddress!,count:6761) }
                    expected=values
                }
                try CosyVoice3LLMRuntime.fillLogits(provider,into:&scratch)
                XCTAssertEqual(scratch.map(\.bitPattern),expected.map(\.bitPattern))
                XCTAssertEqual(scratch.withUnsafeBufferPointer { UInt(bitPattern:$0.baseAddress!) },address)
                var a=LogitsRNG(state:UInt64(iteration+1)),b=a
                let sampler=CosyVoice3RASampler()
                let recent=[42,43,44,6561]
                XCTAssertEqual(try sampler.sample(logits:scratch,decodedTokens:recent,suppressSOS:iteration%2==0,using:&a),try sampler.sample(logits:expected,decodedTokens:recent,suppressSOS:iteration%2==0,using:&b))
                XCTAssertEqual(a.state,b.state)
            }
        }
    }

    func testInvalidOutputFailsClosed() throws {
        let array=try MLMultiArray(shape:[1,6761],dataType:.float16)
        var scratch=[Float](repeating:0,count:1)
        let provider=try MLDictionaryFeatureProvider(dictionary:["logits":array])
        XCTAssertThrowsError(try CosyVoice3LLMRuntime.fillLogits(provider,into:&scratch))
        scratch=[Float](repeating:0,count:6761)
        XCTAssertThrowsError(try CosyVoice3LLMRuntime.fillLogits(MLDictionaryFeatureProvider(dictionary:[:]),into:&scratch))
    }
}
// Purpose: independent original-conversion control, storage lifetime reuse and unchanged RAS RNG checks.
// Upstream: original logits copying path and existing sampler; environment Swift6/macOS15+/iOS18+ XCTest.
// Generated2026-10-06 07:24 EDT America/New_York; new test file, no existing assertion weakened.
