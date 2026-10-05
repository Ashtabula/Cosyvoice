// CosyVoice3RuntimeContracts.swift
// Requirement: private production pipeline interfaces matching the other engine SDKs; no benchmark/UI/host ownership.
import CoreML
import Foundation

enum CosyVoice3GenerationPolicy {
    static let upstreamMaximumTokenTextRatio = 20
    static let contextCapacity = CosyVoice3FP16StatefulLLMSession.capacity
    static let productionSpeechTokenMaximum = 450
    static let logicalPrefixMaximumForFullSpeechWindow = contextCapacity - productionSpeechTokenMaximum

    static func maximumSpeechTokenCount(targetTextTokenCount: Int, logicalPrefixLength: Int) -> Int {
        guard targetTextTokenCount > 0, logicalPrefixLength > 0, logicalPrefixLength < contextCapacity else { return 0 }
        return min(
            targetTextTokenCount * upstreamMaximumTokenTextRatio,
            productionSpeechTokenMaximum,
            contextCapacity - logicalPrefixLength
        )
    }
}

struct CosyVoice3PreparedRequest: @unchecked Sendable {
    let prefillInput: MLFeatureProvider
    let minimumSpeechTokenCount: Int
    let maximumSpeechTokenCount: Int
    let logicalPrefixLength: Int
    let referenceConditioning: CosyVoice3ReferenceConditioning?

    init(
        prefillInput: MLFeatureProvider,
        minimumSpeechTokenCount: Int,
        maximumSpeechTokenCount: Int,
        logicalPrefixLength: Int,
        referenceConditioning: CosyVoice3ReferenceConditioning? = nil
    ) {
        self.prefillInput = prefillInput
        self.minimumSpeechTokenCount = minimumSpeechTokenCount
        self.maximumSpeechTokenCount = maximumSpeechTokenCount
        self.logicalPrefixLength = logicalPrefixLength
        self.referenceConditioning = referenceConditioning
    }
}

protocol CosyVoice3NativeFrontend: Sendable {
    func prepare(text: String, reference: CosyVoice3VoiceReference?, instruction: String?) async throws -> CosyVoice3PreparedRequest
}

protocol CosyVoice3AcousticRuntime: Sendable {
    func synthesize(speechTokens: [Int], prepared: CosyVoice3PreparedRequest) async throws -> CosyVoice3Audio
}

struct CosyVoice3RuntimeAssetContract: Codable, Sendable {
    let schemaVersion: Int
    let speechEmbeddingFile: String
    let ropeTheta: Double
    let ropeHeadDimension: Int
    let ropeMaximumPosition: Int
    let llmPrefillModel: String
    let llmDecodeModel: String
    func validate() throws {
        guard schemaVersion == 1, !speechEmbeddingFile.isEmpty, ropeTheta > 0,
              ropeHeadDimension == 64, ropeMaximumPosition >= 512,
              !llmPrefillModel.isEmpty, !llmDecodeModel.isEmpty else {
            throw CosyVoice3EngineError.developmentRuntimeIncomplete("invalid CosyVoice3 runtime asset contract")
        }
    }
}

// Purpose: isolate frontend, autoregressive LLM and acoustic runtime behind engine-private contracts; generation capacity is request-dynamic from the upstream 20x rule and remaining fixed512 logical context. Legacy fixed225 compatibility is applied by the Engine only when loading a fixed225 asset profile.
// Upstream pattern: OmniVoice RuntimeContracts/SpeechEngine and ZipVoice SpeechContracts.
// Runtime: iOS18+.
// Generated: 2026-10-02 America/New_York.

// Changes 2026-10-04: remove the acoustic N225 limit from the frontend/LLM policy. Per-request maxN is min(20*targetTextTokens,512-logicalPrefixLength); legacy fixed225 manifests are capped by CosyVoice3Engine before LLM generation.

// Changes 2026-10-05: production generation hard-caps real speech at N=450. ctx512 therefore leaves a 62-position logical-prefix budget when the caller needs the full 450-token speech window; longer valid prefixes remain supported with a correspondingly smaller generation window.
