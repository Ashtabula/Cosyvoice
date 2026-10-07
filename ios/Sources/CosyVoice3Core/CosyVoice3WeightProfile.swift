// CosyVoice3WeightProfile.swift
// Requirement: immutable Current/Q8/Q4 profile selection, one shared engine, fail-closed pinned assets and accepted two-partition acoustic routing.
import CryptoKit
import Foundation

public struct CosyVoice3WeightProfileMetadata: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let weightCompression: String
    public let modelAssetIdentity: String
    public let manifestIdentity: String
    public let prefillModelIdentity: String
    public let decodeModelIdentity: String
    public let prefillRepresentation: String
    public let decodeRepresentation: String
    public let stateBridgeMode: String
    public let acousticShards: Int
    public let flowSteps: Int
    public let requestedLLMPlacement: String
    public let assetRepository: String
    public let immutableAssetRevision: String
    public let assetCollectionIdentity: String
    public let runtimeAssetTreeIdentity: String
    public let acousticPartitionIdentities: [String]
    public let isExperimental: Bool
    public let isSelectableForInference: Bool
}

public enum CosyVoice3WeightProfileError: Error, Equatable, Sendable {
    case assetsMissing(profileID: String)
    case assetIdentityMismatch(profileID: String)
    case incompatibleRuntimeConfiguration(profileID: String)
    case profileNotValidated(profileID: String)
}

public enum CosyVoice3WeightProfile: String, Sendable, CaseIterable {
    case current, q8
    case q4 = "hybrid_q4"
    public static let hybridQ4: Self = .q4
    public static let productionDefault: Self = .current

    public var metadata: CosyVoice3WeightProfileMetadata {
        let name: String, compression: String
        switch self {
        case .current: name = "Current"; compression = "FP16"
        case .q8: name = "Q8"; compression = "INT8 weight compression, per channel"
        case .q4: name = "Hybrid Q4 — Q8 Prefill + Q4 Decode"; compression = "Q8 prefill + INT4 per-channel decode (hybrid)"
        }
        let prefillRepresentation: String
        let decodeRepresentation: String
        let stateBridgeMode: String
        switch self {
        case .current:
            prefillRepresentation = "FP16"
            decodeRepresentation = "FP16"
            stateBridgeMode = "shared model-owned FP16 MLState; no cross-model state copy"
        case .q8:
            prefillRepresentation = "INT8 per-channel weight compression"
            decodeRepresentation = "INT8 per-channel weight compression"
            stateBridgeMode = "shared model-owned FP16 MLState; no cross-model state copy"
        case .q4:
            prefillRepresentation = "Q8 prefill"
            decodeRepresentation = "INT4 per-channel decode"
            stateBridgeMode = "Q8-prefill→Q4-decode request-level FP16 state-copy bridge"
        }
        // Public identities are content hashes only; model filenames stay private.
        let pair = contract.prefillSHA + "\n" + contract.decodeSHA
        return .init(
            id: rawValue,
            displayName: name,
            weightCompression: compression,
            modelAssetIdentity: SHA256.hash(data: Data(pair.utf8)).map { String(format: "%02x", $0) }.joined(),
            manifestIdentity: contract.manifestSHA,
            prefillModelIdentity: contract.prefillSHA,
            decodeModelIdentity: contract.decodeSHA,
            prefillRepresentation: prefillRepresentation,
            decodeRepresentation: decodeRepresentation,
            stateBridgeMode: stateBridgeMode,
            acousticShards: 2,
            flowSteps: 6,
            requestedLLMPlacement: "CPU_AND_NE",
            assetRepository: "actacomes/CosyVoice-assets",
            immutableAssetRevision: "c16f38383fa261bfed317fbec2fad2c4115d690c",
            assetCollectionIdentity: "47958326989cca9ad26fe3001b03d858c205cdfa19bd5f60d19b40e16f6e54a1",
            runtimeAssetTreeIdentity: contract.payloadSHA,
            acousticPartitionIdentities: Self.validatedFlowPackages.map { $0.1 },
            isExperimental: self != .current,
            isSelectableForInference: true
        )
    }

