// CosyVoice3PersistentRuntimeStore.swift
// Requirement: content-bound, backup-excluded persistent artifacts and independently identified family readiness.
import CoreML
import CryptoKit
import Foundation

final class CosyVoice3PersistentRuntimeStore: @unchecked Sendable {
    static let shared = CosyVoice3PersistentRuntimeStore()
    private let lock = NSRecursiveLock()
    private var roots: [String: (manifest: String, payload: String, schema: String)] = [:]
    private var packages: [String: String] = [:]
    private var validatedInProcess = Set<String>()
    private var events: [[String: String]] = []
    private var activeRequests = 0
    private let storageRootOverride: URL?

    init(storageRootOverride: URL? = nil) { self.storageRootOverride = storageRootOverride }
    func beginSynthesis() { lock.lock(); defer { lock.unlock() }; activeRequests += 1 }
    func endSynthesis() { lock.lock(); defer { lock.unlock() }; activeRequests -= 1 }
    var hasActiveSynthesis: Bool { lock.lock(); defer { lock.unlock() }; return activeRequests > 0 }

    static var runtimeVersion: String {
        let bundle = Bundle(for: MLModel.self)
        return ProcessInfo.processInfo.operatingSystemVersionString + "|CoreML=" +
            (bundle.infoDictionary?["CFBundleVersion"] as? String ?? "OS-build-bound") + "|SDKRuntimeABI=2"
    }

    func directory(_ component: String = "") throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var root = storageRootOverride ?? support.appendingPathComponent("CosyVoice3Core/RuntimeDerived-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        root = component.isEmpty ? root : root.appendingPathComponent(component, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Source roots are immutable for the lifetime of one Engine/process. Every new
    // process hashes actual bytes again; no persistent timestamp-only trust shortcut.
    func packageSHA(_ source: URL) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let value = packages[source.standardizedFileURL.path] { return value }
        let result = try contentTree(source, excludingExportReceipt: false)
        packages[source.standardizedFileURL.path] = result
        return result
    }

