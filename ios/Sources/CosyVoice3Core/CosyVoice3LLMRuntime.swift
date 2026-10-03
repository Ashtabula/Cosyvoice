// CosyVoice3LLMRuntime.swift
// Requirement: in-process stateful Core ML decode + native RAS + native embedding/RoPE; no file bridge or Python runtime.
import CoreML
import Foundation

@available(iOS 18.0, macOS 15.0, *)
final class CosyVoice3LLMRuntime: @unchecked Sendable {
    enum RuntimeError: Error { case missingLogits; case invalidLogitsShape([Int]); case unexpectedStop(Int) }
    private let prefillModel:MLModel
    private let decodeModel:MLModel
    private let conditioner:CosyVoice3TokenConditioner
    private let sampler:CosyVoice3RASampler
    init(prefillModel:MLModel, decodeModel:MLModel, conditioner:CosyVoice3TokenConditioner, sampler: CosyVoice3RASampler = .init()) {
        self.prefillModel=prefillModel; self.decodeModel=decodeModel; self.conditioner=conditioner; self.sampler=sampler
    }
    func generate(_ prepared:CosyVoice3PreparedRequest) throws -> [Int] {
        let session=try CosyVoice3FP16StatefulLLMSession(prefillModel:prefillModel,decodeModel:decodeModel,prefixLength:224,diagnosticHostWriteMask:true,logicalPrefixLength:prepared.logicalPrefixLength)
        var output=try session.prefill(prepared.prefillInput), decoded:[Int]=[]
        for step in 0..<prepared.maximumSpeechTokenCount {
            let logits=try Self.logits(output), token=try sampler.sample(logits:logits,decodedTokens:decoded,suppressSOS:step<prepared.minimumSpeechTokenCount)
            if CosyVoice3TokenSemantics.isStop(token) {
                guard token<CosyVoice3TokenSemantics.logitsCount else { throw RuntimeError.unexpectedStop(token) }
                return decoded
            }
            decoded.append(token)

            // Upstream inference_wrapper treats max_len exhaustion as normal completion:
            // the last yielded speech token is returned without running another decode
            // step. The fixed225 publication lane uses the same behavior at its
            // downstream bucket capacity.
            if decoded.count == prepared.maximumSpeechTokenCount {
                return decoded
            }

            let embedding=try conditioner.embeddingFP16(token:token), rope=try conditioner.ropeFP16(position:prepared.logicalPrefixLength+step)
            output=try autoreleasepool {
                try session.decode(
                    embedding:embedding,
                    cos:rope.cos,
                    sin:rope.sin,
                    absolutePosition:prepared.logicalPrefixLength+step
                )
            }
        }
        return decoded
    }
    private static func logits(_ output:MLFeatureProvider) throws -> [Float] {
        let names=["logits","logp","scores"]; guard let array=names.compactMap({output.featureValue(for:$0)?.multiArrayValue}).first else { throw RuntimeError.missingLogits }
        let shape=array.shape.map(\.intValue); guard array.count==CosyVoice3TokenSemantics.logitsCount else { throw RuntimeError.invalidLogitsShape(shape) }
        switch array.dataType {
        case .float32: let p=array.dataPointer.bindMemory(to:Float.self,capacity:array.count); return Array(UnsafeBufferPointer(start:p,count:array.count))
        case .float16: let p=array.dataPointer.bindMemory(to:UInt16.self,capacity:array.count); return (0..<array.count).map { Float(Float16(bitPattern:p[$0])) }
        default: throw RuntimeError.invalidLogitsShape(shape)
        }
    }
}

// Purpose: collapse the former Air<->Mac per-step bridge into a single on-device autoregressive loop; max-length exhaustion is normal upstream completion rather than a runtime error.
// Upstream behavior: fixed512 stateful LLM + sampling_ids/ras_sampling audited at8789402. Stop region is6561...6760; actual EOS is6562.
// Runtime: iOS18+/macOS15+ CoreML State.
// Generated: 2026-10-02 America/New_York.

// Changes 2026-10-02: restore the accepted physical-benchmark per-step autoreleasepool around each Core ML decode call so 225-step temporary Core ML/provider objects do not accumulate until utterance completion; model/state/token math is unchanged.
