// CosyVoice3AssetLoader.swift
// Requirement: fail-closed SDK asset loading for both the frozen fixed225 oracle and the dynamic-acoustic production candidate, with persistent compiled Core ML caching so repeated synthesis never recompiles immutable .mlpackage assets.
import CoreML
import CryptoKit
import Foundation

enum CosyVoice3AssetError: Error, Equatable { case missing(String); case invalidJSON(String); case unsupportedProfile(String); case compiledCache(String) }

enum CosyVoice3ModelComputePlacement {
    // Physical iPhone validation: stateful LLM prefill/decode must remain CPU_ONLY.
    // CPU_AND_NE previously failed execution-plan construction with Core ML error -14.
    static let llm: MLComputeUnits = .cpuOnly
    // Dynamic/fixed acoustic Core ML graphs use the accepted CPU_AND_NE request policy.
    // This is a requested compute-unit policy, not a residency claim.
    static let acoustic: MLComputeUnits = .cpuAndNeuralEngine
    static let referenceEncoder: MLComputeUnits = .cpuOnly
}

struct CosyVoice3ModelWarmSpec: @unchecked Sendable {
    let path: String
    let computeUnits: MLComputeUnits
    let reshapeFrequencyInfrequent: Bool

    init(
        _ path: String,
        computeUnits: MLComputeUnits = CosyVoice3ModelComputePlacement.acoustic,
        reshapeFrequencyInfrequent: Bool = false
    ) {
        self.path = path
        self.computeUnits = computeUnits
        self.reshapeFrequencyInfrequent = reshapeFrequencyInfrequent
    }

    static func llm(_ path: String) -> Self {
        .init(path, computeUnits: CosyVoice3ModelComputePlacement.llm)
    }

    static func dynamicAcoustic(_ path: String) -> Self {
        .init(
            path,
            computeUnits: CosyVoice3ModelComputePlacement.acoustic,
            reshapeFrequencyInfrequent: true
        )
    }
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
            throw CosyVoice3AssetError.invalidJSON("invalid reference enrollment contract")
        }
    }
}

struct CosyVoice3DynamicAcousticAssets: Codable, Sendable {
    let status: String
    let speechTokenMinimum: Int
    let speechTokenMaximum: Int
    let promptFrameCount: Int
    let defaultPromptTokens: String
    let defaultPromptFeat: String
    let defaultSpeaker: String
    let flowNoiseMaximum: String
    let hiftExcitationMaximum: String

    func validate() throws {
        guard status == "CANDIDATE",
              speechTokenMinimum >= 1,
              speechTokenMaximum >= speechTokenMinimum,
              speechTokenMaximum <= CosyVoice3FP16StatefulLLMSession.capacity,
              promptFrameCount == 302,
              !defaultPromptTokens.isEmpty,
              !defaultPromptFeat.isEmpty,
              !defaultSpeaker.isEmpty,
              !flowNoiseMaximum.isEmpty,
              !hiftExcitationMaximum.isEmpty else {
            throw CosyVoice3AssetError.invalidJSON("invalid dynamic acoustic contract")
        }
    }

    var maximumFlowFrames: Int { promptFrameCount + 2 * speechTokenMaximum }
    var maximumMelFrames: Int { 2 * speechTokenMaximum }
    var maximumPCMSamples: Int { 960 * speechTokenMaximum }
}

struct CosyVoice3AssetManifest: Codable, Sendable {
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
    let flowMask: String?
    let flowNoise: String?
    let ropeTheta: Double
    let textEmbeddingRows: Int
    let referenceEnrollment: CosyVoice3ReferenceEnrollmentAssets?
    let dynamicAcoustic: CosyVoice3DynamicAcousticAssets?

    var isDynamicAcoustic: Bool { profile.hasPrefix("ios18-dynamic-") }
    var manifestFileName: String { isDynamicAcoustic ? "cosyvoice3_dynamic.json" : "cosyvoice3_fixed225.json" }

    func validate() throws {
        guard flowShards.count == 6,
              ropeTheta > 0,
              textEmbeddingRows > 151646,
              !tokenizerFolder.isEmpty,
              !textEmbedding.isEmpty,
              !llmPrefill.isEmpty,
              !llmDecode.isEmpty,
              !speechEmbedding.isEmpty,
              !flowConditions.isEmpty,
              !hift.isEmpty,
              !f0Folder.isEmpty else {
            throw CosyVoice3AssetError.unsupportedProfile(profile)
        }

        if profile == "ios18-fixed225" {
            guard schemaVersion == 1,
                  dynamicAcoustic == nil,
                  flowMask?.isEmpty == false,
                  flowNoise?.isEmpty == false else {
                throw CosyVoice3AssetError.unsupportedProfile(profile)
            }
        } else if isDynamicAcoustic {
            guard schemaVersion == 2, let dynamicAcoustic else {
                throw CosyVoice3AssetError.unsupportedProfile(profile)
            }
            try dynamicAcoustic.validate()
        } else {
            throw CosyVoice3AssetError.unsupportedProfile(profile)
        }
        try referenceEnrollment?.validate()
    }
}

