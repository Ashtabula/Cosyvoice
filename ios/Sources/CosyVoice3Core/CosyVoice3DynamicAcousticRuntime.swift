// CosyVoice3DynamicAcousticRuntime.swift
// Requirement: production-candidate variable-length acoustic runtime using one symbolic Conditions/Flow/HiFT family, exact request shapes, 6/8/10-step CFG Euler, FP64 F0, and manifest-bound maximum stochastic buffers. No padding, buckets, or zero-buffer fallback.
import CoreML
import Foundation

@available(iOS 18.0, macOS 15.0, *)
final class CosyVoice3DynamicAcousticRuntime: CosyVoice3AcousticRuntime, @unchecked Sendable {
    static let sampleRate = 24_000
    static let validatedFlowStepCounts = CosyVoice3FlowSteps.allCases.map(\.rawValue)

    private let conditions: MLModel
    private let shards: [MLModel]
    private let hift: MLModel
    private let f0: CosyVoice3HiFTDoubleF0
    private let contract: CosyVoice3DynamicAcousticAssets
    private let defaultPromptTokens: MLMultiArray
    private let defaultPromptFeat: MLMultiArray
    private let defaultSpeaker: MLMultiArray
    private let flowNoiseMaximum: MLMultiArray
    private let hiftExcitationMaximum: MLMultiArray
    private let flowStepCount: Int

    init(
        conditions: MLModel,
        shards: [MLModel],
        hift: MLModel,
        f0: CosyVoice3HiFTDoubleF0,
        contract: CosyVoice3DynamicAcousticAssets,
        defaultPromptTokens: MLMultiArray,
        defaultPromptFeat: MLMultiArray,
        defaultSpeaker: MLMultiArray,
        flowNoiseMaximum: MLMultiArray,
        hiftExcitationMaximum: MLMultiArray,
        flowStepCount: Int = CosyVoice3FlowSteps.productionDefault.rawValue
    ) throws {
        try contract.validate()
        guard shards.count == 6 else { throw CosyVoice3AcousticError.invalidShape("flow_shards", [shards.count]) }
        guard Self.validatedFlowStepCounts.contains(flowStepCount) else { throw CosyVoice3AcousticError.invalidFlowStepCount(flowStepCount) }
        guard defaultPromptTokens.shape.map(\.intValue) == [1,151] else { throw CosyVoice3AcousticError.invalidShape("default_prompt_tokens", defaultPromptTokens.shape.map(\.intValue)) }
        guard defaultPromptFeat.shape.map(\.intValue) == [1,contract.promptFrameCount,80] else { throw CosyVoice3AcousticError.invalidShape("default_prompt_feat", defaultPromptFeat.shape.map(\.intValue)) }
        guard defaultSpeaker.shape.map(\.intValue) == [1,192] else { throw CosyVoice3AcousticError.invalidShape("default_speaker", defaultSpeaker.shape.map(\.intValue)) }
        guard flowNoiseMaximum.shape.map(\.intValue) == [1,80,contract.maximumFlowFrames] else { throw CosyVoice3AcousticError.invalidShape("flow_noise_maximum", flowNoiseMaximum.shape.map(\.intValue)) }
        guard hiftExcitationMaximum.shape.map(\.intValue) == [1,contract.maximumPCMSamples,9] else { throw CosyVoice3AcousticError.invalidShape("hift_excitation_maximum", hiftExcitationMaximum.shape.map(\.intValue)) }
        guard flowNoiseMaximum.dataType == .float32, hiftExcitationMaximum.dataType == .float32,
              Self.isContiguous(flowNoiseMaximum), Self.isContiguous(hiftExcitationMaximum) else {
            throw CosyVoice3AcousticError.invalidShape("dynamic_stochastic_buffers", [])
        }

        self.conditions = conditions
        self.shards = shards
        self.hift = hift
        self.f0 = f0
        self.contract = contract
        self.defaultPromptTokens = defaultPromptTokens
        self.defaultPromptFeat = defaultPromptFeat
        self.defaultSpeaker = defaultSpeaker
        self.flowNoiseMaximum = flowNoiseMaximum
        self.hiftExcitationMaximum = hiftExcitationMaximum
        self.flowStepCount = flowStepCount
    }

