// CosyVoice3DynamicAcousticRuntime.swift
// Requirement: production-candidate variable-length acoustic runtime using one symbolic Conditions/Flow/HiFT family, exact request shapes, 6/8/10-step CFG Euler, FP64 F0, and manifest-bound maximum stochastic buffers. No padding, buckets, or zero-buffer fallback.
import CoreML
import Foundation

@available(iOS 18.0, macOS 15.0, *)
final class CosyVoice3DynamicAcousticRuntime: CosyVoice3AcousticRuntime, @unchecked Sendable {
    static let sampleRate = 24_000
    static let validatedFlowStepCounts = CosyVoice3FlowSteps.allCases.map(\.rawValue)

    private enum AcousticContract: Sendable {
        case dynamic(CosyVoice3DynamicAcousticAssets)
        case enumerated(CosyVoice3EnumeratedAcousticAssets)

        var speechTokenMinimum: Int {
            switch self { case .dynamic(let v): return v.speechTokenMinimum; case .enumerated(let v): return v.speechTokenMinimum }
        }
        var speechTokenMaximum: Int {
            switch self { case .dynamic(let v): return v.speechTokenMaximum; case .enumerated(let v): return v.speechTokenMaximum }
        }
        var promptFrameCount: Int {
            switch self { case .dynamic(let v): return v.promptFrameCount; case .enumerated(let v): return v.promptFrameCount }
        }
        var maximumFlowFrames: Int {
            switch self { case .dynamic(let v): return v.maximumFlowFrames; case .enumerated(let v): return v.maximumFlowFrames }
        }
        var maximumPCMSamples: Int {
            switch self { case .dynamic(let v): return v.maximumPCMSamples; case .enumerated(let v): return v.maximumPCMSamples }
        }
        func functionName(forSpeechTokenCount n: Int) throws -> String? {
            switch self {
            case .dynamic: return nil
            case .enumerated(let value): return try value.functionName(forSpeechTokenCount: n)
            }
        }
        func validate() throws {
            switch self { case .dynamic(let v): try v.validate(); case .enumerated(let v): try v.validate() }
        }
    }