    private func contentTree(_ root: URL, excludingExportReceipt: Bool) throws -> String {
        let canonicalRoot = root.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: canonicalRoot, includingPropertiesForKeys: keys) else {
            throw CosyVoice3AssetError.compiledCache("cannot enumerate content identity: \(root.path)")
        }
        var rows = [(String, Int, String)]()
        for case let file as URL in enumerator {
            let canonicalFile = file.resolvingSymlinksInPath()
            guard canonicalFile.path.hasPrefix(canonicalRoot.path + "/") else { throw CosyVoice3AssetError.compiledCache("asset file escaped canonical identity root") }
            let relative = String(canonicalFile.path.dropFirst(canonicalRoot.path.count + 1))
            if excludingExportReceipt && (file.lastPathComponent == "enumerated-production-export-receipt.json" || relative.split(separator: "/").contains(".family-build")) { continue }
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            // Foundation FileHandle bridges autoreleased NSData. Drain each chunk,
            // rather than retaining several GiB until the enclosing actor turn ends.
            while try autoreleasepool(invoking: {
                guard let bytes = try handle.read(upToCount: 4 * 1024 * 1024), !bytes.isEmpty else { return false }
                hash.update(data: bytes)
                return true
            }) { }
            rows.append((relative, values.fileSize ?? 0, hash.finalize().map { String(format: "%02x", $0) }.joined()))
        }
        func tree(_ items: [(String, Int, String)]) -> String {
            sha(Data(items.sorted { $0.0 < $1.0 }.map { "\($0.0)\0\($0.1)\0\($0.2)\n" }.joined().utf8))
        }
        if excludingExportReceipt {
            var groups = [String: [(String, Int, String)]]()
            for row in rows {
                if let range = row.0.range(of: ".mlpackage/") {
                    let prefix = String(row.0[..<range.upperBound].dropLast())
                    groups[prefix, default: []].append((String(row.0[range.upperBound...]),row.1,row.2))
                }
            }
            for (prefix, items) in groups { packages[root.appendingPathComponent(prefix).standardizedFileURL.path] = tree(items) }
        }
        return tree(rows)
    }

    func rootIdentity(_ root: URL) throws -> (manifest: String, payload: String, schema: String) {
        lock.lock(); defer { lock.unlock() }
        let key = root.standardizedFileURL.path
        if let hit = roots[key] { return hit }
        let manifest = try CosyVoice3AssetLoader.loadManifest(root: root)
        print("[COSY-PERSISTENT-IDENTITY] begin actual-byte payload verification root=\(root.path)")
        let manifestSHA = sha(try Data(contentsOf: root.appendingPathComponent(manifest.manifestFileName)))
        let payload = try contentTree(root, excludingExportReceipt: true)
        print("[COSY-PERSISTENT-IDENTITY] completed payloadSHA256=\(payload)")
        let receipt = root.appendingPathComponent("enumerated-production-export-receipt.json")
        if manifest.isEnumeratedAcoustic, FileManager.default.fileExists(atPath: receipt.path) {
            let advertised = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any]
            guard advertised?["payloadTreeSha256"] as? String == payload else {
                throw CosyVoice3AssetError.compiledCache("frozen payload actual-byte SHA mismatch; preparation invalidated")
            }
        }
        let result = (manifestSHA, payload, String(manifest.schemaVersion))
        roots[key] = result
        return result
    }

    func identity(root: URL, source: URL, function: String?, units: MLComputeUnits, reshape: Bool, fastPrediction: Bool = false) throws -> [String: String] {
        let rootIdentity = try rootIdentity(root)
        var result = ["manifestSHA256":rootIdentity.manifest, "payloadTreeSHA256":rootIdentity.payload,
            "schema":rootIdentity.schema, "modelPackageSHA256":try packageSHA(source),
            "functionName":function ?? "<default:main>", "requestedPlacement":String(units.rawValue),
            "reshapeInfrequent":String(reshape), "runtimeVersion":Self.runtimeVersion, "modelABI":"CoreML-MLProgram-source-content-v2"]
        if fastPrediction { result["specializationStrategy"] = "fastPrediction" }
        return result
    }

    func key(_ identity: [String: String]) throws -> String {
        sha(try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]))
    }

    func artifactKey(source: URL) throws -> String {
        sha(Data((try packageSHA(source) + "|" + Self.runtimeVersion + "|compiledABI=2").utf8))
    }

    func validatedLoad(identity: [String: String], compiled: URL, milliseconds: Double, compiledHit: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let key = try key(identity)
        let destination = try directory("ModelPlans").appendingPathComponent(key + ".json")
        var record = (try? JSONSerialization.jsonObject(with: Data(contentsOf: destination))) as? [String: Any] ?? [:]
        let existed = record["identity"] as? [String: String] == identity
        record["identity"] = identity; record["key"] = key
        record["firstAuthoritativeLoadMilliseconds"] = record["firstAuthoritativeLoadMilliseconds"] ?? milliseconds
        record["lastAuthoritativeLoadMilliseconds"] = milliseconds
        record["lastValidatedAt"] = Date().timeIntervalSince1970
        record["compiledArtifact"] = compiled.lastPathComponent
        record["status"] = "AUTHORITATIVE_MODEL_LOAD_VALIDATED"
        record["systemExecutionState"] = "CoreML-managed; marker is not proof of system-plan persistence"
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: destination, options: .atomic)
        if validatedInProcess.insert(key).inserted {
            events.append(["key":key,"functionName":identity["functionName"] ?? "", "packageSHA256":identity["modelPackageSHA256"] ?? "",
                "persistentModelRecordHit":String(existed),"compiledArtifactHit":String(compiledHit),"authoritativeLoadMilliseconds":String(milliseconds)])
        }
    }

    func invalidate(_ identity: [String: String], reason: String) throws {
        lock.lock(); defer { lock.unlock() }
        let key = try key(identity)
        let file = try directory("ModelPlans").appendingPathComponent(key + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        events.append(["key":key,"invalidationReason":reason]); validatedInProcess.remove(key)
    }

    func isValidatedInProcess(_ identity: [String: String]) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return validatedInProcess.contains(try key(identity))
    }

    func family(root: URL, function: String, identities: [[String: String]], state: String, n: Int?) throws {
        lock.lock(); defer { lock.unlock() }
        let keys = try identities.map { try key($0) }.sorted()
        let identity = ["functionName":function,"models":keys.joined(separator: ","),"runtimeVersion":Self.runtimeVersion]
        let key = try key(identity)
        let file = try directory("Buckets").appendingPathComponent(key + ".json")
        var record = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
        record["identity"] = identity; record["modelIdentities"] = identities; record["status"] = state
        if state == "PENDING_IDLE" { record["firstQueuedAt"] = record["firstQueuedAt"] ?? Date().timeIntervalSince1970 }
        else { record["firstCompletedAt"] = record["firstCompletedAt"] ?? Date().timeIntervalSince1970 }
        record["lastUpdatedAt"] = Date().timeIntervalSince1970
        if let n { record["lastSuccessfulSpeechTokenCount"] = n }
        record["scope"] = "function load readiness; observed N predictions recorded separately; system exact-shape specialization is not guaranteed by this marker"
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: file, options: .atomic)
    }

    func familyReady(function: String, identities: [[String: String]]) throws -> Bool {
        let keys = try identities.map { try key($0) }.sorted()
        let identity = ["functionName":function,"models":keys.joined(separator: ","),"runtimeVersion":Self.runtimeVersion]
        let file = try directory("Buckets").appendingPathComponent(try key(identity) + ".json")
        guard let data = try? Data(contentsOf: file), let record = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return record["identity"] as? [String: String] == identity &&
            ["LOAD_READY_SYSTEM_STATE_NOT_ASSUMED", "SUCCESSFUL_PUBLIC_SYNTHESIS"].contains(record["status"] as? String ?? "")
    }

    func snapshot() throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let root = try directory()
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey,.isRegularFileKey])!
        var bytes = 0; var records = [[String: Any]]()
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey])
            if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
            if file.pathExtension == "json", let data = try? Data(contentsOf: file), let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { records.append(record) }
        }
        return ["directory":root.path,"excludedFromBackup":try root.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup ?? false,
            "storageBytes":bytes,"records":records,"processID":ProcessInfo.processInfo.processIdentifier,"processLoadEvents":events,
            "systemExecutionPlanPersistence":"not assumed; every process performs authoritative MLModel load when the model is used"]
    }
}
// Purpose: stable app-owned identities/artifacts, independent function records, actual-byte verification.
// Upstream: AssetLoader compiled/warm caches. Swift6/CoreML/iOS18+/macOS15+.
// Generated 2026-10-05 America/New_York; new file. No graph, weights, inference or sampling changes.
