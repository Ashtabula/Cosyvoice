// CosyVoice3WeightProfile.swift
// Requirement: immutable Current/Q8/Q4 profile selection, one shared engine, fail-closed pinned assets and accepted two-partition acoustic routing.
import CryptoKit
import Foundation

public struct CosyVoice3WeightProfileMetadata: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let weightCompression: String
    public let modelAssetIdentity: String
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
    case current, q8, q4
    public static let productionDefault: Self = .current

    public var metadata: CosyVoice3WeightProfileMetadata {
        let name: String, compression: String
        switch self {
        case .current: name = "Current"; compression = "FP16"
        case .q8: name = "Q8"; compression = "INT8 weight compression, per channel"
        case .q4: name = "Q4"; compression = "INT4 weight compression, block32"
        }
        // Identity is a stable digest of the two immutable model packages, not filenames.
        let pair = contract.prefillSHA + "\n" + contract.decodeSHA
        return .init(id: rawValue, displayName: name, weightCompression: compression,
                     modelAssetIdentity: SHA256.hash(data: Data(pair.utf8)).map { String(format: "%02x", $0) }.joined(),
                     isExperimental: self != .current, isSelectableForInference: self != .q4)
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
        ("../FlowPartitions/p2/group-0.mlpackage", "1b6f04d1b8da6437f2a0da24dba3355050f489ae83a1102e9e40da3ec8334b7a"),
        ("../FlowPartitions/p2/group-1.mlpackage", "f7c4064e32c19410818034c206b204f8a84c2b6c2a22f664b7d710a3805a017c")
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
                         payloadSHA: "4750dba5e727276d22b71399b702a33597aaaf36d61edf8cc3dd8bd3897e6efa",
                         prefillSHA: "3fe257e2d8659abc7cc6de6c7b17d72510d55ef691f4323410e6bc9a44351c59",
                         decodeSHA: "c5207c467c19808f14174b239c2a81099970b5c2ba01277720ef985416710d0d",
                         prefillPath: "models/llm-opt-perlayer-prefill.mlpackage",
                         decodePath: "models/llm-opt-perlayer-decode-maskwrite512.mlpackage")
        case .q8:
            return .init(marker: "Q8_WEIGHT_ONLY_UNPROMOTED",
                         manifestSHA: "a276c672e178b4e87d44be96dcb24453bb45b76366270299b5977eca732dc2b5",
                         payloadSHA: "150c0d45d6133818c782f0dfb4dcb2508f097fc42bc81e12e916aca051954f98",
                         prefillSHA: "f0b183e1b22a4ffccfc2c95926a0bee921d740543b4b89e40b0894a407b4a280",
                         decodeSHA: "ce2beac8170a210f3c4d24e4a15b487f5135df69f6a32fdac516183b4ed7c7f5",
                         prefillPath: "models/cosyvoice-llm-q8-prefill.mlpackage",
                         decodePath: "models/cosyvoice-llm-q8-decode.mlpackage")
        case .q4:
            return .init(marker: "Q4_WEIGHT_ONLY_UNPROMOTED",
                         manifestSHA: "092d9fbe3c8ad8fe556dd788a0824128200aec1f2fafba410ecb65b10a1ae31a",
                         payloadSHA: "bca74138e3d7112f2e9e6bd0b0370401cc79be4ee27c7c2c09cc0ddf644f86d1",
                         prefillSHA: "a434a6d7ff3102ed5ba708a45f62677762acefceed53f6f8e9eb79dc5a509ce7",
                         decodeSHA: "bbdcec87ea37686a46e6c2fc16b30868fa42414098f7844e28bf20d7d812f0b7",
                         prefillPath: "models/cosyvoice-llm-q4-prefill.mlpackage",
                         decodePath: "models/cosyvoice-llm-q4-decode.mlpackage")
        }
    }
}
// Purpose: one immutable profile contract; asset hashes verified by existing locked byte-identity store, no global mutable selection.
// Upstream accepted FP16/Q8 and isolated Q4 export receipts; Swift6/iOS18+/macOS15+; generated2026-10-06 America/New_York.
// New API/contract file; no tensor math, weights, sampling, precision, placement or state changes.
// Q4 physicalgate2026-10-06: INT4block32 prefill failed CPU_AND_NE plan -14 before prediction on iPhone18,4/iOS27.2.
// Q4 remains discoverable metadata but is not selectable for inference until a separate candidate passes physical validation; no automatic fallback.