    // Accept either an installed profile root or a logical profile collection containing
    // current/q8/q4. Never search/fall back to a different profile after finding a manifest.
    func resolveAssets(in directory: URL) throws -> URL {
        let names = ["cosyvoice3_enumerated.json", "cosyvoice3_dynamic.json", "cosyvoice3_fixed225.json"]
        func hasManifest(_ root: URL) -> Bool {
            names.contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        }
        if hasManifest(directory) { return directory }
        let child = directory.appendingPathComponent(rawValue, isDirectory: true)
        guard hasManifest(child) else { throw CosyVoice3WeightProfileError.assetsMissing(profileID: rawValue) }
        return child
    }

    func validateManifest(root: URL, manifest: CosyVoice3AssetManifest, requireValidatedRuntime: Bool) throws {
        let data = try Data(contentsOf: root.appendingPathComponent(manifest.manifestFileName))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let marker = object?["experimentalLLMVariant"] as? String
        guard marker == contract.marker else { throw CosyVoice3WeightProfileError.assetIdentityMismatch(profileID: rawValue) }
        // Preserve legacy unquantized default initializer behavior. Explicit profiles
        // select the validated schema3 family and never silently choose a legacy graph.
        if !requireValidatedRuntime && self == .current && !manifest.isEnumeratedAcoustic { return }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard manifest.isEnumeratedAcoustic, hash == contract.manifestSHA,
              manifest.llmPrefill == contract.prefillPath, manifest.llmDecode == contract.decodePath else {
            throw CosyVoice3WeightProfileError.assetIdentityMismatch(profileID: rawValue)
        }
        if requireValidatedRuntime {
            let partitions = CommandLine.arguments.filter { $0.hasPrefix("--validation-flow-partition=") }
            guard partitions.count <= 1, partitions.allSatisfy({ $0 == "--validation-flow-partition=2" }) else {
                throw CosyVoice3WeightProfileError.incompatibleRuntimeConfiguration(profileID: rawValue)
            }
        }
    }

    func validateContent(manifestSHA: String, payloadSHA: String, prefillSHA: String, decodeSHA: String) throws {
        guard manifestSHA == contract.manifestSHA, payloadSHA == contract.payloadSHA,
              prefillSHA == contract.prefillSHA, decodeSHA == contract.decodeSHA else {
            throw CosyVoice3WeightProfileError.assetIdentityMismatch(profileID: rawValue)
        }
    }

    func validateAssets(root: URL, store: CosyVoice3PersistentRuntimeStore = .shared) throws {
        let identity = try store.rootIdentity(root)
        try validateContent(manifestSHA: identity.manifest, payloadSHA: identity.payload,
                            prefillSHA: store.packageSHA(root.appendingPathComponent(contract.prefillPath)),
                            decodeSHA: store.packageSHA(root.appendingPathComponent(contract.decodePath)))
        // The already accepted lossless P2 packages are unchanged shared siblings.
        // Package hashes guard a stale/mixed acoustic partition even outside Runtime.
        for (path, expected) in Self.validatedFlowPackages {
            guard try store.packageSHA(root.appendingPathComponent(path)) == expected else {
                throw CosyVoice3WeightProfileError.assetIdentityMismatch(profileID: rawValue)
            }
        }
    }

    static let validatedFlowPackages = [
        ("../FlowPartitions/p2/group-0.mlpackage", "70dd09f89694af1774832cd451cdbce8585f16128e9762fc5bb82d653fa54287"),
        ("../FlowPartitions/p2/group-1.mlpackage", "24c3039d6d59a7b88e5cc9d4334e99ef8b7a0cd7ba13ec493e70781dcf24b408")
    ]
    static var validatedFlowPaths: [String] { validatedFlowPackages.map { $0.0 } }

