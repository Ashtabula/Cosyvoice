// CosyVoice3ProductionCleanRoomApp.swift
// Requirement: independent physical-device consumer using only the stable CosyVoice3Core public API and the ordinary fetched asset root.
import Darwin
import CryptoKit
import Foundation
import SwiftUI
import UIKit
import CosyVoice3Core

private struct Binding: Codable {
    let schemaVersion: Int
    let releaseHead: String
    let candidateReleaseHead: String
    let validatedSourceCommit: String
    let assetIdentity: String
    let profile: String
    let version: String
    let revision: String
    let payloadTreeSha256: String
    let testedRuntimeTreeSha256: String
    let referenceTranscriptCharacters: Int
    let workloadText: String
    let workloadTextSha256: String
}

@main
struct CosyVoice3ProductionCleanRoomApp: App {
    @StateObject private var model = CleanRoomModel()
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("CosyVoice3 Production Clean Room").font(.title2.bold())
                Text(model.status).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Spacer()
            }.padding().task { await model.runOnce() }
        }
    }
}

@MainActor
final class CleanRoomModel: ObservableObject {
    @Published var status = "READY"
    private var ran = false
    func runOnce() async {
        guard !ran else { return }; ran = true; status = "RUNNING"; var phase = "resources"
        do {
            let root = try Self.resources(); let runtime = root.appendingPathComponent("Runtime", isDirectory: true)
            phase = "binding"
            let binding = try JSONDecoder().decode(Binding.self, from: Data(contentsOf: root.appendingPathComponent("production-clean-room-binding.json")))
            guard binding.schemaVersion == 1 else { throw NSError(domain:"CleanRoom",code:1,userInfo:[NSLocalizedDescriptionKey:"binding schema mismatch"]) }
            phase = "asset-manifest"
            let assetManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: runtime.appendingPathComponent("asset-manifest.json"))) as? [String:Any]
            guard assetManifest?["profile"] as? String == binding.profile, assetManifest?["assetVersion"] as? String == binding.version, assetManifest?["payloadTreeSha256"] as? String == binding.payloadTreeSha256 else { throw NSError(domain:"CleanRoom",code:2,userInfo:[NSLocalizedDescriptionKey:"asset identity mismatch"]) }
            phase = "reference"
            let transcript = try String(contentsOf: root.appendingPathComponent("reference.txt"), encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
            guard transcript.count == binding.referenceTranscriptCharacters else { throw NSError(domain:"CleanRoom",code:3,userInfo:[NSLocalizedDescriptionKey:"reference transcript mismatch"]) }
            let reference = CosyVoice3VoiceReference(audioURL: root.appendingPathComponent("reference.wav"), transcript: transcript)
            phase = "engine-init"
            let engine = try CosyVoice3Engine(assetRoot: runtime)
            phase = "capabilities"
            let capabilities = try await engine.capabilities()
            guard capabilities.outputSampleRate == 24_000, capabilities.defaultFlowSteps == .steps6, capabilities.supportedFlowSteps.map(\.rawValue) == [6,8,10] else { throw NSError(domain:"CleanRoom",code:4,userInfo:[NSLocalizedDescriptionKey:"public capabilities mismatch"]) }
            phase = "workload-binding"
            let observedWorkloadSHA256 = SHA256.hash(data: Data(binding.workloadText.utf8)).map { String(format:"%02x",$0) }.joined()
            guard observedWorkloadSHA256 == binding.workloadTextSha256 else { throw NSError(domain:"CleanRoom",code:6,userInfo:[NSLocalizedDescriptionKey:"workload text hash mismatch"]) }
            phase = "synthesize"
            let audio = try await engine.synthesize(binding.workloadText, parameters: CosyVoice3Parameters(reference:reference,instruction:"You are a helpful assistant.<|endofprompt|>",flowSteps:.steps6))
            phase = "pcm-validation"
            guard audio.sampleRate == 24_000, audio.channels == 1, !audio.samples.isEmpty, audio.samples.allSatisfy({ $0.isFinite }) else { throw NSError(domain:"CleanRoom",code:5,userInfo:[NSLocalizedDescriptionKey:"PCM contract failed"]) }
            let receipt:[String:Any] = ["schemaVersion":1,"status":"PASS_PRODUCTION_CLEAN_ROOM_PUBLIC_API_PCM","releaseHead":binding.releaseHead,"candidateReleaseHead":binding.candidateReleaseHead,"validatedSourceCommit":binding.validatedSourceCommit,"assetIdentity":binding.assetIdentity,"profile":binding.profile,"version":binding.version,"revision":binding.revision,"payloadTreeSha256":binding.payloadTreeSha256,"testedRuntimeTreeSha256":binding.testedRuntimeTreeSha256,"publicApiOnly":true,"flowSteps":6,"sampleRate":audio.sampleRate,"channels":audio.channels,"samples":audio.samples.count,"finite":true,"referenceTranscriptCharacters":transcript.count,"workloadTextCharacters":binding.workloadText.count,"workloadTextSha256":binding.workloadTextSha256,"device":UIDevice.current.model,"deviceModelIdentifier":Self.machineIdentifier(),"systemName":UIDevice.current.systemName,"systemVersion":UIDevice.current.systemVersion,"recordedAtUnix":Int(Date().timeIntervalSince1970)]
            phase = "write-pass-receipt"
            let data = try JSONSerialization.data(withJSONObject: receipt, options:[.prettyPrinted,.sortedKeys]); let url = try Self.documents().appendingPathComponent("production-clean-room-receipt.json"); try data.write(to:url,options:.atomic)
            status = "PASS samples=\(audio.samples.count) receipt=\(url.path)"
        } catch {
            let message = String(describing:error)
            status = "FAIL phase=\(phase) \(message)"
            let receipt:[String:Any] = ["schemaVersion":1,"status":"FAIL_PRODUCTION_CLEAN_ROOM","phase":phase,"error":message,"recordedAtUnix":Int(Date().timeIntervalSince1970),"device":UIDevice.current.model,"deviceModelIdentifier":Self.machineIdentifier(),"systemName":UIDevice.current.systemName,"systemVersion":UIDevice.current.systemVersion]
            if let data = try? JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]), let url = try? Self.documents().appendingPathComponent("production-clean-room-receipt.json") { try? data.write(to:url,options:.atomic) }
        }
    }
    private static func resources() throws -> URL { guard let u=Bundle.main.resourceURL?.appendingPathComponent("GeneratedAssets",isDirectory:true) else { throw NSError(domain:"CleanRoom",code:10) }; return u }
    private static func documents() throws -> URL { try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true) }
    private static func machineIdentifier() -> String { var info=utsname(); uname(&info); return withUnsafePointer(to:&info.machine){ $0.withMemoryRebound(to:CChar.self,capacity:1){ String(cString:$0) } } }
}
// Code purpose: minimal independent public-API consumer used only for the Production clean-room physical-device gate.
// Upstream source: CosyVoice3Core public API; no validation SPI/private runtime source.
// Runtime environment: iOS 18+ physical iPhone.
// Generated time: 2026-10-03 America/New_York.

// Changes 2026-10-03: every clean-room failure now writes the same Documents receipt with FAIL_PRODUCTION_CLEAN_ROOM plus the exact phase/error, so host polling cannot time out silently on app-side validation/runtime errors.

// Changes 2026-10-03: Production clean-room now consumes the exact Candidate-frozen public-API workload from its staged binding. The fixed225 acoustic bucket requires 225 generated speech tokens; inventing a new sentence can legitimately hit EOS early and is outside this validated fixed bucket.

// Changes 2026-10-03: recompute SHA256 of the staged workload on device before synthesis; the receipt now proves the exact Candidate-frozen text rather than merely echoing a host-provided digest.
