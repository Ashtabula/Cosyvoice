// CosyVoice3VoiceEngine.swift
// Requirement: stable application-facing synthesis contract; model/token/KV/Flow/CoreML details stay private.
import Foundation

public struct CosyVoice3VoiceReference: Sendable {
    public let audioURL: URL
    public let transcript: String
    public init(audioURL: URL, transcript: String) { self.audioURL=audioURL; self.transcript=transcript }
}

public enum CosyVoice3FlowSteps: Int, CaseIterable, Sendable {
    case steps6 = 6
    case steps8 = 8
    case steps10 = 10

    public static let productionDefault: CosyVoice3FlowSteps = .steps6
}

public struct CosyVoice3Parameters: Sendable {
    public let reference: CosyVoice3VoiceReference?
    public let instruction: String?
    public let flowSteps: CosyVoice3FlowSteps

    public init(
        reference: CosyVoice3VoiceReference? = nil,
        instruction: String? = nil,
        flowSteps: CosyVoice3FlowSteps = .productionDefault
    ) {
        self.reference=reference
        self.instruction=instruction
        self.flowSteps=flowSteps
    }
}

public struct CosyVoice3Audio: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let channels: Int
    public init(samples: [Float], sampleRate: Int=24000, channels: Int=1) { self.samples=samples; self.sampleRate=sampleRate; self.channels=channels }
}

public struct CosyVoice3Capabilities: Sendable {
    public let supportsReferenceAudio: Bool
    public let supportsInstruction: Bool
    public let outputSampleRate: Int
    public let supportedFlowSteps: [CosyVoice3FlowSteps]
    public let defaultFlowSteps: CosyVoice3FlowSteps

    public init(
        supportsReferenceAudio: Bool = true,
        supportsInstruction: Bool = true,
        outputSampleRate: Int = 24000,
        supportedFlowSteps: [CosyVoice3FlowSteps] = CosyVoice3FlowSteps.allCases,
        defaultFlowSteps: CosyVoice3FlowSteps = .productionDefault
    ) {
        self.supportsReferenceAudio=supportsReferenceAudio
        self.supportsInstruction=supportsInstruction
        self.outputSampleRate=outputSampleRate
        self.supportedFlowSteps=supportedFlowSteps
        self.defaultFlowSteps=defaultFlowSteps
    }
}

public struct CosyVoice3PreparationReport: Sendable {
    public let totalMilliseconds: Double
    public let modelWarmupMilliseconds: Double
    public let referencePreparationMilliseconds: Double
    public let warmedModelCount: Int
    public let maximumConcurrentModelWarmups: Int
    public let modelPreparationCacheHit: Bool
    public let referenceCacheHit: Bool

    public init(
        totalMilliseconds: Double,
        modelWarmupMilliseconds: Double,
        referencePreparationMilliseconds: Double,
        warmedModelCount: Int,
        maximumConcurrentModelWarmups: Int,
        modelPreparationCacheHit: Bool,
        referenceCacheHit: Bool
    ) {
        self.totalMilliseconds = totalMilliseconds
        self.modelWarmupMilliseconds = modelWarmupMilliseconds
        self.referencePreparationMilliseconds = referencePreparationMilliseconds
        self.warmedModelCount = warmedModelCount
        self.maximumConcurrentModelWarmups = maximumConcurrentModelWarmups
        self.modelPreparationCacheHit = modelPreparationCacheHit
        self.referenceCacheHit = referenceCacheHit
    }
}

public struct CosyVoice3SynthesisReport: Sendable {
    public let flowSteps: CosyVoice3FlowSteps
    public let totalMilliseconds: Double
    public let preparationMilliseconds: Double
    public let frontendMilliseconds: Double
    public let llmModelLoadMilliseconds: Double
    public let llmGenerationMilliseconds: Double
    public let acousticModelLoadMilliseconds: Double
    public let acousticSynthesisMilliseconds: Double
    public let modelPreparationCacheHit: Bool
    public let referenceCacheHit: Bool
    public let warmedModelCount: Int

