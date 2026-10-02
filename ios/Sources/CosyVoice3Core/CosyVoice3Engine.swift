// CosyVoice3Engine.swift
// Requirement: public SDK facade owns the complete on-device fixed225 lane; custom reference activates only after its assets are explicitly device-parity promoted.
import CoreML
import Foundation
import Tokenizers

public actor CosyVoice3Engine: CosyVoice3SynthesisEngine {
    public let assetRoot: URL
    private let manifest: CosyVoice3Fixed225AssetManifest
    private let capabilitiesValue: CosyVoice3Capabilities

    public init(assetRoot: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: assetRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CosyVoice3EngineError.assetRootMissing(assetRoot.path)
        }
        self.assetRoot = assetRoot
        self.manifest = try CosyVoice3AssetLoader.loadManifest(root: assetRoot)
        self.capabilitiesValue = CosyVoice3Capabilities(
            supportsReferenceAudio: manifest.referenceEnrollment?.isPromoted == true,
            supportsInstruction: true,
            outputSampleRate: 24_000
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
        _ = try await makeReferenceEncoder(assets: assets).encode(audioURL: reference.audioURL)
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
        let baseFrontend = CosyVoice3Fixed224Frontend(
            tokenizer: tokenizer,
            textEmbeddings: textEmbeddings,
            speechEmbeddings: speechEmbeddings,
            rope: rope
        )

        let frontend: any CosyVoice3NativeFrontend
        let flowConditionsPath: String
        if parameters.reference != nil {
            guard let referenceAssets = manifest.referenceEnrollment, referenceAssets.isPromoted else {
                throw CosyVoice3EngineError.developmentRuntimeIncomplete(
                    "custom reference requested but reference enrollment is not PASS_DEVICE_PARITY"
                )
            }
            let encoder = try makeReferenceEncoder(assets: referenceAssets)
            frontend = CosyVoice3ReferenceAwareFrontend(base: baseFrontend, encoder: encoder)
            flowConditionsPath = referenceAssets.flowConditionsDynamic
        } else {
            frontend = baseFrontend
            flowConditionsPath = manifest.flowConditions
        }

        let prepared = try await frontend.prepare(
            text: cleaned,
            reference: parameters.reference,
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

        let conditions = try CosyVoice3AssetLoader.model(root: assetRoot, path: flowConditionsPath)
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

// Purpose: default baked-reference and separately parity-gated custom-reference fixed225 paths now share one public text->PCM API.
// Upstream: CosyVoice3_NPU@8789402.
// Runtime: iOS18+/macOS15+, no Python/host bridge.
// Generated: 2026-10-02 America/New_York.
