// CosyVoice3Engine.swift
// Requirement: concrete SDK boundary now, without claiming the still-missing native text/reference frontend and host-RAS replacement are production complete.
import Foundation

public actor CosyVoice3Engine: CosyVoice3SynthesisEngine {
    public let assetRoot: URL
    private let capabilitiesValue=CosyVoice3Capabilities()
    public init(assetRoot: URL) throws {
        var isDirectory: ObjCBool=false
        guard FileManager.default.fileExists(atPath:assetRoot.path,isDirectory:&isDirectory), isDirectory.boolValue else { throw CosyVoice3EngineError.assetRootMissing(assetRoot.path) }
        self.assetRoot=assetRoot
    }
    public func capabilities() async throws -> CosyVoice3Capabilities { capabilitiesValue }
    public func validateReference(_ reference: CosyVoice3VoiceReference, probeText: String) async throws {
        guard !reference.transcript.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, !probeText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, FileManager.default.fileExists(atPath:reference.audioURL.path) else { throw CosyVoice3EngineError.invalidReference }
        throw CosyVoice3EngineError.developmentRuntimeIncomplete("native reference enrollment/frontend preflight has not yet been extracted from the validated development harness")
    }
    public func synthesize(_ text: String, parameters: CosyVoice3Parameters = .init()) async throws -> CosyVoice3Audio {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw CosyVoice3EngineError.emptyText }
        if let reference=parameters.reference { guard !reference.transcript.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, FileManager.default.fileExists(atPath:reference.audioURL.path) else { throw CosyVoice3EngineError.invalidReference } }
        throw CosyVoice3EngineError.developmentRuntimeIncomplete("native text/reference frontend and in-process RAS sampling are not yet integrated; frozen/host-bridge benchmark paths are intentionally excluded from the SDK")
    }
}

// Purpose: concrete public facade while preserving an honest Development gate.
// Upstream: validated CosyVoice3_NPU@8789402 runtime scaffold; no model/sampling behavior copied or changed here.
// Runtime: iOS17+.
// Generated: 2026-10-02 America/New_York.
