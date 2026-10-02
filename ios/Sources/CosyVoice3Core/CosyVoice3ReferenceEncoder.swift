// CosyVoice3ReferenceEncoder.swift
// Requirement: complete local custom-reference enrollment using native DSP + converted Core ML speech-tokenizer/CAMPPlus assets.
import CoreML
import CryptoKit
import Foundation

extension CosyVoice3ReferenceConditioning: @unchecked Sendable {}

enum CosyVoice3ReferenceEncoderError: Error {
    case missingOutput(String)
    case invalidOutput(String, [Int])
    case insufficientReference(secondsRequired: Double)
}

protocol CosyVoice3ReferenceFeatureExtractor: Sendable {
    func encode(audioURL: URL) async throws -> CosyVoice3ReferenceConditioning
}

@available(iOS 18.0, macOS 15.0, *)
final class CosyVoice3CoreMLReferenceEncoder: CosyVoice3ReferenceFeatureExtractor, @unchecked Sendable {
    static let fixedSeconds = 6.056
    static let fixed16kSamples = 96_896
    static let fixed24kSamples = 145_344
    static let fixedWhisperFrames = 605
    static let fixedCampFrames = 604
    static let fixedPromptTokens = 151
    static let fixedPromptFrames = 302

    private let speechTokenizer: MLModel
    private let campPlus: MLModel
    private let dsp: CosyVoice3ReferenceDSP

    init(speechTokenizer: MLModel, campPlus: MLModel, dsp: CosyVoice3ReferenceDSP) {
        self.speechTokenizer = speechTokenizer
        self.campPlus = campPlus
        self.dsp = dsp
    }

    func encode(audioURL: URL) async throws -> CosyVoice3ReferenceConditioning {
        let audio = try CosyVoice3ReferenceAudio.load(url: audioURL)
        guard audio.samples16k.count >= Self.fixed16kSamples,
              audio.samples24k.count >= Self.fixed24kSamples else {
            throw CosyVoice3ReferenceEncoderError.insufficientReference(secondsRequired: Self.fixedSeconds)
        }
        let audio16 = Array(audio.samples16k.prefix(Self.fixed16kSamples))
        let audio24 = Array(audio.samples24k.prefix(Self.fixed24kSamples))

        let whisper = try dsp.whisperFeatures(audio16)
        guard whisper.shape.map(\.intValue) == [1, 128, Self.fixedWhisperFrames] else {
            throw CosyVoice3ReferenceEncoderError.invalidOutput("whisper128", whisper.shape.map(\.intValue))
        }
        let whisperLength = try MLMultiArray(shape: [1], dataType: .int32)
        whisperLength[0] = NSNumber(value: Self.fixedWhisperFrames)
        let tokenResult = try await speechTokenizer.prediction(
            from: try MLDictionaryFeatureProvider(dictionary: [
                "feats": whisper,
                "feats_length": whisperLength
            ])
        )
        let rawTokens = try output(tokenResult, name: "indices")
        guard rawTokens.count >= Self.fixedPromptTokens else {
            throw CosyVoice3ReferenceEncoderError.invalidOutput("indices", rawTokens.shape.map(\.intValue))
        }

        let fbank = try dsp.campPlusFeatures(audio16)
        guard fbank.shape.map(\.intValue) == [1, Self.fixedCampFrames, 80] else {
            throw CosyVoice3ReferenceEncoderError.invalidOutput("campplus_fbank", fbank.shape.map(\.intValue))
        }
        let speakerResult = try await campPlus.prediction(
            from: try MLDictionaryFeatureProvider(dictionary: ["input": fbank])
        )
        let rawSpeaker = try output(speakerResult, name: "output")
        guard rawSpeaker.count == 192 else {
            throw CosyVoice3ReferenceEncoderError.invalidOutput("output", rawSpeaker.shape.map(\.intValue))
        }

        let rawMel = try dsp.promptMel(audio24)
        guard rawMel.shape.map(\.intValue) == [1, 80, Self.fixedPromptFrames] else {
            throw CosyVoice3ReferenceEncoderError.invalidOutput("prompt_mel", rawMel.shape.map(\.intValue))
        }

        let flowTokens = try MLMultiArray(shape: [1, Self.fixedPromptTokens as NSNumber], dataType: .int32)
        let tokenPointer = flowTokens.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<Self.fixedPromptTokens { tokenPointer[i] = Int32(rawTokens[i].intValue) }

        let promptFeat = try MLMultiArray(shape: [1, Self.fixedPromptFrames as NSNumber, 80], dataType: .float32)
        let featPointer = promptFeat.dataPointer.assumingMemoryBound(to: Float.self)
        for frame in 0..<Self.fixedPromptFrames {
            for mel in 0..<80 {
                featPointer[frame * 80 + mel] = rawMel[mel * Self.fixedPromptFrames + frame].floatValue
            }
        }

        let speaker = try MLMultiArray(shape: [1, 192], dataType: .float32)
        let speakerPointer = speaker.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<192 { speakerPointer[i] = rawSpeaker[i].floatValue }

        let data = try Data(contentsOf: audioURL)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return CosyVoice3ReferenceConditioning(
            fingerprint: fingerprint,
            tensors: [
                "flow_prompt_speech_token": flowTokens,
                "prompt_speech_feat": promptFeat,
                "flow_embedding": speaker
            ],
            metadata: [
                "profile": "fixed225-reference151-mel302",
                "reference_sha256": fingerprint,
                "reference_window_seconds": String(Self.fixedSeconds)
            ]
        )
    }

    private func output(_ provider: MLFeatureProvider, name: String) throws -> MLMultiArray {
        guard let value = provider.featureValue(for: name)?.multiArrayValue else {
            throw CosyVoice3ReferenceEncoderError.missingOutput(name)
        }
        return value
    }
}

@available(iOS 18.0, macOS 15.0, *)
final class CosyVoice3ReferenceAwareFrontend: CosyVoice3NativeFrontend, @unchecked Sendable {
    private let base: CosyVoice3Fixed224Frontend
    private let encoder: any CosyVoice3ReferenceFeatureExtractor

    init(base: CosyVoice3Fixed224Frontend, encoder: any CosyVoice3ReferenceFeatureExtractor) {
        self.base = base
        self.encoder = encoder
    }

    func prepare(text: String, reference: CosyVoice3VoiceReference?, instruction: String?) async throws -> CosyVoice3PreparedRequest {
        guard let reference else {
            return try await base.prepare(text: text, reference: nil, instruction: instruction)
        }
        async let conditioning = encoder.encode(audioURL: reference.audioURL)
        let prepared = try await base.prepare(text: text, reference: reference, instruction: instruction)
        return CosyVoice3PreparedRequest(
            prefillInput: prepared.prefillInput,
            minimumSpeechTokenCount: prepared.minimumSpeechTokenCount,
            maximumSpeechTokenCount: prepared.maximumSpeechTokenCount,
            logicalPrefixLength: prepared.logicalPrefixLength,
            referenceConditioning: try await conditioning
        )
    }
}

// Purpose: native replacement for frontend.py reference enrollment for the fixed225 SDK profile.
// Upstream: CosyVoice3_NPU@8789402. Fixed lane consumes first 6.056s to produce exactly 151 prompt tokens / 302 prompt mel frames.
// Runtime: iOS18+/macOS15+, CoreML + Accelerate + AVFoundation.
// Generated: 2026-10-02 America/New_York.
