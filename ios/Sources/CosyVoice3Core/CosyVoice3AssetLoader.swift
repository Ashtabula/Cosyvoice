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

// Validation-only role overrides. No fallback: malformed/duplicate requests throw before load.
enum CosyVoice3ValidationPlacement {
    static let roles = ["llmPrefill", "llmDecode", "conditions", "flow0", "flow1", "flow2", "flow3", "flow4", "flow5", "hift", "speechTokenizer", "campPlus"]
    static func role(for path: String) -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if name.contains("prefill") { return "llmPrefill" }
        if name.contains("decode") { return "llmDecode" }
        if name.contains("speech-tokenizer") { return "speechTokenizer" }
        if name.contains("campplus") { return "campPlus" }
        if path.hasPrefix("enumerated-acoustic/") {
            if name == "conditions.mlpackage" { return "conditions" }
            if name == "hift.mlpackage" { return "hift" }
            for index in 0..<6 where name == "flow-shard-\(index).mlpackage" { return "flow\(index)" }
        }
        return nil
    }
    static func overrides(arguments: [String] = CommandLine.arguments) throws -> [String: MLComputeUnits] {
        var result: [String: MLComputeUnits] = [:]
        for arg in arguments where arg.hasPrefix("--validation-placement=") {
            let pair = String(arg.dropFirst("--validation-placement=".count)).split(separator: ":", omittingEmptySubsequences: false)
            guard pair.count == 2, roles.contains(String(pair[0])), result[String(pair[0])] == nil else {
                throw CosyVoice3AssetError.compiledCache("invalid/duplicate validation placement: \(arg)")
            }
            let units: MLComputeUnits
            switch pair[1] {
            case "CPU_ONLY": units = .cpuOnly
            case "CPU_AND_GPU": units = .cpuAndGPU
            case "CPU_AND_NE": units = .cpuAndNeuralEngine
            default: throw CosyVoice3AssetError.compiledCache("unknown validation placement: \(arg)")
            }
            result[String(pair[0])] = units
        }
        return result
    }
}

struct CosyVoice3ModelWarmSpec: @unchecked Sendable {
    let path: String
    let computeUnits: MLComputeUnits
    let reshapeFrequencyInfrequent: Bool
    let functionName: String?