    struct Contract: Sendable {
        let marker: String?
        let manifestSHA: String
        let payloadSHA: String
        let prefillSHA: String
        let decodeSHA: String
        let prefillPath: String
        let decodePath: String
    }
    var contract: Contract {
        switch self {
        case .current:
            return .init(marker: nil,
                         manifestSHA: "2ddc7fa084fb0e458b34f61af7fcc927773fb3697496a17f8ae1593ba33b56ee",
                         payloadSHA: "dbea074bfc8dc49514c32d99f38f378d6ed030cd60b25d82f807b2dd69b40677",
                         prefillSHA: "62f5a760f1a23dcf8540627fa2e7f52c9d0dd912e0094b90fec642b6b5801ece",
                         decodeSHA: "c466ebefec84a4e05da001675bd4e4901c23459964064c9819dca6ccb5eb1c37",
                         prefillPath: "models/llm-opt-perlayer-prefill.mlpackage",
                         decodePath: "models/llm-opt-perlayer-decode-maskwrite512.mlpackage")
        case .q8:
            return .init(marker: "Q8_WEIGHT_ONLY_UNPROMOTED",
                         manifestSHA: "a276c672e178b4e87d44be96dcb24453bb45b76366270299b5977eca732dc2b5",
                         payloadSHA: "14fbec1f7765e1f5569200a67cb5d14b4f9758c9b56bc1c9e5363e10c5019c05",
                         prefillSHA: "3cea2eae34b390a14e3bb79f5f4c97353ea22ec8a723ab01e9767156bd528a18",
                         decodeSHA: "46c52f10b28f947509e6c35bad05c4c942076b39d8b62d791cb4c0d8e093076d",
                         prefillPath: "models/cosyvoice-llm-q8-prefill.mlpackage",
                         decodePath: "models/cosyvoice-llm-q8-decode.mlpackage")
        case .q4:
            return .init(marker: "Q4_DECODE_HYBRID_A_Q8_PREFILL_INT4_PER_CHANNEL_DECODE",
                         manifestSHA: "4f8e3aec18152c07a0e31814c2fa9ac92c3555fc4345f22f378cc07c6aa495d8",
                         payloadSHA: "0cd48a4704f12485cfa8f863ae9996ed5f8908e19dbbdd3540fe91e711a81fbe",
                         prefillSHA: "3cea2eae34b390a14e3bb79f5f4c97353ea22ec8a723ab01e9767156bd528a18",
                         decodeSHA: "d3e7135201e0e8c7a3f5a6282ba8d42abab95504c8c819a3441aa20c113963e1",
                         prefillPath: "models/cosyvoice-llm-q8-prefill.mlpackage",
                         decodePath: "models/cosyvoice-llm-q4-rescue-a-decode.mlpackage")
        }
    }
}
// Purpose: one immutable profile contract; asset hashes verified by existing locked byte-identity store, no global mutable selection.
// Upstream accepted FP16/Q8 and isolated Q4 export receipts; Swift6/iOS18+/macOS15+; generated2026-10-06 America/New_York.
// New API/contract file; no tensor math, weights, sampling, precision, placement or state changes.
// Q4 physicalgate2026-10-06: INT4block32 prefill failed CPU_AND_NE plan -14 before prediction on iPhone18,4/iOS27.2.
// Historical block32 candidate remains failed; human-approved hybrid supersedes its public contract without fallback.

// Human acceptance2026-10-06: all3hybridEnglishWAVs userPASS; q4 now selects exact Q8prefill+INT4perchanneldecode hybrid. Originalblock32 failure/assets preserved; Currentdefault unchanged; notrelease/HFpromotion. Changedmetadata/contractonly.

// Benchmark identity 2026-10-06: expose only stable public content hashes/representations/SHARDS2/Flow6/state-bridge metadata. Core ML filenames and conversion internals remain private.

// Rebuild validation harness2026-10-06: candidate-only source binding to actual rebuilt Current/P2 bytes.
// Purpose: signed public synthesis revalidation; prior shipping source and old receipts remain unchanged.
// Upstream: frozen053e0ef SDK/harness; environment Swift6 physical iOS27.2.
// Changed regions: exact content hash constants only; no algorithm, state, sampling, placement or tolerance changes.

// Rebuild candidate-only binding2026-10-06: exact new Q8/Hybrid hashes; no old human/physical inheritance or shipping promotion.
// Purpose: isolated public synthesis revalidation; upstream frozen053e0ef, Swift6/iOS27.2.
// Changed hash constants only; Current default, source math, sampling, state bridge and placement remain unchanged.

// Rebuild2026-10-06: new revalidated Current/Q8/Hybrid model/P2 identities and immutable HF revision. q4 enum source spelling remains compatible; canonical raw ID/directory is hybrid_q4. Added public high-level asset identities, no private mapping exposure.
