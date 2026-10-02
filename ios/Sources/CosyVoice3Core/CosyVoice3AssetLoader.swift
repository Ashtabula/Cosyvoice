// CosyVoice3AssetLoader.swift
// Requirement: fail-closed SDK asset loading for the validated fixed225 production lane.
import CoreML
import Foundation

enum CosyVoice3AssetError: Error, Equatable { case missing(String); case invalidJSON(String); case unsupportedProfile(String) }

struct CosyVoice3ReferenceEnrollmentAssets: Codable, Sendable {
    let status: String
    let speechTokenizer: String
    let campPlus: String
    let whisperMel128: String
    let kaldiMel80: String
    let matchaMel80: String
    let flowConditionsDynamic: String
    let promptTokenCount: Int
    let promptFrameCount: Int

    var isPromoted: Bool { status == "PASS_DEVICE_PARITY" }

    func validate() throws {
        guard !speechTokenizer.isEmpty, !campPlus.isEmpty,
              !whisperMel128.isEmpty, !kaldiMel80.isEmpty, !matchaMel80.isEmpty,
              !flowConditionsDynamic.isEmpty,
              promptTokenCount == 151, promptFrameCount == 302 else {
            throw CosyVoice3AssetError.invalidJSON("invalid fixed225 reference enrollment contract")
        }
    }
}

struct CosyVoice3Fixed225AssetManifest: Codable, Sendable {
    let schemaVersion: Int
    let profile: String
    let tokenizerFolder: String
    let textEmbedding: String
    let llmPrefill: String
    let llmDecode: String
    let speechEmbedding: String
    let flowConditions: String
    let flowShards: [String]
    let hift: String
    let f0Folder: String
    let flowMask: String
    let flowNoise: String
    let ropeTheta: Double
    let textEmbeddingRows: Int
    let referenceEnrollment: CosyVoice3ReferenceEnrollmentAssets?

    func validate() throws {
        guard schemaVersion == 1,
              profile == "ios18-fixed225",
              flowShards.count == 6,
              ropeTheta > 0,
              textEmbeddingRows > 151646,
              !tokenizerFolder.isEmpty,
              !textEmbedding.isEmpty else {
            throw CosyVoice3AssetError.unsupportedProfile(profile)
        }
        try referenceEnrollment?.validate()
    }
}

@available(iOS 18.0, macOS 15.0, *)
enum CosyVoice3AssetLoader {
    static func loadManifest(root: URL) throws -> CosyVoice3Fixed225AssetManifest {
        let url = root.appendingPathComponent("cosyvoice3_fixed225.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw CosyVoice3AssetError.missing(url.path) }
        do {
            let manifest = try JSONDecoder().decode(CosyVoice3Fixed225AssetManifest.self, from: Data(contentsOf: url))
            try manifest.validate()
            return manifest
        } catch let error as CosyVoice3AssetError {
            throw error
        } catch {
            throw CosyVoice3AssetError.invalidJSON(String(describing: error))
        }
    }

    static func model(root: URL, path: String, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws -> MLModel {
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CosyVoice3AssetError.missing(url.path) }
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        return try MLModel(contentsOf: compiled, configuration: config)
    }

    static func array(root: URL, path: String, shape: [Int], type: MLMultiArrayDataType) throws -> MLMultiArray {
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CosyVoice3AssetError.missing(url.path) }
        let data = try Data(contentsOf: url)
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: type)
        let bytesPerElement = type == .float16 ? 2 : 4
        let expected = array.count * bytesPerElement
        guard data.count == expected else { throw CosyVoice3AssetError.invalidJSON("asset byte count mismatch \(path)") }
        data.withUnsafeBytes { raw in array.dataPointer.copyMemory(from: raw.baseAddress!, byteCount: expected) }
        return array
    }
}

// Purpose: centralize immutable fixed225 assets and gate custom-reference enrollment on explicit device-parity promotion.
// Upstream: CosyVoice3_NPU@8789402.
// Runtime: iOS18+/macOS15+.
// Generated: 2026-10-02 America/New_York.
