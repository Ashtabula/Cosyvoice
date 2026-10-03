// CosyVoice3Engine.swift
// Requirement: public SDK facade owns the complete on-device fixed225 lane; immutable Core ML artifacts are compiled once, lightweight frontend/reference state is reused across calls, and large inference MLModel objects retain the validated sequential lifetime.
import CoreML
import CryptoKit
import Foundation
import Tokenizers

public actor CosyVoice3Engine: CosyVoice3SynthesisEngine {
    public let assetRoot: URL
    private let manifest: CosyVoice3Fixed225AssetManifest
    private let capabilitiesValue: CosyVoice3Capabilities
    private let rope: CosyVoice3RoPEConfiguration

    // Safe persistent engine state. Large LLM/Flow/HiFT MLModel objects intentionally remain
    // request-scoped so the accepted sequential memory lifecycle is preserved.
    private var tokenizerCache: (any Tokenizer)?
    private var textEmbeddingsCache: CosyVoice3FP16EmbeddingTable?
    private var speechEmbeddingsCache: CosyVoice3FP16EmbeddingTable?
    private var conditionerCache: CosyVoice3TokenConditioner?
    private var f0Cache: CosyVoice3HiFTDoubleF0?
    private var flowMaskCache: MLMultiArray?
    private var flowNoiseCache: MLMultiArray?
    private var referenceConditioningCache: [String: CosyVoice3ReferenceConditioning] = [:]

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
    }

    public func capabilities() async throws -> CosyVoice3Capabilities { capabilitiesValue }

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
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw CosyVoice3EngineError.emptyText }
        if let reference = parameters.reference {
            guard !reference.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  FileManager.default.fileExists(atPath: reference.audioURL.path) else {
                throw CosyVoice3EngineError.invalidReference
            }
        }

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
            prepared = CosyVoice3PreparedRequest(
                prefillInput: basePrepared.prefillInput,
                minimumSpeechTokenCount: basePrepared.minimumSpeechTokenCount,
                maximumSpeechTokenCount: basePrepared.maximumSpeechTokenCount,
                logicalPrefixLength: basePrepared.logicalPrefixLength,
                referenceConditioning: conditioning
            )
            flowConditionsPath = referenceAssets.flowConditionsDynamic
        } else {
            prepared = basePrepared
            flowConditionsPath = manifest.flowConditions
        }

        // MLModel objects remain request-scoped to preserve the previously validated memory
        // lifecycle. CosyVoice3AssetLoader now resolves these through a persistent .mlmodelc
        // cache, so this is model construction, not package recompilation.
        let speechTokens: [Int] = try {
            let prefill = try CosyVoice3AssetLoader.model(root: assetRoot, path: manifest.llmPrefill)
            let decode = try CosyVoice3AssetLoader.model(root: assetRoot, path: manifest.llmDecode)
            let llm = CosyVoice3LLMRuntime(
                prefillModel: prefill,
                decodeModel: decode,
                conditioner: try reusableConditioner()
            )
            return try llm.generate(prepared)
        }()

        // The lexical scope above intentionally drops request-scoped LLM model references
        // before Flow model construction, matching the accepted device benchmark lifecycle.
        let conditions = try CosyVoice3AssetLoader.model(root: assetRoot, path: flowConditionsPath)
        let shards = try manifest.flowShards.map { try CosyVoice3AssetLoader.model(root: assetRoot, path: $0) }
        let hift = try CosyVoice3AssetLoader.model(root: assetRoot, path: manifest.hift)
        let acoustic = try CosyVoice3Fixed225AcousticRuntime(
            conditions: conditions,
            shards: shards,
            hift: hift,
            f0: try reusableF0(),
            flowMask: try reusableFlowMask(),
            initialNoise: try reusableFlowNoise()
        )
        return try await acoustic.synthesize(speechTokens: speechTokens, prepared: prepared)
    }

    private func reusableBaseFrontend() async throws -> CosyVoice3Fixed224Frontend {
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

        return CosyVoice3Fixed224Frontend(
            tokenizer: tokenizer,
            textEmbeddings: textEmbeddings,
            speechEmbeddings: speechEmbeddings,
            rope: rope
        )
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
            path: manifest.flowMask,
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
            path: manifest.flowNoise,
            shape: [1,80,752],
            type: .float32
        )
        flowNoiseCache = loaded
        return loaded
    }

    private func referenceConditioning(
        for reference: CosyVoice3VoiceReference,
        assets: CosyVoice3ReferenceEnrollmentAssets
    ) async throws -> CosyVoice3ReferenceConditioning {
        let key = try referenceFingerprint(reference.audioURL)
        if let cached = referenceConditioningCache[key] { return cached }
        let encoded = try await makeReferenceEncoder(assets: assets).encode(audioURL: reference.audioURL)
        guard encoded.fingerprint == key else {
            throw CosyVoice3EngineError.developmentRuntimeIncomplete("reference conditioning fingerprint mismatch")
        }
        referenceConditioningCache[key] = encoded
        return encoded
    }

    private func referenceFingerprint(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeReferenceEncoder(assets: CosyVoice3ReferenceEnrollmentAssets) throws -> CosyVoice3CoreMLReferenceEncoder {
        let speechTokenizer = try CosyVoice3AssetLoader.model(
            root: assetRoot, path: assets.speechTokenizer, computeUnits: .cpuOnly
        )
        let campPlus = try CosyVoice3AssetLoader.model(
            root: assetRoot, path: assets.campPlus, computeUnits: .cpuOnly
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
}

// Purpose: default baked-reference and separately parity-gated custom-reference fixed225 paths share one public text->PCM API without recompiling immutable Core ML packages on every synthesis.
// Upstream: CosyVoice3_NPU@8789402; request-scoped large-model lifetime follows the accepted StatefulLLMBench full-pipeline memory behavior.
// Runtime: iOS18+/macOS15+, no Python/host bridge.
// Generated: 2026-10-02 America/New_York.
// Changes 2026-10-02: cache tokenizer/embedding/F0/static buffers and per-audio reference conditioning on the engine; large LLM/Flow/HiFT MLModel objects remain request-scoped but now load from CosyVoice3AssetLoader's persistent compiled cache.

// Changes 2026-10-02: explicit LLM lexical lifetime releases request-scoped prefill/decode references before Flow construction, matching accepted full-pipeline memory behavior.