typealias CosyVoice3Fixed225AssetManifest = CosyVoice3AssetManifest

@available(iOS 18.0, macOS 15.0, *)
enum CosyVoice3AssetLoader {
    private final class CacheState: @unchecked Sendable {
        let lock = NSLock()
        var resolvedCompiledURLs: [String: URL] = [:]
        var selectedLLMComputeUnitsByRoute: [String: MLComputeUnits] = [:]
    }

    private static let cacheState = CacheState()
    private static let compiledCacheVersion = "v1"

    static func loadManifest(root: URL) throws -> CosyVoice3AssetManifest {
        let names = ["cosyvoice3_dynamic.json", "cosyvoice3_fixed225.json"]
        guard let url = names.map({ root.appendingPathComponent($0) }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw CosyVoice3AssetError.missing(names.joined(separator: " or "))
        }
        do {
            let manifest = try JSONDecoder().decode(CosyVoice3AssetManifest.self, from: Data(contentsOf: url))
            try manifest.validate()
            guard manifest.manifestFileName == url.lastPathComponent else {
                throw CosyVoice3AssetError.invalidJSON("manifest/profile filename mismatch: \(url.lastPathComponent) profile=\(manifest.profile)")
            }
            return manifest
        } catch let error as CosyVoice3AssetError {
            throw error
        } catch {
            throw CosyVoice3AssetError.invalidJSON(String(describing: error))
        }
    }