    private let assetRoot: URL
    private let conditionsPath: String
    private let flowShardPaths: [String]
    private let hiftPath: String
    private let f0: CosyVoice3HiFTDoubleF0
    private let contract: AcousticContract
    private let defaultPromptTokens: MLMultiArray
    private let defaultPromptFeat: MLMultiArray
    private let defaultSpeaker: MLMultiArray
    private let flowNoiseMaximum: MLMultiArray
    private let hiftExcitationMaximum: MLMultiArray
    private let flowStepCount: Int
    private let progress: (@Sendable (String) -> Void)?
    private var phaseMilliseconds: [String: Double] = [:]
    private var firstCallMilliseconds: [String: Double] = [:]
    private var phaseCalls: [String: Int] = [:]
    private func recordPhase(_ name: String, since started: UInt64, loadBefore: Double) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000 - (modelLoadMilliseconds - loadBefore)
        if phaseCalls[name, default: 0] == 0 { firstCallMilliseconds[name] = elapsed }
        phaseMilliseconds[name, default: 0] += elapsed
        phaseCalls[name, default: 0] += 1
    }
    private(set) var modelLoadMilliseconds: Double = 0

    convenience init(
        assetRoot: URL,
        conditionsPath: String,
        flowShardPaths: [String],
        hiftPath: String,
        f0: CosyVoice3HiFTDoubleF0,
        contract: CosyVoice3DynamicAcousticAssets,
        defaultPromptTokens: MLMultiArray,
        defaultPromptFeat: MLMultiArray,
        defaultSpeaker: MLMultiArray,
        flowNoiseMaximum: MLMultiArray,
        hiftExcitationMaximum: MLMultiArray,
        flowStepCount: Int = CosyVoice3FlowSteps.productionDefault.rawValue,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws {
        try self.init(
            assetRoot: assetRoot,
            conditionsPath: conditionsPath,
            flowShardPaths: flowShardPaths,
            hiftPath: hiftPath,
            f0: f0,
            contract: .dynamic(contract),
            defaultPromptTokens: defaultPromptTokens,
            defaultPromptFeat: defaultPromptFeat,
            defaultSpeaker: defaultSpeaker,
            flowNoiseMaximum: flowNoiseMaximum,
            hiftExcitationMaximum: hiftExcitationMaximum,
            flowStepCount: flowStepCount,
            progress: progress
        )
    }

    convenience init(
        assetRoot: URL,
        conditionsPath: String,
        flowShardPaths: [String],
        hiftPath: String,
        f0: CosyVoice3HiFTDoubleF0,
        contract: CosyVoice3EnumeratedAcousticAssets,
        defaultPromptTokens: MLMultiArray,
        defaultPromptFeat: MLMultiArray,
        defaultSpeaker: MLMultiArray,
        flowNoiseMaximum: MLMultiArray,
        hiftExcitationMaximum: MLMultiArray,
        flowStepCount: Int = CosyVoice3FlowSteps.productionDefault.rawValue,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws {
        try self.init(
            assetRoot: assetRoot,
            conditionsPath: conditionsPath,
            flowShardPaths: flowShardPaths,
            hiftPath: hiftPath,
            f0: f0,
            contract: .enumerated(contract),
            defaultPromptTokens: defaultPromptTokens,
            defaultPromptFeat: defaultPromptFeat,
            defaultSpeaker: defaultSpeaker,
            flowNoiseMaximum: flowNoiseMaximum,
            hiftExcitationMaximum: hiftExcitationMaximum,
            flowStepCount: flowStepCount,
            progress: progress
        )
    }

    private init(
        assetRoot: URL,
        conditionsPath: String,
        flowShardPaths: [String],
        hiftPath: String,
        f0: CosyVoice3HiFTDoubleF0,
        contract: AcousticContract,
        defaultPromptTokens: MLMultiArray,
        defaultPromptFeat: MLMultiArray,
        defaultSpeaker: MLMultiArray,
        flowNoiseMaximum: MLMultiArray,
        hiftExcitationMaximum: MLMultiArray,
        flowStepCount: Int,
        progress: (@Sendable (String) -> Void)?
    ) throws {
        try contract.validate()
        guard flowShardPaths.count == 6 else { throw CosyVoice3AcousticError.invalidShape("flow_shards", [flowShardPaths.count]) }
        guard !conditionsPath.isEmpty, !hiftPath.isEmpty, flowShardPaths.allSatisfy({ !$0.isEmpty }) else {
            throw CosyVoice3AcousticError.invalidShape("dynamic_model_paths", [])
        }
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

        self.assetRoot = assetRoot
        self.conditionsPath = conditionsPath
        let partitionArgs = CommandLine.arguments.filter { $0.hasPrefix("--validation-flow-partition=") }
        guard partitionArgs.count <= 1 else { throw CosyVoice3AcousticError.invalidShape("duplicate_flow_partition", []) }
        let count: Int
        if let argument = partitionArgs.first {
            guard let value = Int(argument.dropFirst("--validation-flow-partition=".count)) else { throw CosyVoice3AcousticError.invalidShape("invalid_flow_partition", []) }
            count = value
        } else { count = 6 }
        guard [1,2,3,6].contains(count) else { throw CosyVoice3AcousticError.invalidShape("flow_partition", [count]) }
        if count != 6 {
            guard case .enumerated = contract else { throw CosyVoice3AcousticError.invalidShape("partition_requires_schema3", []) }
            self.flowShardPaths = (0..<count).map { "../FlowPartitions/p\(count)/group-\($0).mlpackage" }
        } else { self.flowShardPaths = flowShardPaths }
        self.hiftPath = hiftPath
        self.f0 = f0
        self.contract = contract
        self.defaultPromptTokens = defaultPromptTokens
        self.defaultPromptFeat = defaultPromptFeat
        self.defaultSpeaker = defaultSpeaker
        self.flowNoiseMaximum = flowNoiseMaximum
        self.hiftExcitationMaximum = hiftExcitationMaximum
        self.flowStepCount = flowStepCount
        self.progress = progress
    }

    func synthesize(speechTokens: [Int], prepared: CosyVoice3PreparedRequest) async throws -> CosyVoice3Audio {
        defer {
            let value: [String: Any] = ["executeMsExcludingLoad": phaseMilliseconds, "firstCallMs": firstCallMilliseconds, "calls": phaseCalls, "modelLoadMs": modelLoadMilliseconds, "opaqueSpecializationIncludedInPrediction": true]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("[COSY-ACOUSTIC-PHASE] \(text)") }
        }
        let n = speechTokens.count
        guard n >= contract.speechTokenMinimum, n <= contract.speechTokenMaximum else {
            throw CosyVoice3AcousticError.invalidTokenCount(n)
        }
        let p = contract.promptFrameCount
        let tFrames = p + 2 * n
        let g = 2 * n
        let samplesCount = 960 * n
        let functionName = try contract.functionName(forSpeechTokenCount: n)
        if let functionName {
            print("[COSY-ENUMERATED] N=\(n) T=\(tFrames) G=\(g) function=\(functionName)")
        }

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

        progress?("acoustic.conditions.begin:N=\(n):T=\(tFrames)")
        let (mu,spks,cond) = try predictConditions(
            tokens: tokens,
            promptTokens: promptTokens,
            promptFeat: promptFeat,
            speaker: speaker,
            tFrames: tFrames,
            functionName: functionName
        )
        await Task.yield()
        progress?("acoustic.conditions.end:N=\(n):T=\(tFrames)")

        var x = flowNoisePrefix(frameCount: tFrames)
        let mask = try ones(shape: [2,1,tFrames])
        let batchX = try MLMultiArray(shape: [2,80,NSNumber(value:tFrames)], dataType: .float32)
        let time = try MLMultiArray(shape: [2], dataType: .float32)
        let span = try CosyVoice3Fixed225AcousticRuntime.flowTimeSpan(stepCount: flowStepCount)
        var currentT = span[0]
        var dt = span[1] - span[0]

        do {
            let flowModels = try flowShardPaths.enumerated().map { index, path in
                try loadModel(
                    path: path,
                    stage: "acoustic.flow.shard.\(index + 1).\(flowShardPaths.count).model",
                    functionName: functionName
                )
            }
            progress?("acoustic.flow.models.ready:count=\(flowModels.count):function=\(functionName ?? "<range>")")
            print("[COSY-FLOW-LIFECYCLE] constructors=\(flowModels.count) steps=\(flowStepCount) function=\(functionName ?? "<range>")")

            for step in 0..<flowStepCount {
                progress?("acoustic.flow.step.\(step + 1).\(flowStepCount).begin:N=\(n):T=\(tFrames)")
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
                for index in flowShardPaths.indices {
                    let stage = try predictFlowShard(
                        index: index,
                        model: flowModels[index],
                        flowStep: step,
                        feed: feed,
                        tFrames: tFrames
                    )
                    switch stage {
                    case .first(let h, let te):
                        feed = ["h":h, "te":te, "mask":mask]
                    case .hidden(let h):
                        feed["h"] = h
                    case .velocity(let value):
                        velocity = value
                    }
                    await Task.yield()
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
                progress?("acoustic.flow.step.\(step + 1).\(flowStepCount).end:N=\(n):T=\(tFrames)")
            }
        }
        await Task.yield()
        guard x.allSatisfy(\.isFinite) else { throw CosyVoice3AcousticError.nonFinite("flow") }

        let mel = try MLMultiArray(shape: [1,80,NSNumber(value:g)], dataType: .float32)
        let melPointer = mel.dataPointer.assumingMemoryBound(to: Float.self)
        for channel in 0..<80 {
            for frame in 0..<g {
                melPointer[channel * g + frame] = x[channel * tFrames + p + frame]
            }
        }

        progress?("acoustic.f0.begin:G=\(g)")
        let f0Started = DispatchTime.now().uptimeNanoseconds
        let f0Values = try f0.prediction(mel: mel)
        recordPhase("f0", since: f0Started, loadBefore: modelLoadMilliseconds)
        guard f0Values.shape.map(\.intValue) == [1,g] else { throw CosyVoice3AcousticError.invalidShape("f0", f0Values.shape.map(\.intValue)) }
        progress?("acoustic.f0.end:G=\(g)")

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
        progress?("acoustic.hift.begin:G=\(g):samples=\(samplesCount)")
        let samples = try predictHiFT(
            mel: mel,
            f0: f0Values,
            phase: phase,
            excitation: excitation,
            norm: norm,
            samplesCount: samplesCount,
            functionName: functionName
        )
        await Task.yield()
        progress?("acoustic.hift.end:G=\(g):samples=\(samplesCount)")
        return .init(samples: samples, sampleRate: Self.sampleRate, channels: 1)
    }

    private enum FlowShardStage {
        case first(MLMultiArray, MLMultiArray)
        case hidden(MLMultiArray)
        case velocity(MLMultiArray)
    }

    private func loadModel(path: String, stage: String, functionName: String?) throws -> MLModel {
        progress?("\(stage).load.begin:\(path):function=\(functionName ?? "<range>")")
        let started = DispatchTime.now().uptimeNanoseconds
        let model: MLModel
        if let functionName {
            model = try CosyVoice3AssetLoader.enumeratedAcousticModel(root: assetRoot, path: path, functionName: functionName)
            print("[COSY-SPECIALIZATION] stage=\(stage) strategy=ENUMERATED_EXACT function=\(functionName) productionPath=YES")
        } else {
            let fast = stage.contains(".shard.") && ProcessInfo.processInfo.environment["COSYVOICE3_VALIDATION_FLOW_FAST_PREDICTION"] == "1"
            model = try CosyVoice3AssetLoader.dynamicAcousticModel(root: assetRoot, path: path, preferFastPrediction: fast)
            print("[COSY-SPECIALIZATION] stage=\(stage) strategy=\(fast ? "FAST_PREDICTION" : "DEFAULT") validationOnly=YES")
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        modelLoadMilliseconds += elapsed
        print("[COSY-MODEL-LOAD] stage=\(stage) ms=\(elapsed)")
        progress?("\(stage).load.end:\(path):ms=\(String(format: "%.3f", elapsed))")
        return model
    }

    private func predictConditions(
        tokens: MLMultiArray,
        promptTokens: MLMultiArray,
        promptFeat: MLMultiArray,
        speaker: MLMultiArray,
        tFrames: Int,
        functionName: String?
    ) throws -> (MLMultiArray, MLMultiArray, MLMultiArray) {
        let phaseStarted = DispatchTime.now().uptimeNanoseconds
        let loadBefore = modelLoadMilliseconds
        defer { recordPhase("conditions", since: phaseStarted, loadBefore: loadBefore) }
        return try autoreleasepool {
            let model = try loadModel(path: conditionsPath, stage: "acoustic.conditions.model", functionName: functionName)
            progress?("acoustic.conditions.prediction.begin:T=\(tFrames)")
            let result = try model.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
                "tokens": tokens,
                "prompt_tokens": promptTokens,
                "prompt_feat": promptFeat,
                "speaker": speaker
            ]))
            let mu = try ownedFloat32Output(result, "mu")
            let spks = try ownedFloat32Output(result, "spks")
            let cond = try ownedFloat32Output(result, "cond")
            guard mu.shape.map(\.intValue) == [2,80,tFrames] else { throw CosyVoice3AcousticError.invalidShape("mu", mu.shape.map(\.intValue)) }
            guard spks.shape.map(\.intValue) == [2,80] else { throw CosyVoice3AcousticError.invalidShape("spks", spks.shape.map(\.intValue)) }
            guard cond.shape.map(\.intValue) == [2,80,tFrames] else { throw CosyVoice3AcousticError.invalidShape("cond", cond.shape.map(\.intValue)) }
            progress?("acoustic.conditions.prediction.end:T=\(tFrames)")
            return (mu,spks,cond)
        }
    }

    private func predictFlowShard(
        index: Int,
        model: MLModel,
        flowStep: Int,
        feed: [String: MLMultiArray],
        tFrames: Int
    ) throws -> FlowShardStage {
        let phaseStarted = DispatchTime.now().uptimeNanoseconds
        let loadBefore = modelLoadMilliseconds
        defer {
            recordPhase("flow", since: phaseStarted, loadBefore: loadBefore)
            recordPhase("flow.shard.\(index)", since: phaseStarted, loadBefore: loadBefore)
        }
        return try autoreleasepool {
            let label = "acoustic.flow.step.\(flowStep + 1).\(flowStepCount).shard.\(index + 1).\(flowShardPaths.count)"
            progress?("\(label).prediction.begin:T=\(tFrames)")
            let result = try model.prediction(from: try MLDictionaryFeatureProvider(dictionary: feed))
            let stage: FlowShardStage
            if index == 0 && flowShardPaths.count > 1 {
                let h = try ownedFloat32Output(result, "h")
                let te = try ownedFloat32Output(result, "te")
                guard h.shape.map(\.intValue) == [2,tFrames,1024] else { throw CosyVoice3AcousticError.invalidShape("h", h.shape.map(\.intValue)) }
                guard te.shape.map(\.intValue) == [2,1024] else { throw CosyVoice3AcousticError.invalidShape("te", te.shape.map(\.intValue)) }
                stage = .first(h,te)
            } else if index == flowShardPaths.count - 1 {
                let velocity = try ownedFloat32Output(result, "velocity")
                stage = .velocity(velocity)
            } else {
                let h = try ownedFloat32Output(result, "h_out")
                guard h.shape.map(\.intValue) == [2,tFrames,1024] else { throw CosyVoice3AcousticError.invalidShape("h_out", h.shape.map(\.intValue)) }
                stage = .hidden(h)
            }
            progress?("\(label).prediction.end:T=\(tFrames)")
            return stage
        }
    }

    private func predictHiFT(
        mel: MLMultiArray,
        f0: MLMultiArray,
        phase: MLMultiArray,
        excitation: MLMultiArray,
        norm: MLMultiArray,
        samplesCount: Int,
        functionName: String?
    ) throws -> [Float] {
        let phaseStarted = DispatchTime.now().uptimeNanoseconds
        let loadBefore = modelLoadMilliseconds
        defer { recordPhase("decoder", since: phaseStarted, loadBefore: loadBefore) }
        return try autoreleasepool {
            let model = try loadModel(path: hiftPath, stage: "acoustic.hift.model", functionName: functionName)
            progress?("acoustic.hift.prediction.begin:samples=\(samplesCount)")
            let result = try model.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
                "mel": mel, "f0": f0, "phase": phase, "noise": excitation, "norm": norm
            ]))
            let pcm = try output(result, "pcm")
            guard pcm.shape.map(\.intValue) == [1,samplesCount] else { throw CosyVoice3AcousticError.invalidShape("pcm", pcm.shape.map(\.intValue)) }
            let samples = Self.floatValues(pcm)
            guard samples.count == samplesCount else { throw CosyVoice3AcousticError.invalidPCMCount(samples.count) }
            guard samples.allSatisfy(\.isFinite) else { throw CosyVoice3AcousticError.nonFinite("pcm") }
            progress?("acoustic.hift.prediction.end:samples=\(samplesCount)")
            return samples
        }
    }

    private func ownedFloat32Output(_ provider: MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        let source = try output(provider, name)
        guard source.dataType == .float32 else {
            throw CosyVoice3AcousticError.invalidShape("\(name)_dtype", source.shape.map(\.intValue))
        }
        let owned = try MLMultiArray(shape: source.shape, dataType: .float32)
        if Self.isContiguous(source), Self.isContiguous(owned) {
            memcpy(owned.dataPointer, source.dataPointer, source.count * MemoryLayout<Float>.size)
        } else {
            for index in 0..<source.count { owned[index] = source[index] }
        }
        return owned
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
// Runtime environment: iOS18+/macOS15+ CoreML; dynamic acoustic MLModel lifetime is stage-scoped inside this runtime, with at most one Conditions/Flow/HiFT MLModel intentionally retained at a time.
// Generated time: 2026-10-04 America/New_York.
// Changes: variable N/T/G/PCM shapes; generic default/custom reference conditioning; manifest-bound max Flow noise and HiFT excitation prefixes; no zero-buffer fallback, padding, bucket substitution, or production promotion claim.

// Changes 2026-10-04: optional nil-default validation progress marks Conditions, each Euler Flow step, F0 and HiFT boundaries; tensor math, model inputs and production behavior are unchanged.

// Changes 2026-10-04: replace resident Conditions+6 Flow+HiFT model set with stage-scoped loading. Conditions/Flow outputs are copied into owned Float32 arrays before the producing model leaves scope; each Flow shard is loaded/predicted/released for each Euler step; HiFT loads only after Flow/F0. This trades model-instantiation time for bounded memory while preserving exact dynamic tensors and scheduler math.

// Changes 2026-10-04: align production dynamic model lifetime exactly with the physically accepted shape-sweep pattern: synchronous MLModel.prediction inside a throwing autoreleasepool, one request-scoped model per prediction. Owned outputs escape the pool; MLModel/provider temporaries do not.

// Changes 2026-10-04: every dynamic Conditions/Flow/HiFT prediction load now uses the exact physical-probe MLModel configuration (CPU_AND_NE requested units plus reshapeFrequency=.infrequent). Flow shard progress also includes the outer Euler step so a stall is uniquely attributable.

// Updated 2026-10-04: phase instrumentation only; execute time excludes explicit MLModel construction but includes opaque runtime specialization; all shapes and model scoping preserved.

// Purpose: opt-in single-variable Flow specialization experiment, default unchanged; upstream: sequential dynamic runtime.
// Environment: Swift6 iOS18+/macOS15+; generated 2026-10-05 America/New_York; changed loadModel validation hint only.

// Changes 2026-10-05: production enumerated lane selects one exact-shape multifunction family after real EOS determines N. N/T/G/PCM stay exact; no bucket padding or crop is introduced. Schema-2 RangeDim remains available only as the frozen comparison path.

// Changes 2026-10-05: production Flow lifecycle now constructs the six selected-function MLModel objects once per utterance, reuses them across all Euler steps, and releases the whole Flow set before F0/HiFT. This reduces the 6-step path from 36 Flow constructors to 6 without changing exact N/T/G, model bytes, scheduler math, CFG, noise, or function selection.

// Changes 2026-10-05: validation-only 6/3/2/1 adjacent graph packages from separate FlowPartitions; four-family schema3 required. Full-group output velocity handled in existing solver, all6/8/10 Euler steps/math unchanged. Upstream frozen six-shard runtime; Swift6/iOS18+.
