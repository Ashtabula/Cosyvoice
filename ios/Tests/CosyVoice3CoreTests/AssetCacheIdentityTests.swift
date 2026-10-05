// AssetCacheIdentityTests.swift
// Requirement: immutable release cache identity must bind the release manifest, not only file size/mtime metadata.
import Foundation
import XCTest
@testable import CosyVoice3Core

@available(iOS 18.0, macOS 15.0, *)
final class AssetCacheIdentityTests: XCTestCase {
    func testReleaseManifestChangesCacheIdentity() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("CosyVoice3AssetIdentity-"+UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data("same-payload".utf8).write(to:root.appendingPathComponent("reference.bin"))
        try Data("{\"release\":1}".utf8).write(to:root.appendingPathComponent("asset-manifest.json"))
        let first=try CosyVoice3AssetLoader.assetCacheIdentity(root:root,paths:["reference.bin"])
        try Data("{\"release\":2}".utf8).write(to:root.appendingPathComponent("asset-manifest.json"),options:.atomic)
        let second=try CosyVoice3AssetLoader.assetCacheIdentity(root:root,paths:["reference.bin"])
        XCTAssertNotEqual(first,second)
    }
}
// Purpose: lock manifest-bound cache invalidation for immutable RC assets.
// Runtime: Swift XCTest iOS18+/macOS15+; generated 2026-10-05 America/New_York.