    init(
        _ path: String,
        computeUnits: MLComputeUnits = CosyVoice3ModelComputePlacement.acoustic,
        reshapeFrequencyInfrequent: Bool = false,
        functionName: String? = nil
    ) {
        self.path = path
        self.computeUnits = computeUnits
        self.reshapeFrequencyInfrequent = reshapeFrequencyInfrequent
        self.functionName = functionName
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
        guard ["CANDIDATE", "PASS_DEVICE_VALIDATION"].contains(status),
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

struct CosyVoice3EnumeratedShapeFamily: Codable, Sendable, Equatable {
    let speechTokenMinimum: Int
    let speechTokenMaximum: Int
    let functionName: String

    var count: Int { speechTokenMaximum - speechTokenMinimum + 1 }

    func contains(_ n: Int) -> Bool {
        n >= speechTokenMinimum && n <= speechTokenMaximum
    }
}

struct CosyVoice3EnumeratedAcousticAssets: Codable, Sendable {
    let status: String
    let speechTokenMinimum: Int
    let speechTokenMaximum: Int
    let promptFrameCount: Int
    let logicalPrefixMaximumForFullSpeechWindow: Int
    let families: [CosyVoice3EnumeratedShapeFamily]
    let defaultPromptTokens: String
    let defaultPromptFeat: String
    let defaultSpeaker: String
    let flowNoiseMaximum: String
    let hiftExcitationMaximum: String

    func validate() throws {
        guard ["CANDIDATE", "PASS_DEVICE_VALIDATION"].contains(status),
              speechTokenMinimum == 1,
              speechTokenMaximum == 450,
              promptFrameCount == 302,
              logicalPrefixMaximumForFullSpeechWindow == CosyVoice3FP16StatefulLLMSession.capacity - speechTokenMaximum,
              families.count == 4,
              !defaultPromptTokens.isEmpty,
              !defaultPromptFeat.isEmpty,
              !defaultSpeaker.isEmpty,
              !flowNoiseMaximum.isEmpty,
              !hiftExcitationMaximum.isEmpty else {
            throw CosyVoice3AssetError.invalidJSON("invalid enumerated acoustic contract")
        }
        let expected = [
            CosyVoice3EnumeratedShapeFamily(speechTokenMinimum: 1, speechTokenMaximum: 128, functionName: "n001_128"),
            CosyVoice3EnumeratedShapeFamily(speechTokenMinimum: 129, speechTokenMaximum: 256, functionName: "n129_256"),
            CosyVoice3EnumeratedShapeFamily(speechTokenMinimum: 257, speechTokenMaximum: 384, functionName: "n257_384"),
            CosyVoice3EnumeratedShapeFamily(speechTokenMinimum: 385, speechTokenMaximum: 450, functionName: "n385_450"),
        ]
        guard families == expected, families.allSatisfy({ $0.count <= 128 }) else {
            throw CosyVoice3AssetError.invalidJSON("enumerated acoustic family partition mismatch")
        }
    }

    func functionName(forSpeechTokenCount n: Int) throws -> String {
        guard let family = families.first(where: { $0.contains(n) }) else {
            throw CosyVoice3AssetError.invalidJSON("no enumerated acoustic function for N=\(n)")
        }
        return family.functionName
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
    let enumeratedAcoustic: CosyVoice3EnumeratedAcousticAssets?

    var isDynamicAcoustic: Bool { profile.hasPrefix("ios18-dynamic-") }
    var isEnumeratedAcoustic: Bool { profile == "ios18-enumerated-n1-n450" }
    var isVariableAcoustic: Bool { isDynamicAcoustic || isEnumeratedAcoustic }
    var manifestFileName: String {
        if isEnumeratedAcoustic { return "cosyvoice3_enumerated.json" }
        return isDynamicAcoustic ? "cosyvoice3_dynamic.json" : "cosyvoice3_fixed225.json"
    }

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
                  enumeratedAcoustic == nil,
                  flowMask?.isEmpty == false,
                  flowNoise?.isEmpty == false else {
                throw CosyVoice3AssetError.unsupportedProfile(profile)
            }
        } else if isDynamicAcoustic {
            guard schemaVersion == 2, let dynamicAcoustic, enumeratedAcoustic == nil else {
                throw CosyVoice3AssetError.unsupportedProfile(profile)
            }
            try dynamicAcoustic.validate()
            if referenceEnrollment?.isPromoted == true,
               referenceEnrollment?.flowConditionsDynamic != flowConditions {
                throw CosyVoice3AssetError.invalidJSON(
                    "dynamic promoted reference Conditions path must match active flowConditions"
                )
            }
        } else if isEnumeratedAcoustic {
            guard schemaVersion == 3,
                  dynamicAcoustic == nil,
                  let enumeratedAcoustic,
                  flowMask == nil,
                  flowNoise == nil else {
                throw CosyVoice3AssetError.unsupportedProfile(profile)
            }
            try enumeratedAcoustic.validate()
            if referenceEnrollment?.isPromoted == true,
               referenceEnrollment?.flowConditionsDynamic != flowConditions {
                throw CosyVoice3AssetError.invalidJSON(
                    "enumerated promoted reference Conditions path must match active flowConditions"
                )
            }
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
    }

    private static let cacheState = CacheState()
    private static let compiledCacheVersion = "v1"

    static func loadManifest(root: URL) throws -> CosyVoice3AssetManifest {
        let names = ["cosyvoice3_enumerated.json", "cosyvoice3_dynamic.json", "cosyvoice3_fixed225.json"]
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
        reshapeFrequencyInfrequent: Bool = false,
        preferFastPrediction: Bool = false,
        functionName: String? = nil
    ) throws -> MLModel {
        let source = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: source.path) else { throw CosyVoice3AssetError.missing(source.path) }
        let compiled = try compiledModelURL(source: source)
        let config = MLModelConfiguration()
        let gpuKey: String? = path.hasPrefix("dynamic-acoustic/") ? "COSYVOICE3_VALIDATION_ACOUSTIC_GPU" : nil
        let enumeratedGPU = path.hasPrefix("enumerated-acoustic/") && CommandLine.arguments.contains("--validation-enumerated-cpu-gpu")
        let enumeratedCPU = path.hasPrefix("enumerated-acoustic/") && CommandLine.arguments.contains("--validation-enumerated-cpu-only")
        if enumeratedGPU && enumeratedCPU {
            throw CosyVoice3AssetError.compiledCache("conflicting enumerated validation compute overrides")
        }
        let units: MLComputeUnits
        if enumeratedGPU {
            units = .cpuAndGPU
        } else if enumeratedCPU {
            units = .cpuOnly
        } else {
            units = gpuKey.map { ProcessInfo.processInfo.environment[$0] == "1" } == true ? .cpuAndGPU : computeUnits
        }
        let overrides = try CosyVoice3ValidationPlacement.overrides()
        let role = CosyVoice3ValidationPlacement.role(for: path)
        let effectiveUnits = role.flatMap { overrides[$0] } ?? units
        config.computeUnits = effectiveUnits
        if let role {
            print("[COSY-ROLE-PLACEMENT] role=\(role) path=\(path) requested=\(effectiveUnits) evidence=requested-only")
        }
        config.functionName = functionName
        if units != computeUnits { print("[COSY-PLACEMENT-PROBE] path=\(path) requested=\(computeUnits) effective=\(units) validationOnly=YES") }
        if preferFastPrediction { config.optimizationHints.specializationStrategy = .fastPrediction }
        if reshapeFrequencyInfrequent {
            config.optimizationHints.reshapeFrequency = .infrequent
        }
        do {
            return try MLModel(contentsOf: compiled, configuration: config)
        } catch {
            throw CosyVoice3AssetError.compiledCache(
                "MLModel load failed path=\(path) function=\(functionName ?? "<default>") computeUnits=\(String(describing: effectiveUnits)) reshapeFrequencyInfrequent=\(reshapeFrequencyInfrequent) compiled=\(compiled.lastPathComponent) error=\(String(describing: error))"
            )
        }
    }

    static func llmModel(root: URL, path: String) throws -> MLModel {
        try model(root: root, path: path, computeUnits: CosyVoice3ModelComputePlacement.llm)
    }

    static func dynamicAcousticModel(root: URL, path: String, preferFastPrediction: Bool = false) throws -> MLModel {
        try model(
            root: root,
            path: path,
            computeUnits: CosyVoice3ModelComputePlacement.acoustic,
            reshapeFrequencyInfrequent: true,
            preferFastPrediction: preferFastPrediction
        )
    }

    static func enumeratedAcousticModel(root: URL, path: String, functionName: String) throws -> MLModel {
        try model(
            root: root,
            path: path,
            computeUnits: CosyVoice3ModelComputePlacement.acoustic,
            reshapeFrequencyInfrequent: false,
            preferFastPrediction: false,
            functionName: functionName
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
                    reshapeFrequencyInfrequent: spec.reshapeFrequencyInfrequent,
                    functionName: spec.functionName
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
        let rows = specs.map { spec -> String in
            let units = String(describing: spec.computeUnits)
            let reshape = String(spec.reshapeFrequencyInfrequent)
            let function = spec.functionName ?? "<default>"
            return [spec.path, units, "reshapeInfrequent=" + reshape, "function=" + function].joined(separator: "|")
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

// Purpose: explicit specialization hint for independent validation; default remains accepted behavior.
// Upstream: existing CoreML loader; environment: Swift6 iOS18+/macOS15+; generated 2026-10-05 America/New_York.
// Changed model/dynamicAcousticModel optional hint arguments only; compute units unchanged.

// Purpose: independent explicit GPU validation for acoustic paths; reference stays CPU_ONLY and defaults stay accepted.
// Upstream: existing model loader; environment: Swift6 Apple CoreML; generated 2026-10-05 America/New_York.
// Changed model configuration: one opt-in validation env key; failures propagate without fallback.

// Changes 2026-10-05: add schema-3 ios18-enumerated-N1...450 acoustic contract with four <=128 exact-shape families, multifunction function selection, and function-bound warm-marker identity. The fixed225 and schema-2 RangeDim contracts remain readable controls.

// Changes 2026-10-05: add validation-only command-line compute overrides for schema-3 enumerated acoustic models: --validation-enumerated-cpu-gpu and --validation-enumerated-cpu-only. Production/default placement remains CPU_AND_NE; conflicting overrides fail closed.

// Changes 2026-10-05: align Swift variable-acoustic status gates with the standalone validator: both schema-2 and schema-3 accept CANDIDATE and PASS_DEVICE_VALIDATION, preventing a physically promoted manifest from becoming unreadable by the SDK.

// Changes 2026-10-05: schema-3 production profile identity is exact (ios18-enumerated-n1-n450), matching validate_assets.py; arbitrary ios18-enumerated-* prefixes no longer enter the production loader contract.

// Changes 2026-10-05: align runtime fail-closed validation with validate_assets.py: promoted schema-2/3 reference Conditions must bind to the active flowConditions package, and schema-3 must not carry legacy fixed flowMask/flowNoise paths.

// Changes 2026-10-05 19:12 America/New_York: validation role parser and model configuration (lines 19-61 and model()); 12 independent fail-closed overrides, production defaults/model bytes unchanged. Upstream: existing SDK AssetLoader; environment Swift6/iOS18+/macOS15+.
