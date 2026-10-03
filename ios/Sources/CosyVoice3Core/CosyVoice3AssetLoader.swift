// CosyVoice3AssetLoader.swift
// Requirement: fail-closed SDK asset loading for the validated fixed225 production lane, with persistent compiled Core ML caching so repeated synthesis never recompiles immutable .mlpackage assets.
import CoreML
import CryptoKit
import Foundation

enum CosyVoice3AssetError: Error, Equatable { case missing(String); case invalidJSON(String); case unsupportedProfile(String); case compiledCache(String) }

struct CosyVoice3ModelWarmSpec: @unchecked Sendable {
    let path: String
    let computeUnits: MLComputeUnits
    init(_ path: String, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) { self.path = path; self.computeUnits = computeUnits }
}

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
    private static let compileLock = NSLock()
    private static let compiledCacheVersion = "v1"

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
        let source = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: source.path) else { throw CosyVoice3AssetError.missing(source.path) }
        let compiled = try compiledModelURL(source: source)
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        return try MLModel(contentsOf: compiled, configuration: config)
    }

    static func warmModels(root: URL, specs: [CosyVoice3ModelWarmSpec], maximumConcurrent: Int = 2) async throws {
        guard maximumConcurrent > 0 else { throw CosyVoice3AssetError.compiledCache("maximumConcurrent must be positive") }
        var offset = 0
        while offset < specs.count {
            let upper = min(offset + maximumConcurrent, specs.count)
            let batch = Array(specs[offset..<upper])
            try await withThrowingTaskGroup(of: Void.self) { group in
                for spec in batch {
                    group.addTask {
                        try autoreleasepool {
                            let warmed = try model(root: root, path: spec.path, computeUnits: spec.computeUnits)
                            _ = warmed.modelDescription
                        }
                    }
                }
                try await group.waitForAll()
            }
            offset = upper
        }
    }

    static func assetCacheIdentity(root: URL, paths: [String]) throws -> String {
        let fileManager = FileManager.default
        var rows: [String] = []
        rows.reserveCapacity(paths.count)
        for path in paths.sorted() {
            let source = root.appendingPathComponent(path)
            guard fileManager.fileExists(atPath: source.path) else { throw CosyVoice3AssetError.missing(source.path) }
            rows.append(try sourceFingerprint(source, fileManager: fileManager))
        }
        return SHA256.hash(data: Data(rows.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
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

    private static func compiledModelURL(source: URL) throws -> URL {
        if source.pathExtension == "mlmodelc" { return source }

        let fileManager = FileManager.default
        let cacheRoot = try compiledModelCacheRoot(fileManager: fileManager)
        let fingerprint = try sourceFingerprint(source, fileManager: fileManager)
        let digest = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = cacheRoot.appendingPathComponent(digest + ".mlmodelc", isDirectory: true)

        compileLock.lock()
        defer { compileLock.unlock() }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return destination
        }

        let compiledTemporary = try MLModel.compileModel(at: source)
        let staging = cacheRoot.appendingPathComponent(".staging-" + UUID().uuidString + ".mlmodelc", isDirectory: true)
        do {
            try fileManager.copyItem(at: compiledTemporary, to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw CosyVoice3AssetError.compiledCache(String(describing: error))
        }
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CosyVoice3AssetError.compiledCache("compiled model cache was not materialized: \(destination.path)")
        }
        return destination
    }

    private static func compiledModelCacheRoot(fileManager: FileManager) throws -> URL {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CosyVoice3AssetError.compiledCache("Caches directory unavailable")
        }
        let root = caches
            .appendingPathComponent("CosyVoice3Core", isDirectory: true)
            .appendingPathComponent("CompiledModels-" + compiledCacheVersion, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func sourceFingerprint(_ source: URL, fileManager: FileManager) throws -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            let values = try source.resourceValues(forKeys: [.contentModificationDateKey])
            return [compiledCacheVersion, ProcessInfo.processInfo.operatingSystemVersionString, source.standardizedFileURL.path, String(values.contentModificationDate?.timeIntervalSince1970 ?? 0)].joined(separator: "|")
        }

        var rows: [String] = [compiledCacheVersion, ProcessInfo.processInfo.operatingSystemVersionString, source.standardizedFileURL.path]
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            let relative = String(item.path.dropFirst(source.path.count))
            rows.append([
                relative,
                String(values.fileSize ?? -1),
                String(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            ].joined(separator: ":"))
        }
        rows.sort()
        return rows.joined(separator: "|")
    }
}

// Purpose: centralize immutable fixed225 assets, gate custom-reference enrollment on explicit device-parity promotion, and persist compiled Core ML artifacts outside each synthesis call.
// Upstream: CosyVoice3_NPU@8789402; stable compiled-artifact lifecycle follows the accepted StatefulLLMBench full-pipeline strategy.
// Runtime: iOS18+/macOS15+.
// Generated: 2026-10-02 America/New_York.
// Changes 2026-10-02: .mlpackage assets now compile once into Library/Caches/CosyVoice3Core and subsequent model construction reuses the stable .mlmodelc; cache identity includes OS version, standardized source path and package file sizes/mtimes and remains fail-closed.\n// Changes 2026-10-02: add bounded batch warm-up that releases every MLModel after constructor/execution-plan preparation; maximumConcurrent defaults to two so cold-start specialization can overlap without reintroducing the rejected all-model-residency memory profile. Asset metadata fingerprints are also exposed internally for safe derived-cache invalidation.\n