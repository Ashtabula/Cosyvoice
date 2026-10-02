// CosyVoice3Engine.swift
// Requirement: public SDK facade owns the complete on-device fixed225 lane.
// Custom-reference enrollment stays fail-closed until its converted assets pass parity; default baked-reference synthesis can produce PCM.
import CoreML
import Foundation
import Tokenizers

public actor CosyVoice3Engine: CosyVoice3SynthesisEngine {
    public let assetRoot: URL
    private let capabilitiesValue = CosyVoice3Capabilities(
        supportsReferenceAudio: false,
        supportsInstruction: true,
        outputSampleRate: 24_000
    )

    public init(assetRoot: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: assetRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CosyVoice3EngineError.assetRootMissing(assetRoot.path)
        }
        self.assetRoot = assetRoot
    }

    public func capabilities() async throws -> CosyVoice3Capabilities { capabilitiesValue }

    public func validateReference(_ reference: CosyVoice3VoiceReference, probeText: String) async throws {
        guard !reference.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !probeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              FileManager.default.fileExists(atPath: reference.audioURL.path) else {
            throw CosyVoice3EngineError.invalidReference
        }
        throw CosyVoice3EngineError.developmentRuntimeIncomplete(
            "custom reference enrollment is not promoted until speech-tokenizer, CAMPPlus and 24-kHz prompt-mel iOS parity pass"
        )
    }

    public func synthesize(_ text: String, parameters: CosyVoice3Parameters = .init()) async throws -> CosyVoice3Audio {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw CosyVoice3EngineError.emptyText }
        if parameters.reference != nil {
            throw CosyVoice3EngineError.developmentRuntimeIncomplete(
                "custom reference enrollment is not yet a validated production asset; omit reference to use the validated baked-reference fixed225 lane"
            )
        }
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw CosyVoice3EngineError.developmentRuntimeIncomplete("stateful CosyVoice3 runtime requires iOS18+/macOS15+")
        }

        let manifest = try CosyVoice3AssetLoader.loadManifest(root: assetRoot)
        let tokenizerRoot = assetRoot.appendingPathComponent(manifest.tokenizerFolder, isDirectory: true)
        let tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerRoot)
        let textEmbeddings = try CosyVoice3FP16EmbeddingTable(
            url: assetRoot.appendingPathComponent(manifest.textEmbedding),
            rows: manifest.textEmbeddingRows
        )
        let speechEmbeddings = try CosyVoice3FP16EmbeddingTable(
            url: assetRoot.appendingPathComponent(manifest.speechEmbedding),
            rows: CosyVoice3TokenSemantics.logitsCount
        )
        let rope = CosyVoice3RoPEConfiguration(
            headDimension: 64,
            theta: manifest.ropeTheta,
            maximumPosition: 512
        )
        let frontend = CosyVoice3Fixed224Frontend(
            tokenizer: tokenizer,
            textEmbeddings: textEmbeddings,
            speechEmbeddings: speechEmbeddings,
            rope: rope
        )
        let prepared = try await frontend.prepare(
            text: cleaned,
            reference: nil,
            instruction: parameters.instruction
        )

        let prefill = try CosyVoice3AssetLoader.model(root: assetRoot, path: manifest.llmPrefill)
        let decode = try CosyVoice3AssetLoader.model(root: assetRoot, path: manifest.llmDecode)
        let conditioner = try CosyVoice3TokenConditioner(
            embeddingURL: assetRoot.appendingPathComponent(manifest.speechEmbedding),
            rope: rope
        )
        let llm = CosyVoice3LLMRuntime(
            prefillModel: prefill,
            decodeModel: decode,
            conditioner: conditioner
        )
        let speechTokens = try llm.generate(prepared)

        let conditions = try CosyVoice3AssetLoader.model(root: assetRoot, path: manifest.flowConditions)
        let shards = try manifest.flowShards.map { try CosyVoice3AssetLoader.model(root: assetRoot, path: $0) }
        let hift = try CosyVoice3AssetLoader.model(root: assetRoot, path: manifest.hift)
        let f0 = try CosyVoice3HiFTDoubleF0(folder: assetRoot.appendingPathComponent(manifest.f0Folder, isDirectory: true))
        let mask = try CosyVoice3AssetLoader.array(root: assetRoot, path: manifest.flowMask, shape: [2,1,752], type: .float32)
        let noise = try CosyVoice3AssetLoader.array(root: assetRoot, path: manifest.flowNoise, shape: [1,80,752], type: .float32)
        let acoustic = try CosyVoice3Fixed225AcousticRuntime(
            conditions: conditions,
            shards: shards,
            hift: hift,
            f0: f0,
            flowMask: mask,
            initialNoise: noise
        )
        return try await acoustic.synthesize(speechTokens: speechTokens, prepared: prepared)
    }
}

// Purpose: connect native tokenizer/prefill, stateful LLM, Swift RAS, Flow and HiFT to actual PCM for the validated fixed225 default-reference profile.
// Upstream: CosyVoice3_NPU@8789402.
// Runtime: iOS18+/macOS15+, no Python/host/file bridge.
// Generated: 2026-10-02 America/New_York.
