// CosyVoice3AcousticRuntime.swift
// Requirement: validated fixed225 Flow -> 10-step CFG Euler -> 450-frame mel -> FP64-F0/HiFT; support baked or dynamic per-reference conditioning.
import CoreML
import Foundation

enum CosyVoice3AcousticError: Error, Equatable {
    case invalidTokenCount(Int)
    case missingOutput(String)
    case missingReferenceTensor(String)
    case invalidShape(String,[Int])
    case nonFinite(String)
    case invalidPCMCount(Int)
}

@available(iOS 18.0, macOS 15.0, *)
final class CosyVoice3Fixed225AcousticRuntime: CosyVoice3AcousticRuntime, @unchecked Sendable {
    static let speechTokenCount=225, flowFrames=752, promptFrames=302, outputMelFrames=450, sampleRate=24000, expectedPCMCount=216000
    private let conditions:MLModel, shards:[MLModel], hift:MLModel, f0:CosyVoice3HiFTDoubleF0, flowMask:MLMultiArray, initialNoise:MLMultiArray

    init(conditions:MLModel, shards:[MLModel], hift:MLModel, f0:CosyVoice3HiFTDoubleF0, flowMask:MLMultiArray, initialNoise:MLMultiArray) throws {
        guard shards.count==6 else { throw CosyVoice3AcousticError.invalidShape("flow_shards",[shards.count]) }
        guard flowMask.shape.map(\.intValue)==[2,1,752] else { throw CosyVoice3AcousticError.invalidShape("flow_mask",flowMask.shape.map(\.intValue)) }
        guard initialNoise.shape.map(\.intValue)==[1,80,752] else { throw CosyVoice3AcousticError.invalidShape("flow_x",initialNoise.shape.map(\.intValue)) }
        self.conditions=conditions; self.shards=shards; self.hift=hift; self.f0=f0; self.flowMask=flowMask; self.initialNoise=initialNoise
    }

    func synthesize(speechTokens:[Int], prepared:CosyVoice3PreparedRequest) async throws -> CosyVoice3Audio {
        guard speechTokens.count==Self.speechTokenCount else { throw CosyVoice3AcousticError.invalidTokenCount(speechTokens.count) }
        let tokens=try MLMultiArray(shape:[1,225],dataType:.int32), tp=tokens.dataPointer.bindMemory(to:Int32.self,capacity:225)
        for i in 0..<225 { tp[i]=Int32(speechTokens[i]) }

        let conditionProvider: MLFeatureProvider
        if let reference = prepared.referenceConditioning {
            guard let promptTokens=reference.tensors["flow_prompt_speech_token"] else { throw CosyVoice3AcousticError.missingReferenceTensor("flow_prompt_speech_token") }
            guard let promptFeat=reference.tensors["prompt_speech_feat"] else { throw CosyVoice3AcousticError.missingReferenceTensor("prompt_speech_feat") }
            guard let speaker=reference.tensors["flow_embedding"] else { throw CosyVoice3AcousticError.missingReferenceTensor("flow_embedding") }
            conditionProvider = try MLDictionaryFeatureProvider(dictionary:[
                "tokens":tokens, "prompt_tokens":promptTokens, "prompt_feat":promptFeat, "speaker":speaker
            ])
        } else {
            conditionProvider = try MLDictionaryFeatureProvider(dictionary:["tokens":tokens])
        }

        let conditionResult=try await conditions.prediction(from:conditionProvider)
        let mu=try output(conditionResult,"mu"), spks=try output(conditionResult,"spks"), cond=try output(conditionResult,"cond")
        var x=(0..<initialNoise.count).map { initialNoise[$0].floatValue }
        let batchX=try MLMultiArray(shape:[2,80,752],dataType:.float32), t=try MLMultiArray(shape:[2],dataType:.float32)
        let span:[Float]=(0...10).map { 1-cos(Float($0)/10*Float.pi/2) }; var currentT=span[0], dt=span[1]-span[0]
        for step in 0..<10 {
            let p=batchX.dataPointer.assumingMemoryBound(to:Float.self)
            x.withUnsafeBufferPointer {
                p.update(from:$0.baseAddress!,count:x.count)
                p.advanced(by:x.count).update(from:$0.baseAddress!,count:x.count)
            }
            t[0]=NSNumber(value:currentT); t[1]=NSNumber(value:currentT)
            var feed:[String:MLMultiArray]=["x":batchX,"mask":flowMask,"mu":mu,"t":t,"spks":spks,"cond":cond], velocity:MLMultiArray?
            for i in shards.indices {
                let result=try await shards[i].prediction(from:try MLDictionaryFeatureProvider(dictionary:feed))
                if i==0 { feed=["h":try output(result,"h"),"te":try output(result,"te"),"mask":flowMask] }
                else if i==shards.count-1 { velocity=try output(result,"velocity") }
                else { feed["h"]=try output(result,"h_out") }
            }
            guard let velocity else { throw CosyVoice3AcousticError.missingOutput("velocity") }
            for i in x.indices { x[i] += dt*(1.7*velocity[i].floatValue-0.7*velocity[i+x.count].floatValue) }
            currentT += dt; if step<9 { dt=span[step+2]-currentT }
        }
        guard x.allSatisfy(\.isFinite) else { throw CosyVoice3AcousticError.nonFinite("flow") }

        let mel=try MLMultiArray(shape:[1,80,450],dataType:.float32), mp=mel.dataPointer.assumingMemoryBound(to:Float.self)
        for c in 0..<80 { for j in 0..<450 { mp[c*450+j]=x[c*752+302+j] } }
        let f0Values=try f0.prediction(mel:mel)
        let phase=try MLMultiArray(shape:[1,450,9],dataType:.float32), pp=phase.dataPointer.assumingMemoryBound(to:Float.self)
        var sums=[Double](repeating:0,count:9)
        for frame in 0..<450 {
            for h in 0..<9 {
                let rad=(f0Values[frame].floatValue*Float(h+1)/24000).truncatingRemainder(dividingBy:1)
                sums[h]+=Double(rad); pp[frame*9+h]=Float(sums[h])*Float(2*Double.pi)
            }
        }
        let hiftResult=try await hift.prediction(from:try MLDictionaryFeatureProvider(dictionary:["mel":mel,"f0":f0Values,"phase":phase]))
        let pcm=try output(hiftResult,"pcm")
        let samples=(0..<pcm.count).map { pcm[$0].floatValue }
        guard samples.count==Self.expectedPCMCount else { throw CosyVoice3AcousticError.invalidPCMCount(samples.count) }
        guard samples.allSatisfy(\.isFinite) else { throw CosyVoice3AcousticError.nonFinite("pcm") }
        return .init(samples:samples,sampleRate:Self.sampleRate,channels:1)
    }

    private func output(_ provider:MLFeatureProvider,_ name:String) throws -> MLMultiArray {
        guard let a=provider.featureValue(for:name)?.multiArrayValue else { throw CosyVoice3AcousticError.missingOutput(name) }
        return a
    }
}

// Purpose: preserve the validated fixed225 acoustic math while allowing a separately parity-gated generic reference-conditioning graph.
// Upstream: FullPipelineBenchmark.swift and export_pipeline_acoustics.py at CosyVoice3_NPU@8789402.
// Runtime: iOS18+ CoreML.
// Generated: 2026-10-02 America/New_York.
