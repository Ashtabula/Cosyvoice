// PersistentRuntimeStoreTests.swift
// Requirement: restart byte verification, independent family identity, pending != ready, no process-validation inference from disk markers.
import CoreML
import Foundation
import XCTest
@testable import CosyVoice3Core

final class PersistentRuntimeStoreTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CosyPersistentTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testRestartHashesActualBytesEvenWithPreservedTimestampAndSize() throws {
        let root = try temporary()
        let package = root.appendingPathComponent("test.mlpackage")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("weight.bin")
        try Data([1,2,3,4]).write(to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let first = try CosyVoice3PersistentRuntimeStore(storageRootOverride: root).packageSHA(package)
        try Data([4,3,2,1]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: file.path)
        let restarted = try CosyVoice3PersistentRuntimeStore(storageRootOverride: root).packageSHA(package)
        XCTAssertNotEqual(first, restarted)
    }

    func testFamilyPendingPersistenceAndIndependentIdentity() throws {
        let root = try temporary()
        let store = CosyVoice3PersistentRuntimeStore(storageRootOverride: root)
        let model = ["functionName":"n257_384","modelPackageSHA256":"test-content","requestedPlacement":"1","manifestSHA256":"manifest","payloadTreeSHA256":"payload","runtimeVersion":"version","modelABI":"2"]
        let compiled = try store.directory("CompiledModels").appendingPathComponent("test.mlmodelc")
        try FileManager.default.createDirectory(at:compiled,withIntermediateDirectories:true)
        // Simulated metadata load receipt, never a Core ML execution claim.
        try store.validatedLoad(identity:model,compiled:compiled,milliseconds:1,compiledHit:false)
        try store.family(root:root,function:"n257_384",identities:[model],state:"PENDING_IDLE",n:nil)
        XCTAssertFalse(try store.familyReady(function:"n257_384",identities:[model]))
        try store.family(root:root,function:"n257_384",identities:[model],state:"SUCCESSFUL_PUBLIC_SYNTHESIS",n:260)
        let restarted = CosyVoice3PersistentRuntimeStore(storageRootOverride: root)
        XCTAssertTrue(try restarted.familyReady(function:"n257_384",identities:[model]))
        XCTAssertFalse(try restarted.isValidatedInProcess(model))
        var other = model; other["functionName"] = "n001_128"
        XCTAssertFalse(try restarted.familyReady(function:"n001_128",identities:[other]))
        for field in ["modelPackageSHA256","requestedPlacement","manifestSHA256","payloadTreeSHA256","runtimeVersion","modelABI"] {
            var changed = model; changed[field] = "changed"
            XCTAssertFalse(try restarted.familyReady(function:"n257_384",identities:[changed]), field)
        }
        XCTAssertEqual(try restarted.snapshot()["excludedFromBackup"] as? Bool, true)
        try FileManager.default.removeItem(at:compiled)
        XCTAssertFalse(try restarted.familyReady(function:"n257_384",identities:[model]), "marker cannot outlive app artifact presence")
    }

    func testCanonicalAndAliasPathsHaveTheSameContentIdentity() throws {
        let root = try temporary()
        let source = root.appendingPathComponent("actual.mlpackage")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data([7,8,9]).write(to: source.appendingPathComponent("weight.bin"))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let store = CosyVoice3PersistentRuntimeStore(storageRootOverride: root)
        XCTAssertEqual(try store.packageSHA(source), try store.packageSHA(alias))
    }
}
// Purpose: storage/invalidation semantics only, not physical Core ML execution proof.
// Upstream persistent runtime store; Swift6/XCTest/macOS/iOS. Generated2026-10-05 America/New_York; new file.
