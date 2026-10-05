// DecodeProviderParityTests.swift
// Requirement: compare the reused provider against independent original per-prefix providers using identical frozen LLMs and two separate KV states.
import CoreML
import Foundation
import XCTest
@testable import CosyVoice3Core
@available(iOS 18.0, macOS 15.0, *)
final class DecodeProviderParityTests: XCTestCase {
    func testFrozenStatefulLogitsMatchOriginalProviders() throws {
        guard let path = ProcessInfo.processInfo.environment["COSYVOICE3_FROZEN_ASSET_ROOT"] else { throw XCTSkip("Set frozen asset root for host stateful numerical comparison") }
        let root = URL(fileURLWithPath: path)
        let m = try CosyVoice3AssetLoader.loadManifest(root: root)
        let prefill = try CosyVoice3AssetLoader.llmModel(root: root, path: m.llmPrefill)
        let decode = try CosyVoice3AssetLoader.llmModel(root: root, path: m.llmDecode)
        func array(_ shape: [Int]) throws -> MLMultiArray {
            let a = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float16)
            memset(a.dataPointer,0,a.count*2); return a
        }
        let px = try array([1,224,896]), pc = try array([1,1,224,64]), ps = try array([1,1,224,64]), pm = try array([1,1,224,224])
        let cosBits = pc.dataPointer.assumingMemoryBound(to: UInt16.self)
        for i in 0..<pc.count { cosBits[i] = 0x3c00 }
        let maskBits = pm.dataPointer.assumingMemoryBound(to: UInt16.self)
        for i in 0..<224 { for j in 0..<224 { maskBits[i*224+j] = j <= i ? 0 : 0xfc00 } }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["x":px,"cos":pc,"sin":ps,"mask":pm])
        for logical in [32,224] {
        let originalState = prefill.makeState()
        let session = try CosyVoice3FP16StatefulLLMSession(prefillModel: prefill,decodeModel: decode,diagnosticHostWriteMask:true,logicalPrefixLength:logical)
        _ = try prefill.prediction(from: provider,using:originalState)
        _ = try session.prefill(provider)
        let x = try array([1,1,896]), c = try array([1,1,1,64]), s = try array([1,1,1,64])
        let cp = c.dataPointer.assumingMemoryBound(to:UInt16.self)
        for i in 0..<64 { cp[i] = 0x3c00 }
        let embedding = Data(bytes:x.dataPointer,count:x.count*2)
        let cos = Data(bytes:c.dataPointer,count:c.count*2), sin = Data(bytes:s.dataPointer,count:s.count*2)
        var maximum:Double = 0
        for position in logical..<(logical+64) {
            let mask = try array([1,1,1,512]), write = try array([1,1,512,1])
            let p = mask.dataPointer.assumingMemoryBound(to:UInt16.self)
            for i in (position+1)..<512 { p[i] = 0xfc00 }
            write.dataPointer.assumingMemoryBound(to:UInt16.self)[position] = 0x3c00
            let original = try decode.prediction(from:MLDictionaryFeatureProvider(dictionary:["x":x,"cos":c,"sin":s,"mask":mask,"write_mask":write]),using:originalState)
            let reused = try session.decode(embedding:embedding,cos:cos,sin:sin,absolutePosition:position)
            let a = try XCTUnwrap(original.featureValue(for:"logits")?.multiArrayValue)
            let b = try XCTUnwrap(reused.featureValue(for:"logits")?.multiArrayValue)
            XCTAssertEqual(a.count,b.count)
            for i in 0..<a.count {
                let delta = abs(a[i].doubleValue-b[i].doubleValue)
                XCTAssertTrue(delta.isFinite)
                maximum = max(maximum,delta)
            }
        }
        print("[COSY-DECODE-PROVIDER-PARITY] logicalPrefix=\(logical) steps=64 maxAbs=\(maximum) scope=HOST_ZERO_EMBEDDING_STATEFUL_CONTROL")
        XCTAssertEqual(maximum,0)
        }
    }
}
// Purpose: test actual CoreML mutable-provider/KV behavior, independent of mask helper implementation.
// Upstream: original independent per-prefix providers and frozen CPU_ONLY LLMs; environment: macOS15+ Swift XCTest.
// Generated: 2026-10-05 America/New_York; all lines new. Synthetic zero embeddings are a numerical control, not speech-quality evidence.
