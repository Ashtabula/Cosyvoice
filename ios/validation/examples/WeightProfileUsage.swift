// WeightProfileUsage.swift
// Requirement: future client selects a validated weight profile through one public engine, without model filenames, conversion scripts or shard CLI flags.
import Foundation
import CosyVoice3Core

enum WeightProfileUsage {
    static func makeEngine(installedAssets: URL, profile: CosyVoice3WeightProfile) throws -> CosyVoice3Engine {
        // Current and Q8 are selectable. Q4 currently throws profileNotValidated
        // because physical CPU_AND_NE prefill execution-plan construction failed.
        try CosyVoice3Engine(assetRoot: installedAssets, profile: profile)
    }

    static func synthesizeOnce(installedAssets: URL, profile: CosyVoice3WeightProfile,
                               text: String, parameters: CosyVoice3Parameters) async throws -> CosyVoice3Audio {
        let engine = try makeEngine(installedAssets: installedAssets, profile: profile)
        return try await engine.synthesize(text, parameters: parameters)
    }

    static func availableProfiles() -> [CosyVoice3WeightProfileMetadata] {
        CosyVoice3WeightProfile.allCases.map(\.metadata)
    }
}
// Purpose: complete public API usage example, not a benchmark runner or automatic Q4 fallback.
// Upstream shared CosyVoice3Core Engine/WeightProfile; Swift6/iOS18+/macOS15+; generated2026-10-06 America/New_York.
// New example. Caller owns installation URL/reference/settings; same Flow6 settings for comparisons, one engine/profile at a time.