    func synthesize(speechTokens: [Int], prepared: CosyVoice3PreparedRequest) async throws -> CosyVoice3Audio {
        let n = speechTokens.count
        guard n >= contract.speechTokenMinimum, n <= contract.speechTokenMaximum else {
            throw CosyVoice3AcousticError.invalidTokenCount(n)
        }
        let p = contract.promptFrameCount
        let tFrames = p + 2 * n
        let g = 2 * n
        let samplesCount = 960 * n

        let tokens = try MLMultiArray(shape: [1,NSNumber(value:n)], dataType: .int32)
        let tokenPointer = tokens.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<n { tokenPointer[i] = Int32(speechTokens[i]) }

        let promptTokens: MLMultiArray
        let promptFeat: MLMultiArray
        let speaker: MLMultiArray
        if let reference = prepared.referenceConditioning {
            guard let value = reference.tensors["flow_prompt_speech_token"] else { throw CosyVoice3AcousticError.missingReferenceTensor("flow_prompt_speech_token") }
            guard let feat = reference.tensors["prompt_speech_feat"] else { throw CosyVoice3AcousticError.missingReferenceTensor("prompt_speech_feat") }
            guard let embedding = reference.tensors["flow_embedding"] else { throw CosyVoice3AcousticError.missingReferenceTensor("flow_embedding") }
            promptTokens = value
            promptFeat = feat
            speaker = embedding
        } else {
            promptTokens = defaultPromptTokens
            promptFeat = defaultPromptFeat
            speaker = defaultSpeaker
        }

        let conditionResult = try await conditions.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
            "tokens": tokens,
            "prompt_tokens": promptTokens,
            "prompt_feat": promptFeat,
            "speaker": speaker
        ]))
        let mu = try output(conditionResult, "mu")
        let spks = try output(conditionResult, "spks")
        let cond = try output(conditionResult, "cond")
        guard mu.shape.map(\.intValue) == [2,80,tFrames] else { throw CosyVoice3AcousticError.invalidShape("mu", mu.shape.map(\.intValue)) }
        guard spks.shape.map(\.intValue) == [2,80] else { throw CosyVoice3AcousticError.invalidShape("spks", spks.shape.map(\.intValue)) }
        guard cond.shape.map(\.intValue) == [2,80,tFrames] else { throw CosyVoice3AcousticError.invalidShape("cond", cond.shape.map(\.intValue)) }

        var x = flowNoisePrefix(frameCount: tFrames)
        let mask = try ones(shape: [2,1,tFrames])
        let batchX = try MLMultiArray(shape: [2,80,NSNumber(value:tFrames)], dataType: .float32)
        let time = try MLMultiArray(shape: [2], dataType: .float32)
        let span = try CosyVoice3Fixed225AcousticRuntime.flowTimeSpan(stepCount: flowStepCount)
        var currentT = span[0]
        var dt = span[1] - span[0]

        for step in 0..<flowStepCount {
            let batchPointer = batchX.dataPointer.assumingMemoryBound(to: Float.self)
            x.withUnsafeBufferPointer {
                batchPointer.update(from: $0.baseAddress!, count: x.count)
                batchPointer.advanced(by: x.count).update(from: $0.baseAddress!, count: x.count)
            }
            time[0] = NSNumber(value: currentT)
            time[1] = NSNumber(value: currentT)

            var feed: [String: MLMultiArray] = [
                "x": batchX, "mask": mask, "mu": mu, "t": time, "spks": spks, "cond": cond
            ]
            var velocity: MLMultiArray?
            for index in shards.indices {
                let result = try await shards[index].prediction(from: try MLDictionaryFeatureProvider(dictionary: feed))
                if index == 0 {
                    let h = try output(result, "h")
                    let te = try output(result, "te")
                    guard h.shape.map(\.intValue) == [2,tFrames,1024] else { throw CosyVoice3AcousticError.invalidShape("h", h.shape.map(\.intValue)) }
                    guard te.shape.map(\.intValue) == [2,1024] else { throw CosyVoice3AcousticError.invalidShape("te", te.shape.map(\.intValue)) }
                    feed = ["h":h, "te":te, "mask":mask]
                } else if index == shards.count - 1 {
                    velocity = try output(result, "velocity")
                } else {
                    let h = try output(result, "h_out")
                    guard h.shape.map(\.intValue) == [2,tFrames,1024] else { throw CosyVoice3AcousticError.invalidShape("h_out", h.shape.map(\.intValue)) }
                    feed["h"] = h
                }
            }

            guard let velocity, velocity.count == x.count * 2 else {
                throw CosyVoice3AcousticError.invalidShape("velocity", velocity?.shape.map(\.intValue) ?? [])
            }
            if velocity.dataType == .float32, Self.isContiguous(velocity) {
                let pointer = velocity.dataPointer.assumingMemoryBound(to: Float.self)
                for i in x.indices { x[i] += dt * (1.7 * pointer[i] - 0.7 * pointer[i + x.count]) }
            } else {
                for i in x.indices { x[i] += dt * (1.7 * velocity[i].floatValue - 0.7 * velocity[i + x.count].floatValue) }
            }
            currentT += dt
            if step < flowStepCount - 1 { dt = span[step + 2] - currentT }
        }
        guard x.allSatisfy(\.isFinite) else { throw CosyVoice3AcousticError.nonFinite("flow") }

        let mel = try MLMultiArray(shape: [1,80,NSNumber(value:g)], dataType: .float32)
        let melPointer = mel.dataPointer.assumingMemoryBound(to: Float.self)
        for channel in 0..<80 {
            for frame in 0..<g {
                melPointer[channel * g + frame] = x[channel * tFrames + p + frame]
            }
        }

        let f0Values = try f0.prediction(mel: mel)
        guard f0Values.shape.map(\.intValue) == [1,g] else { throw CosyVoice3AcousticError.invalidShape("f0", f0Values.shape.map(\.intValue)) }

        let phase = try MLMultiArray(shape: [1,NSNumber(value:g),9], dataType: .float32)
        let phasePointer = phase.dataPointer.assumingMemoryBound(to: Float.self)
        var phaseSums = [Double](repeating: 0, count: 9)
        for frame in 0..<g {
            for harmonic in 0..<9 {
                let radians = (f0Values[frame].floatValue * Float(harmonic + 1) / Float(Self.sampleRate)).truncatingRemainder(dividingBy: 1)
                phaseSums[harmonic] += Double(radians)
                phasePointer[frame * 9 + harmonic] = Float(phaseSums[harmonic]) * Float(2 * Double.pi)
            }
        }

        let excitation = try hiftExcitationPrefix(sampleCount: samplesCount)
        let norm = try overlapAddNorm(sampleCount: samplesCount)
        let hiftResult = try await hift.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
            "mel": mel, "f0": f0Values, "phase": phase, "noise": excitation, "norm": norm
        ]))
        let pcm = try output(hiftResult, "pcm")
        guard pcm.shape.map(\.intValue) == [1,samplesCount] else { throw CosyVoice3AcousticError.invalidShape("pcm", pcm.shape.map(\.intValue)) }
        let samples = Self.floatValues(pcm)
        guard samples.count == samplesCount else { throw CosyVoice3AcousticError.invalidPCMCount(samples.count) }
        guard samples.allSatisfy(\.isFinite) else { throw CosyVoice3AcousticError.nonFinite("pcm") }
        return .init(samples: samples, sampleRate: Self.sampleRate, channels: 1)
    }

    private func flowNoisePrefix(frameCount: Int) -> [Float] {
        let maximumFrames = contract.maximumFlowFrames
        let source = flowNoiseMaximum.dataPointer.assumingMemoryBound(to: Float.self)
        var result = [Float](repeating: 0, count: 80 * frameCount)
        result.withUnsafeMutableBufferPointer { output in
            for channel in 0..<80 {
                output.baseAddress!.advanced(by: channel * frameCount).update(
                    from: source.advanced(by: channel * maximumFrames),
                    count: frameCount
                )
            }
        }
        return result
    }

    private func hiftExcitationPrefix(sampleCount: Int) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: [1,NSNumber(value:sampleCount),9], dataType: .float32)
        let count = sampleCount * 9
        result.dataPointer.assumingMemoryBound(to: Float.self).update(
            from: hiftExcitationMaximum.dataPointer.assumingMemoryBound(to: Float.self),
            count: count
        )
        return result
    }

    private func overlapAddNorm(sampleCount: Int) throws -> MLMultiArray {
        let window = (0..<16).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 16)) }
        var weights = [Float](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            let position = sample + 8
            let low = max(0, (position - 12) / 4)
            let high = min(sampleCount / 4, position / 4)
            if low <= high {
                for frame in low...high {
                    let index = position - 4 * frame
                    if index >= 0, index < 16 { weights[sample] += window[index] * window[index] }
                }
            }
        }
        let result = try MLMultiArray(shape: [1,1,NSNumber(value:sampleCount)], dataType: .float32)
        weights.withUnsafeBufferPointer {
            result.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: weights.count)
        }
        return result
    }

    private func ones(shape: [Int]) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        let pointer = result.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<result.count { pointer[i] = 1 }
        return result
    }

    private func output(_ provider: MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        guard let value = provider.featureValue(for: name)?.multiArrayValue else { throw CosyVoice3AcousticError.missingOutput(name) }
        return value
    }

    private static func isContiguous(_ array: MLMultiArray) -> Bool {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count == strides.count else { return false }
        var expected = 1
        for index in shape.indices.reversed() {
            if strides[index] != expected { return false }
            expected *= shape[index]
        }
        return true
    }

    private static func floatValues(_ array: MLMultiArray) -> [Float] {
        if array.dataType == .float32, isContiguous(array) {
            return Array(UnsafeBufferPointer(start: array.dataPointer.assumingMemoryBound(to: Float.self), count: array.count))
        }
        return (0..<array.count).map { array[$0].floatValue }
    }
}

// Code purpose: production-candidate exact-shape dynamic acoustic runtime for the full manifest-declared speech-token envelope.
// Upstream source: validated CosyVoice3 fixed225 acoustic math plus experiment/ios-dynamic-acoustic symbolic Conditions/Flow/HiFT execution contract.
// Runtime environment: iOS18+/macOS15+ CoreML; request-scoped model lifetime is owned by CosyVoice3Engine.
// Generated time: 2026-10-04 America/New_York.
// Changes: variable N/T/G/PCM shapes; generic default/custom reference conditioning; manifest-bound max Flow noise and HiFT excitation prefixes; no zero-buffer fallback, padding, bucket substitution, or production promotion claim.
