// WeightProfileTests.swift
// Requirement: preserve Current default, explicit immutable profile selection, fail closed on wrong/mixed/stale assets and prevent cache identity collisions.
import Foundation
import XCTest
@testable import CosyVoice3Core

final class WeightProfileTests: XCTestCase {
    private func fixture(_ profile: CosyVoice3WeightProfile) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CosyWeightProfile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = Bundle.module.url(forResource: profile.rawValue, withExtension: "json", subdirectory: "Fixtures")!
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("cosyvoice3_enumerated.json"))
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testExistingInitializerRemainsCurrent() throws {
        let engine = try CosyVoice3Engine(assetRoot: fixture(.current), idleBucketPreparation: false)
        XCTAssertEqual(engine.weightProfile, .current)
        XCTAssertEqual(CosyVoice3WeightProfile.productionDefault, .current)
        XCTAssertFalse(engine.profileMetadata.isExperimental)
    }

    func testExplicitProfilesUseSameEngineAndStableMetadata() throws {
        for profile in CosyVoice3WeightProfile.allCases where profile.metadata.isSelectableForInference {
            let engine = try CosyVoice3Engine(assetRoot: fixture(profile), profile: profile, idleBucketPreparation: false)
            XCTAssertEqual(engine.weightProfile, profile)
            XCTAssertEqual(engine.profileMetadata.id, profile.rawValue)
            XCTAssertEqual(engine.profileMetadata.modelAssetIdentity.count, 64)
            XCTAssertEqual(engine.profileMetadata.isExperimental, profile != .current)
        }
        XCTAssertEqual(CosyVoice3WeightProfile.allCases.map(\.rawValue), ["current", "q8", "q4"])
        XCTAssertEqual(CosyVoice3WeightProfile.current.metadata.displayName, "Current")
        XCTAssertEqual(CosyVoice3WeightProfile.q8.metadata.displayName, "Q8")
        XCTAssertEqual(CosyVoice3WeightProfile.q4.metadata.displayName, "Q4 Decode Hybrid")
    }

    func testAllWrongProfileCombinationsFailDuringInitialization() throws {
        for supplied in CosyVoice3WeightProfile.allCases {
            let root = try fixture(supplied)
            for requested in CosyVoice3WeightProfile.allCases where requested != supplied {
                XCTAssertThrowsError(try CosyVoice3Engine(assetRoot: root, profile: requested))
            }
            if supplied != .current { XCTAssertThrowsError(try CosyVoice3Engine(assetRoot: root)) }
        }
    }

    func testCollectionResolutionHasNoSilentFallback() throws {
        let child = try fixture(.q4), collection = child.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
        let installed = collection.appendingPathComponent("q4", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: child.appendingPathComponent("cosyvoice3_enumerated.json"), to: installed.appendingPathComponent("cosyvoice3_enumerated.json"))
        XCTAssertEqual(try CosyVoice3WeightProfile.q4.resolveAssets(in: collection), installed)
        XCTAssertThrowsError(try CosyVoice3WeightProfile.q8.resolveAssets(in: collection))
        XCTAssertThrowsError(try CosyVoice3Engine(assetRoot: child, profile: .q8))
    }

    func testMixedPackagePayloadAndStaleManifestRejected() throws {
        for profile in CosyVoice3WeightProfile.allCases {
            let c = profile.contract
            XCTAssertNoThrow(try profile.validateContent(manifestSHA: c.manifestSHA, payloadSHA: c.payloadSHA, prefillSHA: c.prefillSHA, decodeSHA: c.decodeSHA))
            XCTAssertThrowsError(try profile.validateContent(manifestSHA: "stale", payloadSHA: c.payloadSHA, prefillSHA: c.prefillSHA, decodeSHA: c.decodeSHA))
            XCTAssertThrowsError(try profile.validateContent(manifestSHA: c.manifestSHA, payloadSHA: "mixed", prefillSHA: c.prefillSHA, decodeSHA: c.decodeSHA))
            XCTAssertThrowsError(try profile.validateContent(manifestSHA: c.manifestSHA, payloadSHA: c.payloadSHA, prefillSHA: "other profile", decodeSHA: c.decodeSHA))
            XCTAssertThrowsError(try profile.validateContent(manifestSHA: c.manifestSHA, payloadSHA: c.payloadSHA, prefillSHA: c.prefillSHA, decodeSHA: "other profile"))
        }
    }

    func testMetadataOnlyRootCannotReachPrediction() async throws {
        for profile in CosyVoice3WeightProfile.allCases where profile.metadata.isSelectableForInference {
            let engine = try CosyVoice3Engine(assetRoot: fixture(profile), profile: profile, idleBucketPreparation: false)
            do { _ = try await engine.prepare(); XCTFail("incomplete assets must fail before model prediction") }
            catch { XCTAssertNotNil(error) }
        }
    }

    func testPersistentPlanAndShelfKeysDisjointAcrossProfiles() throws {
        let store = CosyVoice3PersistentRuntimeStore()
        let identities = CosyVoice3WeightProfile.allCases.map { p in
            ["manifestSHA256": p.contract.manifestSHA, "payloadTreeSHA256": p.contract.payloadSHA,
             "modelPackageSHA256": p.contract.decodeSHA, "functionName": "main", "requestedPlacement": "3",
             "runtimeVersion": "same", "modelABI": "same"]
        }
        XCTAssertEqual(Set(try identities.map { try store.key($0) }).count, 3)
        XCTAssertEqual(Set(CosyVoice3WeightProfile.allCases.map { $0.metadata.modelAssetIdentity }).count, 3)
        // Equal acoustic bytes may share compiled archives, but readiness/shelf keys include
        // different manifest+payload identity, so another profile's model handle is not reused.
        let acoustic = identities.map { $0.merging(["modelPackageSHA256": "identical acoustic"], uniquingKeysWith: { _, b in b }) }
        XCTAssertEqual(Set(try acoustic.map { try store.key($0) }).count, 3)
    }

    func testProfileRoutingNeedsNoShardCLIAndKeepsLegacyDefault() throws {
        let source = (0..<6).map { "manifest-stage-\($0)" }
        XCTAssertEqual(try CosyVoice3DynamicAcousticRuntime.selectedFlowPaths(manifestPaths: source, validatedProfilePaths: nil, isEnumerated: true, arguments: []), source)
        XCTAssertEqual(try CosyVoice3DynamicAcousticRuntime.selectedFlowPaths(manifestPaths: source, validatedProfilePaths: CosyVoice3WeightProfile.validatedFlowPaths, isEnumerated: true, arguments: []), CosyVoice3WeightProfile.validatedFlowPaths)
        XCTAssertEqual(try CosyVoice3DynamicAcousticRuntime.selectedFlowPaths(manifestPaths: source, validatedProfilePaths: nil, isEnumerated: true, arguments: ["--validation-flow-partition=2"]), CosyVoice3WeightProfile.validatedFlowPaths)
    }

    func testInvalidProfileRoutingNeverSilentlyFallsBack() {
        let source = (0..<6).map { "manifest-stage-\($0)" }
        XCTAssertThrowsError(try CosyVoice3DynamicAcousticRuntime.selectedFlowPaths(manifestPaths: source, validatedProfilePaths: ["wrong"], isEnumerated: true, arguments: []))
        XCTAssertThrowsError(try CosyVoice3DynamicAcousticRuntime.selectedFlowPaths(manifestPaths: source, validatedProfilePaths: CosyVoice3WeightProfile.validatedFlowPaths, isEnumerated: false, arguments: []))
        XCTAssertThrowsError(try CosyVoice3DynamicAcousticRuntime.selectedFlowPaths(manifestPaths: source, validatedProfilePaths: CosyVoice3WeightProfile.validatedFlowPaths, isEnumerated: true, arguments: ["--validation-flow-partition=3"]))
    }

    func testAcceptedQ4HybridRejectsOriginalFailedBlock32Assets() throws {
        XCTAssertTrue(CosyVoice3WeightProfile.q4.metadata.isSelectableForInference)
        XCTAssertEqual(CosyVoice3WeightProfile.productionDefault, .current)
        XCTAssertEqual(CosyVoice3WeightProfile.q4.contract.prefillSHA, CosyVoice3WeightProfile.q8.contract.prefillSHA)
        let root = try fixture(.q4)
        var old = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("cosyvoice3_enumerated.json"))) as! [String: Any]
        old["experimentalLLMVariant"] = "Q4_WEIGHT_ONLY_UNPROMOTED"
        old["llmPrefill"] = "models/cosyvoice-llm-q4-prefill.mlpackage"
        old["llmDecode"] = "models/cosyvoice-llm-q4-decode.mlpackage"
        try JSONSerialization.data(withJSONObject: old).write(to: root.appendingPathComponent("cosyvoice3_enumerated.json"))
        XCTAssertThrowsError(try CosyVoice3Engine(assetRoot: root, profile: .q4)) { error in
            XCTAssertEqual(error as? CosyVoice3WeightProfileError, .assetIdentityMismatch(profileID: "q4"))
        }
    }
}
// Purpose: profile/asset/cache contracts, not neural execution or human quality proof.
// Upstream actual immutable manifest fixtures and shared Engine/PersistentRuntimeStore; Swift6/XCTest/macOS15+, generated2026-10-06 America/New_York.
