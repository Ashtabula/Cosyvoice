// CosyVoice3NativeFrontend.swift
// Requirement: build the exact CosyVoice3LM inference prefill on device:
// SOS6561 + Qwen(prompt_text + target_text) embeddings + TASK6563, padded to the validated physical224 prefill ABI.
import CoreML
import Foundation
import Tokenizers

enum CosyVoice3NativeFrontendError: Error, Equatable {
    case emptyTarget
    case missingEndOfPrompt
    case prefixTooLong(Int)
    case invalidTextToken(Int)
}

final class CosyVoice3Fixed224Frontend: @unchecked Sendable, CosyVoice3NativeFrontend {
    static let physicalLength = 224
    static let embeddingWidth = 896
    static let endOfPromptToken = 151646

    private let tokenizer: any Tokenizer
    private let textEmbeddings: CosyVoice3FP16EmbeddingTable
    private let speechEmbeddings: CosyVoice3FP16EmbeddingTable
    private let rope: CosyVoice3RoPEConfiguration

    init(
        tokenizer: any Tokenizer,
        textEmbeddings: CosyVoice3FP16EmbeddingTable,
        speechEmbeddings: CosyVoice3FP16EmbeddingTable,
        rope: CosyVoice3RoPEConfiguration
    ) {
        self.tokenizer = tokenizer
        self.textEmbeddings = textEmbeddings
        self.speechEmbeddings = speechEmbeddings
        self.rope = rope
    }

    func prepare(text: String, reference: CosyVoice3VoiceReference?, instruction: String?) async throws -> CosyVoice3PreparedRequest {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw CosyVoice3NativeFrontendError.emptyTarget }

        let referenceTranscript = reference?.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawInstruction = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = rawInstruction.isEmpty
            ? "You are a helpful assistant.<|endofprompt|>" + referenceTranscript
            : rawInstruction

        let promptIDs = tokenizer.encode(text: prompt)
        let targetIDs = tokenizer.encode(text: target)
        guard promptIDs.contains(Self.endOfPromptToken) else { throw CosyVoice3NativeFrontendError.missingEndOfPrompt }
        guard promptIDs.allSatisfy({ $0 >= 0 && $0 < textEmbeddings.rows }),
              targetIDs.allSatisfy({ $0 >= 0 && $0 < textEmbeddings.rows }) else {
            throw CosyVoice3NativeFrontendError.invalidTextToken((promptIDs + targetIDs).first(where: { $0 < 0 || $0 >= textEmbeddings.rows }) ?? -1)
        }

        let logical = 2 + promptIDs.count + targetIDs.count
        guard logical <= Self.physicalLength else { throw CosyVoice3NativeFrontendError.prefixTooLong(logical) }

        let x = try MLMultiArray(shape: [1, 224, 896], dataType: .float16)
        let cos = try MLMultiArray(shape: [1, 1, 224, 64], dataType: .float16)
        let sin = try MLMultiArray(shape: [1, 1, 224, 64], dataType: .float16)
        let mask = try MLMultiArray(shape: [1, 1, 224, 224], dataType: .float16)

        var rows: [Data] = []
        rows.reserveCapacity(logical)
        rows.append(try speechEmbeddings.row(CosyVoice3TokenSemantics.sos))
        for id in promptIDs { rows.append(try textEmbeddings.row(id)) }
        for id in targetIDs { rows.append(try textEmbeddings.row(id)) }
        rows.append(try speechEmbeddings.row(CosyVoice3TokenSemantics.task))

        let xPointer = x.dataPointer.bindMemory(to: UInt8.self, capacity: x.count * 2)
        for position in 0..<Self.physicalLength {
            let row = rows[min(position, logical - 1)]
            row.withUnsafeBytes { raw in
                xPointer.advanced(by: position * Self.embeddingWidth * 2)
                    .update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: Self.embeddingWidth * 2)
            }
        }

        let ropeGenerator = CosyVoice3RoPEGenerator(configuration: rope)
        let cosPointer = cos.dataPointer.bindMemory(to: UInt8.self, capacity: cos.count * 2)
        let sinPointer = sin.dataPointer.bindMemory(to: UInt8.self, capacity: sin.count * 2)
        for position in 0..<Self.physicalLength {
            let sourcePosition = min(position, logical - 1)
            let pair = try ropeGenerator.fp16(position: sourcePosition)
            pair.cos.withUnsafeBytes { raw in
                cosPointer.advanced(by: position * 64 * 2).update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: 64 * 2)
            }
            pair.sin.withUnsafeBytes { raw in
                sinPointer.advanced(by: position * 64 * 2).update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: 64 * 2)
            }
        }

        let maskBits = mask.dataPointer.bindMemory(to: UInt16.self, capacity: mask.count)
        let negativeInfinity = Float16(-Float.infinity).bitPattern
        for q in 0..<224 {
            for k in 0..<224 {
                let allowed: Bool
                if q < logical {
                    allowed = k <= q
                } else {
                    allowed = k < logical
                }
                maskBits[q * 224 + k] = allowed ? 0 : negativeInfinity
            }
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "x": MLFeatureValue(multiArray: x),
            "cos": MLFeatureValue(multiArray: cos),
            "sin": MLFeatureValue(multiArray: sin),
            "mask": MLFeatureValue(multiArray: mask)
        ])

        return CosyVoice3PreparedRequest(
            prefillInput: provider,
            minimumSpeechTokenCount: targetIDs.count * 2,
            maximumSpeechTokenCount: CosyVoice3Fixed225GenerationPolicy.maximumSpeechTokenCount(
                targetTextTokenCount: targetIDs.count,
                logicalPrefixLength: logical
            ),
            logicalPrefixLength: logical
        )
    }
}

struct CosyVoice3RoPEGenerator: Sendable {
    let configuration: CosyVoice3RoPEConfiguration
    func fp16(position: Int) throws -> (cos: Data, sin: Data) {
        try configuration.validate()
        guard position >= 0, position < configuration.maximumPosition else {
            throw CosyVoice3TokenConditionerError.invalidPosition(position)
        }
        let half = configuration.headDimension / 2
        var c = [UInt16](repeating: 0, count: configuration.headDimension)
        var s = [UInt16](repeating: 0, count: configuration.headDimension)
        for i in 0..<half {
            let inv = 1.0 / pow(configuration.theta, Double(2 * i) / Double(configuration.headDimension))
            let angle = Double(position) * inv
            let cv = Float16(cos(angle)).bitPattern
            let sv = Float16(sin(angle)).bitPattern
            c[i] = cv; c[i + half] = cv
            s[i] = sv; s[i + half] = sv
        }
        return (c.withUnsafeBytes { Data($0) }, s.withUnsafeBytes { Data($0) })
    }
}

// Purpose: native equivalent of probe_instruct2_reuse.py prefill_x/cos/sin/mask generation; the publication fixed225 lane preserves upstream 20x max-length semantics but caps it at the 225-token acoustic bucket.
// Upstream: CosyVoice3LM.inference + prepare_instruct2_prefill224_probe.py at8789402.
// Runtime: Swift + CoreML + swift-transformers.
// Generated: 2026-10-02 America/New_York.