    public init(
        flowSteps: CosyVoice3FlowSteps = .productionDefault,
        totalMilliseconds: Double,
        preparationMilliseconds: Double,
        frontendMilliseconds: Double,
        llmModelLoadMilliseconds: Double,
        llmGenerationMilliseconds: Double,
        acousticModelLoadMilliseconds: Double,
        acousticSynthesisMilliseconds: Double,
        modelPreparationCacheHit: Bool,
        referenceCacheHit: Bool,
        warmedModelCount: Int
    ) {
        self.flowSteps = flowSteps
        self.totalMilliseconds = totalMilliseconds
        self.preparationMilliseconds = preparationMilliseconds
        self.frontendMilliseconds = frontendMilliseconds
        self.llmModelLoadMilliseconds = llmModelLoadMilliseconds
        self.llmGenerationMilliseconds = llmGenerationMilliseconds
        self.acousticModelLoadMilliseconds = acousticModelLoadMilliseconds
        self.acousticSynthesisMilliseconds = acousticSynthesisMilliseconds
        self.modelPreparationCacheHit = modelPreparationCacheHit
        self.referenceCacheHit = referenceCacheHit
        self.warmedModelCount = warmedModelCount
    }
}

@_spi(Validation)
public struct CosyVoice3FlowStepValidationResult: Sendable {
    public let flowSteps: Int
    public let synthesisMilliseconds: Double
    public let audio: CosyVoice3Audio

    public var audioSeconds: Double {
        Double(audio.samples.count) / Double(audio.sampleRate * audio.channels)
    }

    public var rtf: Double {
        synthesisMilliseconds / 1000.0 / audioSeconds
    }
}

@_spi(Validation)
public struct CosyVoice3FlowStepHeadToHeadReport: Sendable {
    public let flowSteps: [Int]
    public let warmupFlowSteps: Int
    public let warmupMilliseconds: Double
    public let speechTokenSHA256: String
    public let preparationMilliseconds: Double
    public let frontendMilliseconds: Double
    public let llmModelLoadMilliseconds: Double
    public let llmGenerationMilliseconds: Double
    public let acousticModelLoadMilliseconds: Double
    public let variants: [CosyVoice3FlowStepValidationResult]
}

public enum CosyVoice3EngineError: Error, LocalizedError, Sendable {
    case emptyText
    case invalidReference
    case assetRootMissing(String)
    case developmentRuntimeIncomplete(String)
    public var errorDescription: String? {
        switch self {
        case .emptyText: return "Input text is empty."
        case .invalidReference: return "Reference voice requires an existing audio file and a non-empty exact transcript."
        case .assetRootMissing(let path): return "CosyVoice3 asset root is missing or is not a directory: \(path)."
        case .developmentRuntimeIncomplete(let reason): return "CosyVoice3 iOS Development runtime is incomplete: \(reason)"
        }
    }
}

public protocol CosyVoice3SynthesisEngine: Sendable {
    func capabilities() async throws -> CosyVoice3Capabilities
    func validateReference(_ reference: CosyVoice3VoiceReference, probeText: String) async throws
    func synthesize(_ text: String, parameters: CosyVoice3Parameters) async throws -> CosyVoice3Audio
}

public extension CosyVoice3SynthesisEngine {
    func synthesize(_ text: String) async throws -> CosyVoice3Audio { try await synthesize(text, parameters: .init()) }
}

// Purpose: stable public ABI for CosyVoice3 iOS SDK.
// Upstream: ZipVoice release API pattern adapted for CosyVoice3 reference + instruction control.
// Runtime: Swift concurrency, iOS17+.
// Generated: 2026-10-02 America/New_York.

// Changes 2026-10-02: add public preparation telemetry so applications and the Candidate runner can distinguish one-time Core ML/reference preparation from actual synthesis latency without exposing model internals.

// Changes 2026-10-02: add public coarse synthesis stage telemetry to separate preparation, frontend, LLM load/generation and acoustic load/synthesis without exposing private model/shard details.

// Changes 2026-10-02: preparation/synthesis telemetry now reports persistent model-preparation marker hits, reference-conditioning cache hits and the number of model constructors actually warmed.

// Changes 2026-10-02: add validation-SPI-only Flow 10/8/6 head-to-head result types.

// Changes 2026-10-02: promote the physically validated 6/8/10 Flow choices into the stable public API; production defaults to 6 steps while callers may explicitly select 8 or 10, and capabilities/telemetry expose the selected contract.

// Changes 2026-10-03: normalize Swift 6 default-argument syntax and keep CosyVoice3SynthesisReport source-compatible by defaulting its new flowSteps field to the production 6-step setting.
