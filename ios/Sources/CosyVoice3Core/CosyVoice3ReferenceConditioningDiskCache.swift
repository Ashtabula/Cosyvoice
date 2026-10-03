// CosyVoice3ReferenceConditioningDiskCache.swift
// Requirement: persist small derived custom-reference conditioning tensors across engine/process launches without persisting private reference audio or weakening asset identity checks.
import CoreML
import Foundation

@available(iOS 18.0, macOS 15.0, *)
final class CosyVoice3ReferenceConditioningDiskCache {
    private struct Receipt: Codable {
        let schemaVersion: Int
        let cacheKey: String
        let referenceFingerprint: String
        let assetIdentity: String
        let promptTokenCount: Int
        let promptFrameCount: Int
        let speakerDimension: Int
    }

    private let fileManager = FileManager.default
    private let root: URL

    init() throws {
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CosyVoice3AssetError.compiledCache("Application Support directory unavailable")
        }
        root = applicationSupport
            .appendingPathComponent("CosyVoice3Core", isDirectory: true)
            .appendingPathComponent("ReferenceConditioning-v1", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
    }

    func load(cacheKey: String, referenceFingerprint: String, assetIdentity: String) throws -> CosyVoice3ReferenceConditioning? {
        let folder = root.appendingPathComponent(cacheKey, isDirectory: true)
        let receiptURL = folder.appendingPathComponent("receipt.json")
        guard fileManager.fileExists(atPath: receiptURL.path) else { return nil }

        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
        guard receipt.schemaVersion == 1,
              receipt.cacheKey == cacheKey,
              receipt.referenceFingerprint == referenceFingerprint,
              receipt.assetIdentity == assetIdentity,
              receipt.promptTokenCount == 151,
              receipt.promptFrameCount == 302,
              receipt.speakerDimension == 192 else {
            throw CosyVoice3AssetError.compiledCache("reference conditioning cache receipt mismatch")
        }

        let tokens = try loadArray(
            folder.appendingPathComponent("flow_prompt_speech_token.i32"),
            shape: [1,151],
            dataType: .int32,
            bytesPerElement: 4
        )
        let prompt = try loadArray(
            folder.appendingPathComponent("prompt_speech_feat.f32"),
            shape: [1,302,80],
            dataType: .float32,
            bytesPerElement: 4
        )
        let speaker = try loadArray(
            folder.appendingPathComponent("flow_embedding.f32"),
            shape: [1,192],
            dataType: .float32,
            bytesPerElement: 4
        )

        return CosyVoice3ReferenceConditioning(
            fingerprint: referenceFingerprint,
            tensors: [
                "flow_prompt_speech_token": tokens,
                "prompt_speech_feat": prompt,
                "flow_embedding": speaker
            ],
            metadata: [
                "profile": "fixed225-reference151-mel302",
                "reference_sha256": referenceFingerprint,
                "cache": "disk-v1"
            ]
        )
    }

    func store(
        _ value: CosyVoice3ReferenceConditioning,
        cacheKey: String,
        assetIdentity: String
    ) throws {
        guard let tokens = value.tensors["flow_prompt_speech_token"],
              let prompt = value.tensors["prompt_speech_feat"],
              let speaker = value.tensors["flow_embedding"],
              tokens.shape.map(\.intValue) == [1,151], tokens.dataType == .int32,
              prompt.shape.map(\.intValue) == [1,302,80], prompt.dataType == .float32,
              speaker.shape.map(\.intValue) == [1,192], speaker.dataType == .float32 else {
            throw CosyVoice3AssetError.compiledCache("reference conditioning tensors do not match fixed225 cache ABI")
        }

        let destination = root.appendingPathComponent(cacheKey, isDirectory: true)
        let staging = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try writeArray(tokens, to: staging.appendingPathComponent("flow_prompt_speech_token.i32"), bytesPerElement: 4)
            try writeArray(prompt, to: staging.appendingPathComponent("prompt_speech_feat.f32"), bytesPerElement: 4)
            try writeArray(speaker, to: staging.appendingPathComponent("flow_embedding.f32"), bytesPerElement: 4)
            let receipt = Receipt(
                schemaVersion: 1,
                cacheKey: cacheKey,
                referenceFingerprint: value.fingerprint,
                assetIdentity: assetIdentity,
                promptTokenCount: 151,
                promptFrameCount: 302,
                speakerDimension: 192
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(receipt).write(to: staging.appendingPathComponent("receipt.json"), options: .atomic)
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    func remove(cacheKey: String) {
        try? fileManager.removeItem(at: root.appendingPathComponent(cacheKey, isDirectory: true))
    }

    private func loadArray(
        _ url: URL,
        shape: [Int],
        dataType: MLMultiArrayDataType,
        bytesPerElement: Int
    ) throws -> MLMultiArray {
        let data = try Data(contentsOf: url)
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: dataType)
        let expected = array.count * bytesPerElement
        guard data.count == expected else {
            throw CosyVoice3AssetError.compiledCache("reference conditioning cache byte count mismatch: \(url.lastPathComponent)")
        }
        data.withUnsafeBytes { raw in
            if let source = raw.baseAddress { array.dataPointer.copyMemory(from: source, byteCount: expected) }
        }
        return array
    }

    private func writeArray(_ array: MLMultiArray, to url: URL, bytesPerElement: Int) throws {
        let data = Data(bytes: array.dataPointer, count: array.count * bytesPerElement)
        try data.write(to: url, options: .atomic)
    }
}

// Purpose: cache only derived fixed225 reference tensors (~98 KB), keyed by exact reference-audio SHA and reference-asset identity; raw user audio is never copied into this cache.
// Upstream: CosyVoice3CoreMLReferenceEncoder fixed151/302/192 outputs.
// Runtime: iOS18+/macOS15+, Application Support, excluded from backup.
// Generated: 2026-10-02 America/New_York.
