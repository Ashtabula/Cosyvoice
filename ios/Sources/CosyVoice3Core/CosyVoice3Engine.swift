// CosyVoice3Engine.swift
// Requirement: public SDK facade owns either the frozen fixed225 oracle or the manifest-selected exact-shape dynamic acoustic lane; first-use Core ML preparation remains serialized and large inference models retain the validated sequential stage lifetime.
import CoreML
import CryptoKit
import Foundation
import Tokenizers

public actor CosyVoice3Engine: CosyVoice3SynthesisEngine {
    public let assetRoot: URL
    private let manifest: CosyVoice3AssetManifest
    private let capabilitiesValue: CosyVoice3Capabilities
    private let rope: CosyVoice3RoPEConfiguration

    // Safe persistent engine state. Large LLM/Flow/HiFT MLModel objects intentionally remain
    // request-scoped so the accepted sequential memory lifecycle is preserved.
    private var tokenizerCache: (any Tokenizer)?
    private var baseFrontendCache: CosyVoice3Fixed224Frontend?
    private var textEmbeddingsCache: CosyVoice3FP16EmbeddingTable?
    private var speechEmbeddingsCache: CosyVoice3FP16EmbeddingTable?
    private var conditionerCache: CosyVoice3TokenConditioner?
    private var f0Cache: CosyVoice3HiFTDoubleF0?
    private var flowMaskCache: MLMultiArray?
    private var flowNoiseCache: MLMultiArray?
    private var dynamicDefaultPromptTokensCache: MLMultiArray?
    private var dynamicDefaultPromptFeatCache: MLMultiArray?
    private var dynamicDefaultSpeakerCache: MLMultiArray?
    private var dynamicFlowNoiseMaximumCache: MLMultiArray?
    private var dynamicHiFTExcitationMaximumCache: MLMultiArray?
    private var referenceConditioningCache: [String: CosyVoice3ReferenceConditioning] = [:]
    private var referenceAssetIdentityCache: String?
    private var referenceDiskCache: CosyVoice3ReferenceConditioningDiskCache?
    private var warmedModelKeys = Set<String>()
    private var lastPreparationReportValue: CosyVoice3PreparationReport?
    private var lastSynthesisReportValue: CosyVoice3SynthesisReport?
    private var validationProgressObserver: (@Sendable (String) -> Void)?

    private struct ReferenceCacheDescriptor {
        let cacheKey: String
        let referenceFingerprint: String
        let assetIdentity: String
    }

    public init(assetRoot: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: assetRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CosyVoice3EngineError.assetRootMissing(assetRoot.path)
        }
        let manifest = try CosyVoice3AssetLoader.loadManifest(root: assetRoot)
        self.assetRoot = assetRoot
        self.manifest = manifest
        self.capabilitiesValue = CosyVoice3Capabilities(
            supportsReferenceAudio: manifest.referenceEnrollment?.isPromoted == true,
            supportsInstruction: true,
            outputSampleRate: 24_000
        )
        self.rope = CosyVoice3RoPEConfiguration(
            headDimension: 64,
            theta: manifest.ropeTheta,
            maximumPosition: 512
        )
        self.referenceDiskCache = try? CosyVoice3ReferenceConditioningDiskCache()
    }

    public func capabilities() async throws -> CosyVoice3Capabilities { capabilitiesValue }
    public func lastPreparationReport() -> CosyVoice3PreparationReport? { lastPreparationReportValue }
    public func lastSynthesisReport() -> CosyVoice3SynthesisReport? { lastSynthesisReportValue }

    @_spi(Validation)
    public func setValidationProgressObserver(_ observer: (@Sendable (String) -> Void)?) {
        validationProgressObserver = observer
    }

    private func validationProgress(_ phase: String) {
        validationProgressObserver?(phase)
    }

    // Applications may call prepare(reference:) immediately after assets/reference selection.
    // synthesize() also calls it automatically, so callers are never required to manage warm-up.
    @discardableResult
    public func prepare(reference: CosyVoice3VoiceReference? = nil) async throws -> CosyVoice3PreparationReport {
        validationProgress("prepare.begin")
        let totalStart = DispatchTime.now().uptimeNanoseconds
        let maximumConcurrentModelWarmups = 1

        var flowConditionsPath = manifest.flowConditions
        var referenceAssets: CosyVoice3ReferenceEnrollmentAssets?
        var referenceCacheHit = false
        if let reference {
            guard !reference.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  FileManager.default.fileExists(atPath: reference.audioURL.path) else {
                throw CosyVoice3EngineError.invalidReference
            }
            guard let assets = manifest.referenceEnrollment, assets.isPromoted else {
                throw CosyVoice3EngineError.developmentRuntimeIncomplete(
                    "custom reference requested but reference enrollment is not PASS_DEVICE_PARITY"
                )
            }
            referenceAssets = assets
            flowConditionsPath = assets.flowConditionsDynamic
            referenceCacheHit = try cachedReferenceConditioning(for: reference, assets: assets) != nil
        }

        // Main synthesis preparation and reference-enrollment preparation have separate
        // persistent markers. The reference tensors may already be cached on a later process
        // launch, but that must not change the identity of the main LLM/Flow/HiFT marker.
        func acousticWarmSpec(_ path: String) -> CosyVoice3ModelWarmSpec {
            manifest.isDynamicAcoustic ? .dynamicAcoustic(path) : .init(path)
        }
        let mainPlan: [CosyVoice3ModelWarmSpec] = [
            .llm(manifest.llmPrefill),
            acousticWarmSpec(manifest.flowShards[0]),
            .llm(manifest.llmDecode),
            acousticWarmSpec(manifest.flowShards[1]),
            acousticWarmSpec(flowConditionsPath),
            acousticWarmSpec(manifest.flowShards[2]),
            acousticWarmSpec(manifest.flowShards[3]),
            acousticWarmSpec(manifest.flowShards[4]),
            acousticWarmSpec(manifest.flowShards[5]),
            acousticWarmSpec(manifest.hift)
        ]
        let referencePlan: [CosyVoice3ModelWarmSpec]
        if let assets = referenceAssets, !referenceCacheHit {
            referencePlan = [
                .init(assets.speechTokenizer, computeUnits: CosyVoice3ModelComputePlacement.referenceEncoder),
                .init(assets.campPlus, computeUnits: CosyVoice3ModelComputePlacement.referenceEncoder)
            ]
        } else {
            referencePlan = []
        }

        var modelPreparationCacheHit = false
        let warmStart = DispatchTime.now().uptimeNanoseconds
        if try CosyVoice3AssetLoader.hasWarmMarker(root: assetRoot, specs: mainPlan) {
            modelPreparationCacheHit = true
            warmedModelKeys.formUnion(mainPlan.map { warmKey($0) })
        }
        if !referencePlan.isEmpty,
           try CosyVoice3AssetLoader.hasWarmMarker(root: assetRoot, specs: referencePlan) {
            modelPreparationCacheHit = true
            warmedModelKeys.formUnion(referencePlan.map { warmKey($0) })
        }

        // Cold custom-reference preparation remains deliberately interleaved by stage, but
        // execution-plan construction itself is serialized after physical iPhone -14 failures
        // under concurrent constructors.
        let plan: [CosyVoice3ModelWarmSpec]
        if referencePlan.count == 2 {
            plan = [
                mainPlan[0], referencePlan[0],
                mainPlan[2], mainPlan[1],
                referencePlan[1], mainPlan[3],
                mainPlan[4], mainPlan[5],
                mainPlan[6], mainPlan[7],
                mainPlan[8], mainPlan[9]
            ]
        } else {
            plan = mainPlan
        }

        let missing = plan.filter { !warmedModelKeys.contains(warmKey($0)) }
        if !missing.isEmpty {
            let progress = validationProgressObserver
            try await CosyVoice3AssetLoader.warmModels(
                root: assetRoot,
                specs: missing,
                maximumConcurrent: maximumConcurrentModelWarmups,
                progress: progress
            )
            warmedModelKeys.formUnion(missing.map { warmKey($0) })
        }
        if mainPlan.allSatisfy({ warmedModelKeys.contains(warmKey($0)) }) {
            try CosyVoice3AssetLoader.storeWarmMarker(root: assetRoot, specs: mainPlan)
        }
        if !referencePlan.isEmpty,
           referencePlan.allSatisfy({ warmedModelKeys.contains(warmKey($0)) }) {
            try CosyVoice3AssetLoader.storeWarmMarker(root: assetRoot, specs: referencePlan)
        }
        let modelWarmupMilliseconds = Self.milliseconds(since: warmStart)

        let referenceStart = DispatchTime.now().uptimeNanoseconds
        if let reference, let assets = referenceAssets, !referenceCacheHit {
            _ = try await referenceConditioning(for: reference, assets: assets)
        }
        let referencePreparationMilliseconds = Self.milliseconds(since: referenceStart)

        let report = CosyVoice3PreparationReport(
            totalMilliseconds: Self.milliseconds(since: totalStart),
            modelWarmupMilliseconds: modelWarmupMilliseconds,
            referencePreparationMilliseconds: referencePreparationMilliseconds,
            warmedModelCount: missing.count,
            maximumConcurrentModelWarmups: maximumConcurrentModelWarmups,
            modelPreparationCacheHit: modelPreparationCacheHit,
            referenceCacheHit: referenceCacheHit
        )
        lastPreparationReportValue = report
        validationProgress("prepare.end:warmed=\(missing.count)")
        return report
    }

    public func validateReference(_ reference: CosyVoice3VoiceReference, probeText: String) async throws {
        guard !reference.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !probeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              FileManager.default.fileExists(atPath: reference.audioURL.path) else {
            throw CosyVoice3EngineError.invalidReference
        }
        guard let assets = manifest.referenceEnrollment, assets.isPromoted else {
            throw CosyVoice3EngineError.developmentRuntimeIncomplete(
                "custom reference enrollment assets have not passed physical-device parity"
            )
        }
        _ = try await referenceConditioning(for: reference, assets: assets)
    }

    public func synthesize(_ text: String, parameters: CosyVoice3Parameters = .init()) async throws -> CosyVoice3Audio {
        validationProgress("synthesis.begin")
        let totalStart = DispatchTime.now().uptimeNanoseconds
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw CosyVoice3EngineError.emptyText }
        if let reference = parameters.reference {
            guard !reference.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  FileManager.default.fileExists(atPath: reference.audioURL.path) else {
                throw CosyVoice3EngineError.invalidReference
            }
        }

        let preparation = try await prepare(reference: parameters.reference)
        validationProgress("frontend.begin")

        let frontendStart = DispatchTime.now().uptimeNanoseconds
        let baseFrontend = try await reusableBaseFrontend()
        let basePrepared = try await baseFrontend.prepare(
            text: cleaned,
            reference: parameters.reference,
            instruction: parameters.instruction
        )

        let prepared: CosyVoice3PreparedRequest
        let flowConditionsPath: String
        if let reference = parameters.reference {
            guard let referenceAssets = manifest.referenceEnrollment, referenceAssets.isPromoted else {
                throw CosyVoice3EngineError.developmentRuntimeIncomplete(
                    "custom reference requested but reference enrollment is not PASS_DEVICE_PARITY"
                )
            }
            let conditioning = try await referenceConditioning(for: reference, assets: referenceAssets)
            prepared = preparedForManifest(basePrepared, referenceConditioning: conditioning)
            flowConditionsPath = referenceAssets.flowConditionsDynamic
        } else {
            prepared = preparedForManifest(basePrepared, referenceConditioning: nil)
            flowConditionsPath = manifest.flowConditions
        }
        let frontendMilliseconds = Self.milliseconds(since: frontendStart)
        validationProgress("frontend.end:logicalPrefix=\(prepared.logicalPrefixLength):minN=\(prepared.minimumSpeechTokenCount):maxN=\(prepared.maximumSpeechTokenCount)")
        validationProgress("llm.load.begin")

        var llmModelLoadMilliseconds = 0.0
        var llmGenerationMilliseconds = 0.0
        let speechTokens: [Int] = try {
            let loadStart = DispatchTime.now().uptimeNanoseconds
            let prefill = try CosyVoice3AssetLoader.llmModel(root: assetRoot, path: manifest.llmPrefill)
            let decode = try CosyVoice3AssetLoader.llmModel(root: assetRoot, path: manifest.llmDecode)
            let llm = CosyVoice3LLMRuntime(
                prefillModel: prefill,
                decodeModel: decode,
                conditioner: try reusableConditioner(),
                progress: validationProgressObserver
            )
            llmModelLoadMilliseconds = Self.milliseconds(since: loadStart)
            validationProgress("llm.load.end")
            validationProgress("llm.generate.begin:maxN=\(prepared.maximumSpeechTokenCount)")
            let generationStart = DispatchTime.now().uptimeNanoseconds
            let tokens = try llm.generate(prepared)
            llmGenerationMilliseconds = Self.milliseconds(since: generationStart)
            validationProgress("llm.generate.end:N=\(tokens.count)")
            return tokens
        }()

        // The lexical scope above intentionally drops request-scoped LLM model references
        // before acoustic execution. The frozen fixed225 lane keeps its validated resident
        // acoustic set. The dynamic lane instead owns stage-scoped model loading internally
        // so Conditions + six Flow shards + HiFT are never intentionally resident together.
        let acousticTotalStart = DispatchTime.now().uptimeNanoseconds
        let audio: CosyVoice3Audio
        let acousticModelLoadMilliseconds: Double
        let acousticSynthesisMilliseconds: Double
        if let dynamic = manifest.dynamicAcoustic {
            validationProgress("acoustic.runtime.begin:N=\(speechTokens.count):lifetime=sequential")
            let acoustic = try CosyVoice3DynamicAcousticRuntime(
                assetRoot: assetRoot,
                conditionsPath: flowConditionsPath,
                flowShardPaths: manifest.flowShards,
                hiftPath: manifest.hift,
                f0: try reusableF0(),
                contract: dynamic,
                defaultPromptTokens: try reusableDynamicDefaultPromptTokens(dynamic),
                defaultPromptFeat: try reusableDynamicDefaultPromptFeat(dynamic),
                defaultSpeaker: try reusableDynamicDefaultSpeaker(dynamic),
                flowNoiseMaximum: try reusableDynamicFlowNoiseMaximum(dynamic),
                hiftExcitationMaximum: try reusableDynamicHiFTExcitationMaximum(dynamic),
                flowStepCount: parameters.flowSteps.rawValue,
                progress: validationProgressObserver
            )
            validationProgress("acoustic.runtime.end:N=\(speechTokens.count):lifetime=sequential")
            validationProgress("acoustic.synthesize.begin:N=\(speechTokens.count)")
            audio = try await acoustic.synthesize(speechTokens: speechTokens, prepared: prepared)
            let acousticTotalMilliseconds = Self.milliseconds(since: acousticTotalStart)
            acousticModelLoadMilliseconds = acoustic.modelLoadMilliseconds
            acousticSynthesisMilliseconds = max(0, acousticTotalMilliseconds - acousticModelLoadMilliseconds)
        } else {
            validationProgress("acoustic.load.begin:N=\(speechTokens.count):lifetime=resident-fixed225")
            let acousticLoadStart = DispatchTime.now().uptimeNanoseconds
            let conditions = try CosyVoice3AssetLoader.model(root: assetRoot, path: flowConditionsPath)
            let shards = try manifest.flowShards.map { try CosyVoice3AssetLoader.model(root: assetRoot, path: $0) }
            let hift = try CosyVoice3AssetLoader.model(root: assetRoot, path: manifest.hift)
            let acoustic = try makeAcousticRuntime(
                conditions: conditions,
                shards: shards,
                hift: hift,
                f0: try reusableF0(),
                flowStepCount: parameters.flowSteps.rawValue
            )
            acousticModelLoadMilliseconds = Self.milliseconds(since: acousticLoadStart)
            validationProgress("acoustic.load.end:N=\(speechTokens.count):lifetime=resident-fixed225")
            validationProgress("acoustic.synthesize.begin:N=\(speechTokens.count)")
            let fixedSynthesisStart = DispatchTime.now().uptimeNanoseconds
            audio = try await acoustic.synthesize(speechTokens: speechTokens, prepared: prepared)
            acousticSynthesisMilliseconds = Self.milliseconds(since: fixedSynthesisStart)
        }
        validationProgress("acoustic.synthesize.end:N=\(speechTokens.count):samples=\(audio.samples.count)")

        lastSynthesisReportValue = CosyVoice3SynthesisReport(
            flowSteps: parameters.flowSteps,
            totalMilliseconds: Self.milliseconds(since: totalStart),
            preparationMilliseconds: preparation.totalMilliseconds,
            frontendMilliseconds: frontendMilliseconds,
            llmModelLoadMilliseconds: llmModelLoadMilliseconds,
            llmGenerationMilliseconds: llmGenerationMilliseconds,
            acousticModelLoadMilliseconds: acousticModelLoadMilliseconds,
            acousticSynthesisMilliseconds: acousticSynthesisMilliseconds,
            modelPreparationCacheHit: preparation.modelPreparationCacheHit,
            referenceCacheHit: preparation.referenceCacheHit,
            warmedModelCount: preparation.warmedModelCount
        )
        print("[COSY-PHASE] summary totalMs=\(Self.milliseconds(since: totalStart)) referencePrepareMs=\(preparation.totalMilliseconds) frontendMs=\(frontendMilliseconds) llmLoadMs=\(llmModelLoadMilliseconds) llmMs=\(llmGenerationMilliseconds) acousticLoadMs=\(acousticModelLoadMilliseconds) acousticExecuteMs=\(acousticSynthesisMilliseconds) samples=\(audio.samples.count) steps=\(parameters.flowSteps.rawValue)")
        validationProgress("synthesis.end:N=\(speechTokens.count):samples=\(audio.samples.count)")
        return audio
    }

    @_spi(Validation)
    public func synthesizeFlowStepHeadToHead(
        _ text: String,
        parameters: CosyVoice3Parameters = .init(),
        flowSteps: [Int] = [10,8,6]
    ) async throws -> CosyVoice3FlowStepHeadToHeadReport {
        guard !manifest.isDynamicAcoustic else {
            throw CosyVoice3EngineError.developmentRuntimeIncomplete(
                "dynamic acoustic uses sequential stage-scoped MLModel lifetime; the legacy same-model-instance Flow head-to-head is fixed225-only"
            )
        }
        guard flowSteps == [10,8,6] else {
            throw CosyVoice3EngineError.developmentRuntimeIncomplete(
                "Flow head-to-head requires the fixed validation order [10, 8, 6]"
            )
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw CosyVoice3EngineError.emptyText }
        if let reference = parameters.reference {
            guard !reference.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  FileManager.default.fileExists(atPath: reference.audioURL.path) else {
                throw CosyVoice3EngineError.invalidReference
            }
        }

        let preparation = try await prepare(reference: parameters.reference)

        let frontendStart = DispatchTime.now().uptimeNanoseconds
        let baseFrontend = try await reusableBaseFrontend()
        let basePrepared = try await baseFrontend.prepare(
            text: cleaned,
            reference: parameters.reference,
            instruction: parameters.instruction
        )

        let prepared: CosyVoice3PreparedRequest
        let flowConditionsPath: String
        if let reference = parameters.reference {
            guard let referenceAssets = manifest.referenceEnrollment, referenceAssets.isPromoted else {
                throw CosyVoice3EngineError.developmentRuntimeIncomplete(
                    "custom reference requested but reference enrollment is not PASS_DEVICE_PARITY"
                )
            }
            let conditioning = try await referenceConditioning(for: reference, assets: referenceAssets)
            prepared = preparedForManifest(basePrepared, referenceConditioning: conditioning)
            flowConditionsPath = referenceAssets.flowConditionsDynamic
        } else {
            prepared = preparedForManifest(basePrepared, referenceConditioning: nil)
            flowConditionsPath = manifest.flowConditions
        }
        let frontendMilliseconds = Self.milliseconds(since: frontendStart)

        var llmModelLoadMilliseconds = 0.0
        var llmGenerationMilliseconds = 0.0
        let speechTokens: [Int] = try {
            let loadStart = DispatchTime.now().uptimeNanoseconds
            let prefill = try CosyVoice3AssetLoader.llmModel(root: assetRoot, path: manifest.llmPrefill)
            let decode = try CosyVoice3AssetLoader.llmModel(root: assetRoot, path: manifest.llmDecode)
            let llm = CosyVoice3LLMRuntime(
                prefillModel: prefill,
                decodeModel: decode,
                conditioner: try reusableConditioner(),
                progress: validationProgressObserver
            )
            llmModelLoadMilliseconds = Self.milliseconds(since: loadStart)
            let generationStart = DispatchTime.now().uptimeNanoseconds
            let tokens = try llm.generate(prepared)
            llmGenerationMilliseconds = Self.milliseconds(since: generationStart)
            return tokens
        }()
        let speechTokenSHA256 = SHA256.hash(
            data: Data(speechTokens.map { String($0) }.joined(separator: ",").utf8)
        ).map { String(format: "%02x", $0) }.joined()

        // Match the production sequential lifetime: LLM objects are out of scope before
        // the acoustic models are constructed. Acoustic models are then reused only inside
        // this validation call so all three variants share identical model instances,
        // speech tokens, reference conditioning, and initial Flow noise.
        let acousticLoadStart = DispatchTime.now().uptimeNanoseconds
        let conditions = try CosyVoice3AssetLoader.model(root: assetRoot, path: flowConditionsPath)
        let shards = try manifest.flowShards.map { try CosyVoice3AssetLoader.model(root: assetRoot, path: $0) }
        let hift = try CosyVoice3AssetLoader.model(root: assetRoot, path: manifest.hift)
        let f0 = try reusableF0()
        let acousticModelLoadMilliseconds = Self.milliseconds(since: acousticLoadStart)

        // One untimed-for-comparison 10-step acoustic warm-up removes first-prediction
        // effects from the measured 10/8/6 sequence while preserving the same model set.
        let warmup = try makeAcousticRuntime(
            conditions: conditions,
            shards: shards,
            hift: hift,
            f0: f0,
            flowStepCount: 10
        )
        let warmupStart = DispatchTime.now().uptimeNanoseconds
        _ = try await warmup.synthesize(speechTokens: speechTokens, prepared: prepared)
        let warmupMilliseconds = Self.milliseconds(since: warmupStart)

        var variants: [CosyVoice3FlowStepValidationResult] = []
        variants.reserveCapacity(flowSteps.count)
        for stepCount in flowSteps {
            let acoustic = try makeAcousticRuntime(
                conditions: conditions,
                shards: shards,
                hift: hift,
                f0: f0,
                flowStepCount: stepCount
            )
            let started = DispatchTime.now().uptimeNanoseconds
            let audio = try await acoustic.synthesize(speechTokens: speechTokens, prepared: prepared)
            let milliseconds = Self.milliseconds(since: started)
            variants.append(
                CosyVoice3FlowStepValidationResult(
                    flowSteps: stepCount,
                    synthesisMilliseconds: milliseconds,
                    audio: audio
                )
            )
        }

        return CosyVoice3FlowStepHeadToHeadReport(
            flowSteps: flowSteps,
            warmupFlowSteps: 10,
            warmupMilliseconds: warmupMilliseconds,
            speechTokenSHA256: speechTokenSHA256,
            preparationMilliseconds: preparation.totalMilliseconds,
            frontendMilliseconds: frontendMilliseconds,
            llmModelLoadMilliseconds: llmModelLoadMilliseconds,
            llmGenerationMilliseconds: llmGenerationMilliseconds,
            acousticModelLoadMilliseconds: acousticModelLoadMilliseconds,
            variants: variants
        )
    }

    private func reusableBaseFrontend() async throws -> CosyVoice3Fixed224Frontend {
        if let cached = baseFrontendCache { return cached }
        let tokenizer: any Tokenizer
        if let cached = tokenizerCache {
            tokenizer = cached
        } else {
            let loaded = try await AutoTokenizer.from(
                modelFolder: assetRoot.appendingPathComponent(manifest.tokenizerFolder, isDirectory: true)
            )
            tokenizerCache = loaded
            tokenizer = loaded
        }

        let textEmbeddings: CosyVoice3FP16EmbeddingTable
        if let cached = textEmbeddingsCache {
            textEmbeddings = cached
        } else {
            let loaded = try CosyVoice3FP16EmbeddingTable(
                url: assetRoot.appendingPathComponent(manifest.textEmbedding),
                rows: manifest.textEmbeddingRows
            )
            textEmbeddingsCache = loaded
            textEmbeddings = loaded
        }

        let speechEmbeddings: CosyVoice3FP16EmbeddingTable
        if let cached = speechEmbeddingsCache {
            speechEmbeddings = cached
        } else {
            let loaded = try CosyVoice3FP16EmbeddingTable(
                url: assetRoot.appendingPathComponent(manifest.speechEmbedding),
                rows: CosyVoice3TokenSemantics.logitsCount
            )
            speechEmbeddingsCache = loaded
            speechEmbeddings = loaded
        }

        let frontend = CosyVoice3Fixed224Frontend(
            tokenizer: tokenizer,
            textEmbeddings: textEmbeddings,
            speechEmbeddings: speechEmbeddings,
            rope: rope
        )
        baseFrontendCache = frontend
        return frontend
    }

    private func reusableConditioner() throws -> CosyVoice3TokenConditioner {
        if let cached = conditionerCache { return cached }
        let loaded = try CosyVoice3TokenConditioner(
            embeddingURL: assetRoot.appendingPathComponent(manifest.speechEmbedding),
            rope: rope
        )
        conditionerCache = loaded
        return loaded
    }

    private func reusableF0() throws -> CosyVoice3HiFTDoubleF0 {
        if let cached = f0Cache { return cached }
        let loaded = try CosyVoice3HiFTDoubleF0(
            folder: assetRoot.appendingPathComponent(manifest.f0Folder, isDirectory: true)
        )
        f0Cache = loaded
        return loaded
    }

    private func reusableFlowMask() throws -> MLMultiArray {
        if let cached = flowMaskCache { return cached }
        let loaded = try CosyVoice3AssetLoader.array(
            root: assetRoot,
            path: try requiredFixedAsset(manifest.flowMask, name: "flowMask"),
            shape: [2,1,752],
            type: .float32
        )
        flowMaskCache = loaded
        return loaded
    }

    private func reusableFlowNoise() throws -> MLMultiArray {
        if let cached = flowNoiseCache { return cached }
        let loaded = try CosyVoice3AssetLoader.array(
            root: assetRoot,
            path: try requiredFixedAsset(manifest.flowNoise, name: "flowNoise"),
            shape: [1,80,752],
            type: .float32
        )
        flowNoiseCache = loaded
        return loaded
    }

    private func preparedForManifest(
        _ base: CosyVoice3PreparedRequest,
        referenceConditioning: CosyVoice3ReferenceConditioning?
    ) -> CosyVoice3PreparedRequest {
        let maximum: Int
        if let dynamic = manifest.dynamicAcoustic {
            maximum = min(base.maximumSpeechTokenCount, dynamic.speechTokenMaximum)
        } else {
            maximum = min(base.maximumSpeechTokenCount, 225)
        }
        return CosyVoice3PreparedRequest(
            prefillInput: base.prefillInput,
            minimumSpeechTokenCount: base.minimumSpeechTokenCount,
            maximumSpeechTokenCount: maximum,
            logicalPrefixLength: base.logicalPrefixLength,
            referenceConditioning: referenceConditioning
        )
    }

    private func makeAcousticRuntime(
        conditions: MLModel,
        shards: [MLModel],
        hift: MLModel,
        f0: CosyVoice3HiFTDoubleF0,
        flowStepCount: Int
    ) throws -> any CosyVoice3AcousticRuntime {
        guard !manifest.isDynamicAcoustic else {
            throw CosyVoice3EngineError.developmentRuntimeIncomplete(
                "resident acoustic construction is fixed225-only; dynamic acoustic must use sequential stage-scoped runtime"
            )
        }
        return try CosyVoice3Fixed225AcousticRuntime(
            conditions: conditions,
            shards: shards,
            hift: hift,
            f0: f0,
            flowMask: try reusableFlowMask(),
            initialNoise: try reusableFlowNoise(),
            flowStepCount: flowStepCount
        )
    }

    private func reusableDynamicDefaultPromptTokens(_ dynamic: CosyVoice3DynamicAcousticAssets) throws -> MLMultiArray {
        if let cached = dynamicDefaultPromptTokensCache { return cached }
        let loaded = try CosyVoice3AssetLoader.array(root: assetRoot, path: dynamic.defaultPromptTokens, shape: [1,151], type: .int32)
        dynamicDefaultPromptTokensCache = loaded
        return loaded
    }

    private func reusableDynamicDefaultPromptFeat(_ dynamic: CosyVoice3DynamicAcousticAssets) throws -> MLMultiArray {
        if let cached = dynamicDefaultPromptFeatCache { return cached }
        let loaded = try CosyVoice3AssetLoader.array(root: assetRoot, path: dynamic.defaultPromptFeat, shape: [1,dynamic.promptFrameCount,80], type: .float32)
        dynamicDefaultPromptFeatCache = loaded
        return loaded
    }

    private func reusableDynamicDefaultSpeaker(_ dynamic: CosyVoice3DynamicAcousticAssets) throws -> MLMultiArray {
        if let cached = dynamicDefaultSpeakerCache { return cached }
        let loaded = try CosyVoice3AssetLoader.array(root: assetRoot, path: dynamic.defaultSpeaker, shape: [1,192], type: .float32)
        dynamicDefaultSpeakerCache = loaded
        return loaded
    }

    private func reusableDynamicFlowNoiseMaximum(_ dynamic: CosyVoice3DynamicAcousticAssets) throws -> MLMultiArray {
        if let cached = dynamicFlowNoiseMaximumCache { return cached }
        let loaded = try CosyVoice3AssetLoader.array(root: assetRoot, path: dynamic.flowNoiseMaximum, shape: [1,80,dynamic.maximumFlowFrames], type: .float32)
        dynamicFlowNoiseMaximumCache = loaded
        return loaded
    }

    private func reusableDynamicHiFTExcitationMaximum(_ dynamic: CosyVoice3DynamicAcousticAssets) throws -> MLMultiArray {
        if let cached = dynamicHiFTExcitationMaximumCache { return cached }
        let loaded = try CosyVoice3AssetLoader.array(root: assetRoot, path: dynamic.hiftExcitationMaximum, shape: [1,dynamic.maximumPCMSamples,9], type: .float32)
        dynamicHiFTExcitationMaximumCache = loaded
        return loaded
    }

    private func requiredFixedAsset(_ path: String?, name: String) throws -> String {
        guard let path, !path.isEmpty else {
            throw CosyVoice3EngineError.developmentRuntimeIncomplete("fixed225 manifest missing \(name)")
        }
        return path
    }

    private func referenceConditioning(
        for reference: CosyVoice3VoiceReference,
        assets: CosyVoice3ReferenceEnrollmentAssets
    ) async throws -> CosyVoice3ReferenceConditioning {
        if let cached = try cachedReferenceConditioning(for: reference, assets: assets) { return cached }
        let descriptor = try referenceCacheDescriptor(for: reference, assets: assets)
        let encoded = try await makeReferenceEncoder(assets: assets).encode(audioURL: reference.audioURL)
        guard encoded.fingerprint == descriptor.referenceFingerprint else {
            throw CosyVoice3EngineError.developmentRuntimeIncomplete("reference conditioning fingerprint mismatch")
        }
        referenceConditioningCache[descriptor.cacheKey] = encoded
        try? referenceDiskCache?.store(encoded, cacheKey: descriptor.cacheKey, assetIdentity: descriptor.assetIdentity)
        return encoded
    }

    private func cachedReferenceConditioning(
        for reference: CosyVoice3VoiceReference,
        assets: CosyVoice3ReferenceEnrollmentAssets
    ) throws -> CosyVoice3ReferenceConditioning? {
        let descriptor = try referenceCacheDescriptor(for: reference, assets: assets)
        if let cached = referenceConditioningCache[descriptor.cacheKey] { return cached }
        guard let disk = referenceDiskCache else { return nil }
        do {
            if let cached = try disk.load(
                cacheKey: descriptor.cacheKey,
                referenceFingerprint: descriptor.referenceFingerprint,
                assetIdentity: descriptor.assetIdentity
            ) {
                referenceConditioningCache[descriptor.cacheKey] = cached
                return cached
            }
        } catch {
            disk.remove(cacheKey: descriptor.cacheKey)
        }
        return nil
    }

    private func referenceCacheDescriptor(
        for reference: CosyVoice3VoiceReference,
        assets: CosyVoice3ReferenceEnrollmentAssets
    ) throws -> ReferenceCacheDescriptor {
        let referenceFingerprint = try referenceFingerprint(reference.audioURL)
        let assetIdentity: String
        if let cached = referenceAssetIdentityCache {
            assetIdentity = cached
        } else {
            let value = try CosyVoice3AssetLoader.assetCacheIdentity(
                root: assetRoot,
                paths: [
                    assets.speechTokenizer,
                    assets.campPlus,
                    assets.whisperMel128,
                    assets.kaldiMel80,
                    assets.matchaMel80
                ]
            )
            referenceAssetIdentityCache = value
            assetIdentity = value
        }
        let material = referenceFingerprint + "|" + assetIdentity
        let cacheKey = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return ReferenceCacheDescriptor(
            cacheKey: cacheKey,
            referenceFingerprint: referenceFingerprint,
            assetIdentity: assetIdentity
        )
    }

    private func referenceFingerprint(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeReferenceEncoder(assets: CosyVoice3ReferenceEnrollmentAssets) throws -> CosyVoice3CoreMLReferenceEncoder {
        let speechTokenizer = try CosyVoice3AssetLoader.model(
            root: assetRoot, path: assets.speechTokenizer, computeUnits: CosyVoice3ModelComputePlacement.referenceEncoder
        )
        let campPlus = try CosyVoice3AssetLoader.model(
            root: assetRoot, path: assets.campPlus, computeUnits: CosyVoice3ModelComputePlacement.referenceEncoder
        )
        let dsp = try CosyVoice3ReferenceDSP(
            whisper128: CosyVoice3MelBank(
                url: assetRoot.appendingPathComponent(assets.whisperMel128),
                rows: 128, columns: 201
            ),
            kaldi80: CosyVoice3MelBank(
                url: assetRoot.appendingPathComponent(assets.kaldiMel80),
                rows: 80, columns: 256
            ),
            matcha80: CosyVoice3MelBank(
                url: assetRoot.appendingPathComponent(assets.matchaMel80),
                rows: 80, columns: 961
            )
        )
        return CosyVoice3CoreMLReferenceEncoder(
            speechTokenizer: speechTokenizer,
            campPlus: campPlus,
            dsp: dsp
        )
    }

    private func warmKey(_ spec: CosyVoice3ModelWarmSpec) -> String {
        spec.path
            + "|" + String(describing: spec.computeUnits)
            + "|reshapeInfrequent=" + String(spec.reshapeFrequencyInfrequent)
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}

// Purpose: frozen fixed225 oracle and manifest-selected exact-shape dynamic acoustic candidate share one public text->PCM API with bounded first-use preparation and no all-model persistent residency.
// Upstream: CosyVoice3_NPU@8789402; request-scoped large-model lifetime follows the accepted StatefulLLMBench full-pipeline memory behavior.
// Runtime: iOS18+/macOS15+, no Python/host bridge.
// Generated: 2026-10-02 America/New_York.
// Changes 2026-10-02: persistent compiled Core ML cache; tokenizer/embedding/F0/static buffers and per-reference in-memory state are reused.
// Changes 2026-10-02: explicit LLM lexical lifetime releases request-scoped prefill/decode references before Flow construction.
// Changes 2026-10-02: persist the immutable native frontend object and precomputed RoPE rows across synthesis calls.
// Changes 2026-10-02: add automatic/public prepare(reference:) using at most two concurrent one-model warmups, preserving request-stage residency while overlapping cold execution-plan construction.
// Changes 2026-10-02: persist only derived fixed151/302/192 reference tensors across launches, keyed by reference-audio SHA plus exact reference-asset metadata identity; raw reference audio is never persisted by the SDK cache.
// Changes 2026-10-02: expose coarse preparation/synthesis stage timings for physical performance validation.

// Changes 2026-10-02: same-install process relaunch recognizes a successful prior model-preparation plan and skips redundant prewarm constructors; the marker is performance-only and never bypasses actual MLModel loading or validation.

// Changes 2026-10-02: split persistent warm markers into the main synthesis plan and reference-enrollment plan so a disk-cached reference on process relaunch does not accidentally invalidate the already-prepared LLM/Flow/HiFT marker.

// Changes 2026-10-02: physical iPhone18,4 Core ML -14 under two-model constructor overlap invalidated the bounded-parallel cold-start experiment; prepare(reference:) now serializes execution-plan construction and relies on early invocation/caching rather than simultaneous large-model specialization.

// Changes 2026-10-02: add validation-SPI 10/8/6 Flow head-to-head synthesis that generates one shared 225-token trajectory, reuses one acoustic model set and identical initial noise/reference conditioning, performs a 10-step warm-up, then measures only the three acoustic variants.

// Changes 2026-10-02: production synthesis forwards the public 6/8/10 Flow-step choice into the acoustic runtime; the selected setting is recorded in synthesis telemetry and the public default is 6.

// Changes 2026-10-04: manifest-selected dynamic acoustic runtime uses request-dynamic LLM capacity and exact N/T/G/PCM shapes; fixed225 manifests retain a 225 LLM cap and the original mask/noise runtime for regression compatibility.

// Changes 2026-10-04: validation SPI observer emits durable stage boundaries for automatic prepare, per-model warming, frontend geometry, LLM load/generation and acoustic load/synthesis. Observer is nil by default and does not alter public synthesis semantics or model math.

// Changes 2026-10-04: validation observer is forwarded into request-scoped LLM runtime for prefill/decode liveness without changing default execution.

// Changes 2026-10-04: production dynamic synthesis no longer constructs a resident Conditions+6 Flow+HiFT model set. It instantiates the stage-scoped dynamic runtime from asset paths, reports aggregate per-stage model-load time, keeps fixed225 resident behavior unchanged, clamps per-request LLM maxN to the active dynamic acoustic envelope, and fail-closes the legacy same-instance Flow head-to-head on dynamic profiles.

// Changes 2026-10-04: enforce the accepted mixed placement contract at every Engine LLM call site: prefill/decode warm and request-scoped loads use CPU_ONLY; Flow/Conditions/HiFT remain CPU_AND_NE requested placement. This fixes cold-plan Core ML -14 observed on the N1 candidate smoke.

// Changes 2026-10-04: dynamic prepare() now warms Conditions/Flow/HiFT with the same reshapeFrequency=.infrequent hint used by the accepted physical acoustic sweep; warm-key identity includes the hint so an older plan marker cannot mask this change.

// Updated 2026-10-04: emit phase totals from existing synthesis timing; no math, model lifetime, or parameters changed.
