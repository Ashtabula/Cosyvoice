// CosyVoice3EmbeddingTables.swift
// Requirement: perform Qwen text and CosyVoice3 speech/special embedding lookup fully on device.
import Foundation

enum CosyVoice3EmbeddingTableError: Error, Equatable {
    case invalidByteCount(expected: Int, actual: Int)
    case invalidToken(Int)
}

final class CosyVoice3FP16EmbeddingTable: @unchecked Sendable {
    let rows: Int
    let width: Int
    private let data: Data
    // Read-only value sharing retains Data storage; neither consumer mutates it.
    var rawFP16Data: Data { data }

    init(url: URL, rows: Int, width: Int = 896) throws {
        let bytes = try Data(contentsOf: url)
        let expected = rows * width * 2
        guard bytes.count == expected else {
            throw CosyVoice3EmbeddingTableError.invalidByteCount(expected: expected, actual: bytes.count)
        }
        self.rows = rows
        self.width = width
        self.data = bytes
    }

    func row(_ token: Int) throws -> Data {
        guard token >= 0, token < rows else { throw CosyVoice3EmbeddingTableError.invalidToken(token) }
        let rowBytes = width * 2
        let start = token * rowBytes
        return data.subdata(in: start..<(start + rowBytes))
    }
}

// Purpose: replace Python/PyTorch embedding lookup with immutable FP16 tables.
// Upstream: llm.model.model.embed_tokens.weight and llm.speech_embedding.weight at CosyVoice3_NPU@8789402.
// Runtime: pure Swift.
// Generated: 2026-10-02 America/New_York.

// Purpose: share immutable speech table storage with the decoder conditioner instead of loading identical bytes twice.
// Upstream: existing FP16 embedding table; environment Swift6/iOS18+/macOS15+; generated2026-10-06 07:32 EDT America/New_York.
// Changed lines14-16: internal read-only Data accessor; row/error semantics unchanged.
