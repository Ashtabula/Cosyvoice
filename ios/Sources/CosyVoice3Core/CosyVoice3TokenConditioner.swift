// CosyVoice3TokenConditioner.swift
// Requirement: replace the development host payload by native speech-embedding lookup plus Qwen2 rotary-position values; immutable RoPE rows are precomputed once per engine conditioner.
import Foundation

enum CosyVoice3TokenConditionerError: Error, Equatable { case invalidEmbeddingAsset(Int); case invalidToken(Int); case invalidPosition(Int); case invalidRoPEConfiguration }

struct CosyVoice3RoPEConfiguration: Codable, Sendable, Equatable {
    let headDimension:Int
    let theta:Double
    let maximumPosition:Int
    init(headDimension:Int=64,theta:Double,maximumPosition:Int=512) { self.headDimension=headDimension; self.theta=theta; self.maximumPosition=maximumPosition }
    func validate() throws { guard headDimension>0, headDimension%2==0, theta>0, maximumPosition>0 else { throw CosyVoice3TokenConditionerError.invalidRoPEConfiguration } }
}

final class CosyVoice3TokenConditioner: @unchecked Sendable {
    static let embeddingWidth=896
    private let embeddings:Data
    private let rope:CosyVoice3RoPEConfiguration
    private let cosRows:[Data]
    private let sinRows:[Data]

    convenience init(embeddingURL:URL, rope:CosyVoice3RoPEConfiguration) throws {
        try rope.validate()
        try self.init(embeddingData:Data(contentsOf:embeddingURL),rope:rope)
    }

    init(embeddingData data:Data, rope:CosyVoice3RoPEConfiguration) throws {
        try rope.validate()
        let expected=CosyVoice3TokenSemantics.logitsCount*Self.embeddingWidth*2
        guard data.count==expected else { throw CosyVoice3TokenConditionerError.invalidEmbeddingAsset(data.count) }
        embeddings=data
        self.rope=rope

        let half=rope.headDimension/2
        var cosRows:[Data]=[]
        var sinRows:[Data]=[]
        cosRows.reserveCapacity(rope.maximumPosition)
        sinRows.reserveCapacity(rope.maximumPosition)
        let frequencies=(0..<half).map { 1.0/pow(rope.theta,Double(2*$0)/Double(rope.headDimension)) }
        for position in 0..<rope.maximumPosition {
            var cosValues=[UInt16](repeating:0,count:rope.headDimension)
            var sinValues=[UInt16](repeating:0,count:rope.headDimension)
            for i in 0..<half {
                let angle=Double(position)*frequencies[i]
                let c=Float16(cos(angle)).bitPattern
                let s=Float16(sin(angle)).bitPattern
                cosValues[i]=c; cosValues[i+half]=c
                sinValues[i]=s; sinValues[i+half]=s
            }
            cosRows.append(cosValues.withUnsafeBytes { Data($0) })
            sinRows.append(sinValues.withUnsafeBytes { Data($0) })
        }
        self.cosRows=cosRows
        self.sinRows=sinRows
    }

    func embeddingFP16(token:Int) throws -> Data {
        guard token >= 0 && token < CosyVoice3TokenSemantics.logitsCount else { throw CosyVoice3TokenConditionerError.invalidToken(token) }
        let bytes=Self.embeddingWidth*2
        let start=token*bytes
        return embeddings.subdata(in:start..<start+bytes)
    }

    func ropeFP16(position:Int) throws -> (cos:Data,sin:Data) {
        guard position>=0 && position<rope.maximumPosition else { throw CosyVoice3TokenConditionerError.invalidPosition(position) }
        return (cosRows[position],sinRows[position])
    }
}

// Purpose: native equivalent of the former host bridge's speech_embedding[token] FP16 lookup and Qwen2 RoPE cos/sin payload.
// Upstream: run_instruct2_native_air.py at CosyVoice3_NPU@8789402. Embedding width896 and head dimension64 are derived from the validated 2056-byte bridge ABI.
// Runtime asset: full 6761-row speech_embedding_fp16.bin plus rope theta/max-position in the SDK asset contract; rows6561/6563 are used for SOS/TASK prefill.
// Generated: 2026-10-02 America/New_York.
// Changes 2026-10-02: precompute all 512 immutable FP16 RoPE rows once when the cached conditioner is created instead of repeating pow/cos/sin for every autoregressive token.

// Purpose: accept the existing immutable frontend speech table by Data value sharing; keep standalone URL initialization.
// Upstream: original conditioner, exact byte-count validation/RoPE/row math; environment Swift6/iOS18+/macOS15+.
// Generated2026-10-06 07:32 EDT America/New_York; changed initializer22-31 only, no token or position semantics.
