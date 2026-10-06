// FlowOwnedBufferTests.swift
// Requirement: request-local owned Flow scratch must preserve original copy bytes and never alias the source.
import CoreML
import XCTest
@testable import CosyVoice3Core

@available(iOS 18.0, macOS 15.0, *)
final class FlowOwnedBufferTests: XCTestCase {
    func testSixRefillsReuseIdentityAndPreserveEveryFloatBit() throws {
        let source = try MLMultiArray(shape: [2,7,1024], dataType: .float32)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["h": source])
        var scratch: MLMultiArray?
        for step in 0..<6 {
            let pointer = source.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<source.count { pointer[i] = Float(bitPattern: UInt32(0x3f000000 + i + step * 33)) }
            let old = try CosyVoice3DynamicAcousticRuntime.ownedFloat32Output(provider, "h")
            let actual = try CosyVoice3DynamicAcousticRuntime.ownedFloat32Output(provider, "h", reuse: scratch)
            if let scratch { XCTAssertTrue(actual === scratch) }
            XCTAssertFalse(actual === source)
            XCTAssertEqual(Data(bytes: old.dataPointer, count: old.count * 4), Data(bytes: actual.dataPointer, count: actual.count * 4))
            scratch = actual
        }
    }
    func testStridedFallbackAndIncompatibleScratch() throws {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 40)
        pointer.initialize(repeating: -99, count: 40)
        defer { pointer.deinitialize(count: 40); pointer.deallocate() }
        let source = try MLMultiArray(dataPointer: pointer, shape: [2,3], dataType: .float32, strides: [10,2], deallocator: nil)
        for i in 0..<source.count { source[i] = NSNumber(value: Float(i) / 7) }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["h": source])
        let scratch = try MLMultiArray(shape: [2,3], dataType: .float32)
        let actual = try CosyVoice3DynamicAcousticRuntime.ownedFloat32Output(provider, "h", reuse: scratch)
        XCTAssertTrue(actual === scratch)
        for i in 0..<source.count { XCTAssertEqual(actual[i].floatValue.bitPattern, source[i].floatValue.bitPattern) }
        let wrong = try MLMultiArray(shape: [6], dataType: .float32)
        let replacement = try CosyVoice3DynamicAcousticRuntime.ownedFloat32Output(provider, "h", reuse: wrong)
        XCTAssertFalse(replacement === wrong)
        XCTAssertEqual(replacement.shape, source.shape)
    }
}
// Purpose: independent original allocation vs reused-storage byte parity; source and destination lifetime stay in test scope.
// Upstream DynamicAcousticRuntime ownedFloat32Output; Swift6/CoreML/XCTest macOS15+/iOS18+; generated2026-10-06.
