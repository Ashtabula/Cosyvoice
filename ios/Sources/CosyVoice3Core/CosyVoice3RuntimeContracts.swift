// CosyVoice3RuntimeContracts.swift
// Requirement: private production pipeline interfaces matching the other engine SDKs; no benchmark/UI/host ownership.
import CoreML
import Foundation

enum CosyVoice3Fixed225GenerationPolicy {
    static let speechTokenCapacity = 225
    static let upstreamMaximumTokenTextRatio = 20

    static func maximumSpeechTokenCount(targetTextTokenCount: Int, logicalPrefixLength: Int) -> Int {
        guard targetTextTokenCount > 0, logicalPrefixLength > 0 else { return 0 }
        return min(
            targetTextTokenCount * upstreamMaximumTokenTextRatio,
            speechTokenCapacity,
            CosyVoice3FP16StatefulLLMSession.capacity - logicalPrefixLength
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

// Purpose: isolate frontend, autoregressive LLM and acoustic runtime behind engine-private contracts; fixed225 generation explicitly caps the upstream max-length policy at the current acoustic bucket capacity.
// Upstream pattern: OmniVoice RuntimeContracts/SpeechEngine and ZipVoice SpeechContracts.
// Runtime: iOS18+.
// Generated: 2026-10-02 America/New_York.