    static func model(
        root: URL,
        path: String,
        computeUnits: MLComputeUnits = CosyVoice3ModelComputePlacement.acoustic,
        reshapeFrequencyInfrequent: Bool = false
    ) throws -> MLModel {
        let source = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: source.path) else { throw CosyVoice3AssetError.missing(source.path) }
        let compiled = try compiledModelURL(source: source)
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        if reshapeFrequencyInfrequent {
            config.optimizationHints.reshapeFrequency = .infrequent
        }
        do {
            return try MLModel(contentsOf: compiled, configuration: config)
        } catch {
            throw CosyVoice3AssetError.compiledCache(
                "MLModel load failed path=\(path) computeUnits=\(String(describing: computeUnits)) reshapeFrequencyInfrequent=\(reshapeFrequencyInfrequent) compiled=\(compiled.lastPathComponent) error=\(String(describing: error))"
            )
        }
    }

    static func llmModel(root: URL, path: String) throws -> MLModel {
        try model(root: root, path: path, computeUnits: CosyVoice3ModelComputePlacement.llm)
    }

    static func llmModelPair(
        root: URL,
        prefillPath: String,
        decodePath: String
    ) throws -> (prefill: MLModel, decode: MLModel, computeUnits: MLComputeUnits, routeKey: String) {
        let routeKey = llmRouteKey(root: root, prefillPath: prefillPath, decodePath: decodePath)
        cacheState.lock.lock()
        let cachedUnits = cacheState.selectedLLMComputeUnitsByRoute[routeKey]
        cacheState.lock.unlock()

        if let cachedUnits {
            do {
                let prefill = try model(root: root, path: prefillPath, computeUnits: cachedUnits)
                let decode = try model(root: root, path: decodePath, computeUnits: cachedUnits)
                print("[COSY-LLM-ROUTE] reuse computeUnits=\(String(describing: cachedUnits))")
                return (prefill, decode, cachedUnits, routeKey)
            } catch {
                print("[COSY-LLM-ROUTE] cached route rejected computeUnits=\(String(describing: cachedUnits)) error=\(String(describing: error))")
                cacheState.lock.lock()
                cacheState.selectedLLMComputeUnitsByRoute.removeValue(forKey: routeKey)
                cacheState.lock.unlock()
            }
        }

        var lastError: Error?
        for units: MLComputeUnits in [.cpuAndNeuralEngine, .all, .cpuOnly] {
            do {
                let prefill = try model(root: root, path: prefillPath, computeUnits: units)
                let decode = try model(root: root, path: decodePath, computeUnits: units)
                print("[COSY-LLM-ROUTE] candidate computeUnits=\(String(describing: units))")
                return (prefill, decode, units, routeKey)
            } catch {
                lastError = error
                print("[COSY-LLM-ROUTE] rejected computeUnits=\(String(describing: units)) error=\(String(describing: error))")
            }
        }
        throw lastError ?? CosyVoice3AssetError.compiledCache(
            "no Core ML compute route could construct both CosyVoice3 LLM models"
        )
    }

    static func confirmLLMComputeUnits(_ units: MLComputeUnits, routeKey: String) {
        cacheState.lock.lock()
        cacheState.selectedLLMComputeUnitsByRoute[routeKey] = units
        cacheState.lock.unlock()
        print("[COSY-LLM-ROUTE] confirmed route=\(routeKey) computeUnits=\(String(describing: units))")
    }

    static func rejectLLMComputeUnits(_ units: MLComputeUnits, routeKey: String) {
        cacheState.lock.lock()
        if cacheState.selectedLLMComputeUnitsByRoute[routeKey] == units {
            cacheState.selectedLLMComputeUnitsByRoute.removeValue(forKey: routeKey)
        }
        cacheState.lock.unlock()
        print("[COSY-LLM-ROUTE] rejected after prediction route=\(routeKey) computeUnits=\(String(describing: units))")
    }

    static func isRetryableCoreMLFailure(_ error: Error) -> Bool {
        if case CosyVoice3AssetError.compiledCache(let message) = error {
            let text = message.lowercased()
            return text.contains("coreml") || text.contains("core ml") || text.contains("execution plan") || text.contains("error code: -14")
        }
        let nsError = error as NSError
        if nsError.domain.lowercased().contains("coreml") { return true }
        if nsError.localizedDescription.lowercased().contains("core ml") { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isRetryableCoreMLFailure(underlying)
        }
        return false
    }

    private static func llmRouteKey(root: URL, prefillPath: String, decodePath: String) -> String {
        [
            root.standardizedFileURL.path,
            prefillPath,
            decodePath
        ].joined(separator: "|")
    }

    static func dynamicAcousticModel(root: URL, path: String) throws -> MLModel {
        try model(
            root: root,
            path: path,
            computeUnits: CosyVoice3ModelComputePlacement.acoustic,
            reshapeFrequencyInfrequent: true
        )
    }

    static func warmModels(
        root: URL,
        specs: [CosyVoice3ModelWarmSpec],
        maximumConcurrent: Int = 1,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        guard maximumConcurrent == 1 else {
            throw CosyVoice3AssetError.compiledCache(
                "parallel Core ML execution-plan construction is disabled on the validated iPhone path; maximumConcurrent must be 1"
            )
        }
        for (index, spec) in specs.enumerated() {
            progress?("prepare.model.\(index + 1).\(specs.count).begin:\(spec.path)")
            try autoreleasepool {
                let warmed = try model(
                    root: root,
                    path: spec.path,
                    computeUnits: spec.computeUnits,
                    reshapeFrequencyInfrequent: spec.reshapeFrequencyInfrequent
                )
                _ = warmed.modelDescription
            }
            progress?("prepare.model.\(index + 1).\(specs.count).end:\(spec.path)")
            // Yield between large constructors so Core ML can tear down temporary
            // execution-plan resources before the next model is specialized.
            await Task.yield()
        }
    }

    static func hasWarmMarker(root: URL, specs: [CosyVoice3ModelWarmSpec]) throws -> Bool {
        let marker = try warmMarkerURL(root: root, specs: specs)
        return FileManager.default.fileExists(atPath: marker.path)
    }

    static func storeWarmMarker(root: URL, specs: [CosyVoice3ModelWarmSpec]) throws {
        let marker = try warmMarkerURL(root: root, specs: specs)
        try Data("ready\n".utf8).write(to: marker, options: .atomic)
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
        let processKey = ProcessInfo.processInfo.operatingSystemVersionString + "|" + source.standardizedFileURL.path

        cacheState.lock.lock()
        defer { cacheState.lock.unlock() }

        var isDirectory: ObjCBool = false
        if let cached = cacheState.resolvedCompiledURLs[processKey],
           fileManager.fileExists(atPath: cached.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return cached
        }

        let cacheRoot = try compiledModelCacheRoot(fileManager: fileManager)
        let fingerprint = try sourceFingerprint(source, fileManager: fileManager)
        let digest = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = cacheRoot.appendingPathComponent(digest + ".mlmodelc", isDirectory: true)

        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            cacheState.resolvedCompiledURLs[processKey] = destination
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
        cacheState.resolvedCompiledURLs[processKey] = destination
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

    private static func warmMarkerURL(root: URL, specs: [CosyVoice3ModelWarmSpec]) throws -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CosyVoice3AssetError.compiledCache("Caches directory unavailable")
        }
        let markerRoot = caches
            .appendingPathComponent("CosyVoice3Core", isDirectory: true)
            .appendingPathComponent("PreparedModelPlans-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: markerRoot, withIntermediateDirectories: true)

        let loadedManifest = try loadManifest(root: root)
        let manifest = root.appendingPathComponent(loadedManifest.manifestFileName)
        let manifestData = try Data(contentsOf: manifest)
        let manifestHash = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        let rows = specs.map {
            $0.path + "|" + String(describing: $0.computeUnits) + "|reshapeInfrequent=" + String($0.reshapeFrequencyInfrequent)
        }.sorted()
        let identity = [
            ProcessInfo.processInfo.operatingSystemVersionString,
            root.standardizedFileURL.path,
            manifestHash,
            rows.joined(separator: "\n")
        ].joined(separator: "\n")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return markerRoot.appendingPathComponent(key + ".ready")
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

// Purpose: centralize immutable fixed225-or-dynamic assets, gate custom-reference enrollment on explicit device-parity promotion, and persist compiled Core ML artifacts outside each synthesis call.
// Upstream: CosyVoice3_NPU@8789402; stable compiled-artifact lifecycle follows the accepted StatefulLLMBench full-pipeline strategy.
// Runtime: iOS18+/macOS15+.
// Generated: 2026-10-02 America/New_York.
// Changes 2026-10-02: .mlpackage assets now compile once into Library/Caches/CosyVoice3Core and subsequent model construction reuses the stable .mlmodelc; cache identity includes OS version, standardized source path and package file sizes/mtimes and remains fail-closed.\n// Changes 2026-10-02: add bounded batch warm-up that releases every MLModel after constructor/execution-plan preparation; maximumConcurrent defaults to two so cold-start specialization can overlap without reintroducing the rejected all-model-residency memory profile. Asset metadata fingerprints are also exposed internally for safe derived-cache invalidation.\n
// Changes 2026-10-02: memoize resolved stable .mlmodelc URLs within the process after the first full package fingerprint/cache check; immutable SDK assets therefore avoid repeated package-tree enumeration on warm model construction.

// Changes 2026-10-02: wrap process-local compiled-URL memoization in a locked @unchecked Sendable reference so Swift 6 strict concurrency sees no unisolated mutable static storage.

// Changes 2026-10-02: store a same-install/OS/runtime-plan performance-only warm marker after successful model preparation; process relaunch can skip redundant prewarm, while actual MLModel construction remains authoritative and safely rebuilds if Core ML system caches were evicted.

// Changes 2026-10-02: disable concurrent Core ML execution-plan constructors after physical iPhone18,4 returned Core ML -14 during two-model cold prewarm; first-use specialization is serialized with an autoreleasepool/yield boundary, and model-load errors now identify the exact asset path/computeUnits/compiled cache entry.

// Changes 2026-10-04: add schemaVersion2 ios18-dynamic-* manifests with exact dynamic acoustic bounds/default conditioning/max noise/excitation assets. Loader prefers cosyvoice3_dynamic.json when present and otherwise preserves the frozen cosyvoice3_fixed225.json path.

// Changes 2026-10-04: optional validation-only progress callback around each serialized model warm; nil default leaves production compilation/loading/lifetime behavior unchanged.

// Changes 2026-10-04: centralize validated mixed compute placement. Stateful LLM warm/load is CPU_ONLY to avoid physical iPhone Core ML -14; acoustic defaults remain CPU_AND_NE; reference encoders remain CPU_ONLY. Added llmModel()/WarmSpec.llm so call sites cannot silently inherit acoustic placement.

// Changes 2026-10-04: dynamic acoustic model configuration now matches the physically accepted shape-sweep probe by setting optimizationHints.reshapeFrequency=.infrequent for both warm and prediction loads. The hint participates in warm-marker identity; fixed225/LLM/reference behavior is unchanged unless explicitly selected.

// Changes 2026-10-04 performance candidate: add process-cached LLM route negotiation (CPU_AND_NE -> ALL -> CPU_ONLY); a route is accepted only if both stateful prefill and decode models construct. Baseline CPU_ONLY constant and immutable model bytes remain unchanged.

// Changes 2026-10-04 performance candidate follow-up: accelerator LLM route is cached only after a complete generation succeeds; prediction-time failure can reject the route and permit a fresh CPU_ONLY retry.

// Changes 2026-10-05: key negotiated LLM compute placement by asset root + prefill/decode paths so unrelated profiles cannot share a stale route; expose a fail-closed Core ML error classifier so sampler/contract/runtime logic errors are never silently retried as accelerator failures.
