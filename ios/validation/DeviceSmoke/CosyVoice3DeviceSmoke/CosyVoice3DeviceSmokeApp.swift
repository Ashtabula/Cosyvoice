// CosyVoice3DeviceSmokeApp.swift
// Requirement: physical-device smoke/Candidate paths use the stable public CosyVoice3Core API; variable-length validation covers schema-2 RangeDim and schema-3 exact-enumerated profiles, default/no-reference and custom-reference lanes.

import AVFoundation
import Combine
import CoreML
import CryptoKit
import Darwin
import SwiftUI
import UIKit
@_spi(Validation) import CosyVoice3Core

private func writeVariableEngineProgress(
    url: URL,
    lane: String,
    stage: String,
    sourceCommit: String,
    hostReceiptSHA256: String,
    profile: String,
    speechTokenBounds: [Int],
    recordedAtUnix: Int,
    defaultN: Int? = nil,
    defaultSamples: Int? = nil
) {
    var value: [String: Any] = [
        "schemaVersion": 1,
        "status": "RUNNING",
        "phase": lane + ":" + stage,
        "sourceCommit": sourceCommit,
        "hostReceiptSha256": hostReceiptSHA256,
        "profile": profile,
        "speechTokenBounds": speechTokenBounds,
        "recordedAtUnix": recordedAtUnix,
        "updatedAtUnix": Int(Date().timeIntervalSince1970),
        "productionPromotion": false
    ]
    if let defaultN { value["defaultInferredSpeechTokensFromPCM"] = defaultN }
    if let defaultSamples { value["defaultSamples"] = defaultSamples }
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys]) else { return }
    try? data.write(to: url, options: .atomic)
}

@main
struct CosyVoice3DeviceSmokeApp: App {
    @StateObject private var model = CosyVoice3SmokeModel()
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("CosyVoice3 Device Smoke").font(.title2.bold())
                Text(model.status).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Button("Run public API reference smoke") { Task { await model.runSmoke() } }.disabled(model.running)
                Button("Run variable default + reference smoke") { Task { await model.runVariablePublicAPISmoke() } }.disabled(model.running)
                Button("Run Candidate cold/warm benchmark") { Task { await model.runCandidateBenchmark() } }.disabled(model.running)
                Button("Run Flow 10 / 8 / 6 head-to-head") { Task { await model.runFlowStepHeadToHead() } }.disabled(model.running)
                HStack {
                    Button("Play 10") { model.playFlowStep(10) }.disabled(model.running || !model.availableFlowSteps.contains(10))
                    Button("Play 8") { model.playFlowStep(8) }.disabled(model.running || !model.availableFlowSteps.contains(8))
                    Button("Play 6") { model.playFlowStep(6) }.disabled(model.running || !model.availableFlowSteps.contains(6))
                }
                Button("Copy receipt JSON") { UIPasteboard.general.string = model.receiptJSON }.disabled(model.receiptJSON.isEmpty)
                Spacer()
            }
            .padding()
            .task { guard !model.didAutoRun else { return }; model.didAutoRun = true; await model.runAutoMode() }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in model.resumePersistentIdleIfEnabled() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.resumePersistentIdleIfEnabled() }
        }
    }
}

@MainActor
final class CosyVoice3SmokeModel: ObservableObject {
    @Published var status = "READY"
    @Published var running = false
    @Published var receiptJSON = ""
    @Published var availableFlowSteps = Set<Int>()
    var didAutoRun = false
    private var benchmarkPeakFootprint: UInt64 = 0
    private var benchmarkThermalPeak = ProcessInfo.ThermalState.nominal
    private var player: AVAudioPlayer?
    private var flowStepAudios: [Int: CosyVoice3Audio] = [:]
    private var persistentIdleEngine: CosyVoice3Engine?
    private var idleReceiptTask: Task<Void, Never>?
    private var heldIdleTimerSetting: Bool?

    func resumePersistentIdleIfEnabled() {
        guard let engine = persistentIdleEngine, idleReceiptTask == nil else { return }
        idleReceiptTask = Task { [weak self] in
            defer { self?.idleReceiptTask = nil }
            let thermalStart = Self.thermalName(ProcessInfo.processInfo.thermalState)
            let started = Date()
            var peak = Self.processFootprint()
            var thermalPeak = ProcessInfo.processInfo.thermalState
            let monitor = Task { @MainActor in
                while !Task.isCancelled {
                    peak = max(peak, Self.processFootprint())
                    if ProcessInfo.processInfo.thermalState.rawValue > thermalPeak.rawValue { thermalPeak = ProcessInfo.processInfo.thermalState }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            defer { monitor.cancel() }
            await engine.resumeIdleBucketPreparation()
            await engine.waitForIdleBucketPreparation()
            do {
                let data = Data(try await engine.persistentRuntimeSnapshotJSON().utf8)
                var result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let states = result["bucketStates"] as? [[String: Any]] ?? []
                result["status"] = states.count == 4 && states.allSatisfy { $0["ready"] as? Bool == true } ? "PASS_ALL_FOUR_BUCKETS_LOAD_READY" : "RUNNING_IDLE_PAUSED_OR_PENDING"
                result["recordedAtUnix"] = Int(Date().timeIntervalSince1970)
                result["thermalState"] = Self.thermalName(ProcessInfo.processInfo.thermalState)
                result["thermalStart"] = thermalStart
                result["thermalPeak"] = Self.thermalName(thermalPeak)
                result["sampledPeakPhysicalFootprintBytes"] = peak
                result["idleWindowElapsedMilliseconds"] = Date().timeIntervalSince(started)*1000
                result["meaning"] = "persistent identity/function load readiness; not proof all exact N system specializations persist"
                _ = try Self.write(result, to: Self.receiptURL("persistent-idle-receipt.json"))
                if result["status"] as? String == "PASS_ALL_FOUR_BUCKETS_LOAD_READY", let previous = self?.heldIdleTimerSetting {
                    UIApplication.shared.isIdleTimerDisabled = previous
                    self?.heldIdleTimerSetting = nil
                }
            } catch { if let self { Self.recordFailure(error, filename:"persistent-idle-receipt.json", into:self) } }
        }
    }

    private var automatedNoPlayback: Bool {
        ProcessInfo.processInfo.arguments.contains("--no-playback")
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func resetValidationCosyVoiceCachesIfRequested() throws -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("--reset-cosy-cache") else { return false }
        guard CommandLine.arguments.contains("--validation-cold-lane=FIRST_EVER_COLD") else { throw SmokeError("cache reset requires explicit FIRST_EVER_COLD lane") }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let root = caches.appendingPathComponent("CosyVoice3Core", isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for path in ["CosyVoice3Core/ReferenceConditioning-v1", "CosyVoice3Core/RuntimeDerived-v2"] {
            let derived = support.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: derived.path) { try FileManager.default.removeItem(at: derived) }
        }
        return true
    }

    func runAutoMode() async {
        let idleSetting = UIApplication.shared.isIdleTimerDisabled
        if CommandLine.arguments.contains("--validation-idle-bootstrap") { heldIdleTimerSetting = idleSetting }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { if heldIdleTimerSetting == nil { UIApplication.shared.isIdleTimerDisabled = idleSetting } }
        do {
            let resources = try Self.generatedAssets()
            if ProcessInfo.processInfo.arguments.contains("--ane-llm-parity") { await runANEStatefulParity() }
            else if CommandLine.arguments.contains("--validation-resource-run") { await runResourceEfficiency() }
            else if CommandLine.arguments.contains("--validation-warm-pass") { await runWarmDecodePass() }
            else if CommandLine.arguments.contains("--validation-listening-checkpoint") { await runListeningCheckpoint() }
            else if CommandLine.arguments.contains("--validation-isolated-request") { await runIsolatedRequest() }
            else if CommandLine.arguments.contains("--validation-idle-bootstrap") { await runPersistentIdleBootstrap() }
            else if ProcessInfo.processInfo.arguments.contains("--ane-compute-plans") { await runANEComputePlans() }
            else if ProcessInfo.processInfo.arguments.contains("--candidate-benchmark") { await runCandidateBenchmark() }
            else if FileManager.default.fileExists(atPath: resources.appendingPathComponent("variable-public-api-smoke-mode.json").path)
                 || FileManager.default.fileExists(atPath: resources.appendingPathComponent("dynamic-public-api-smoke-mode.json").path) {
                await runVariablePublicAPISmoke()
            }
            else if FileManager.default.fileExists(atPath: resources.appendingPathComponent("flow-step-head-to-head-mode.json").path) { await runFlowStepHeadToHead() }
            else if FileManager.default.fileExists(atPath: resources.appendingPathComponent("candidate-benchmark-mode.json").path) { await runCandidateBenchmark() }
            else { await runSmoke() }
        } catch { status = "FAIL \(String(describing: error))" }
        print("[COSY-AUTO-DONE] status=\(status)")
    }

    func runSmoke() async {
        guard !running else { return }; running = true; status = "RUNNING public API custom-reference smoke..."; defer { running = false }
        do {
            let fixture = try Self.fixture()
            let engine = try CosyVoice3Engine(assetRoot: fixture.runtime)
            let capabilities = try await engine.capabilities()
            guard capabilities.supportsReferenceAudio,
                  capabilities.supportsInstruction,
                  capabilities.outputSampleRate == 24_000,
                  capabilities.defaultFlowSteps == .steps6,
                  capabilities.supportedFlowSteps.map(\.rawValue) == [6,8,10] else {
                throw SmokeError("unexpected capabilities")
            }
            try await engine.validateReference(fixture.reference, probeText: fixture.text)
            let clock = ContinuousClock(); let started = clock.now
            let audio = try await engine.synthesize(fixture.text, parameters: fixture.parameters)
            let elapsedSeconds = Self.seconds(started.duration(to: clock.now)); try Self.validate(audio)
            let duration = Self.audioDuration(audio); let stats = Self.stats(audio)
            let receipt: [String: Any] = ["schemaVersion":1,"status":"PASS_DEVICE_PUBLIC_API_REFERENCE_PCM","sampleRate":audio.sampleRate,"channels":audio.channels,"samples":audio.samples.count,"durationSeconds":duration,"elapsedSeconds":elapsedSeconds,"rtf":elapsedSeconds/duration,"finite":true,"peakAbs":stats.peak,"rms":stats.rms,"referenceTranscriptCharacters":fixture.transcript.count,"flowSteps":fixture.parameters.flowSteps.rawValue,"hostReceiptSha256":fixture.hostReceiptSHA256,"device":UIDevice.current.model,"deviceModelIdentifier":Self.machineIdentifier(),"systemName":UIDevice.current.systemName,"systemVersion":UIDevice.current.systemVersion]
            let url = try Self.receiptURL("reference-smoke-receipt.json"); receiptJSON = try Self.write(receipt, to: url); try play(audio)
            status = String(format:"PASS samples=%d duration=%.3fs elapsed=%.3fs rtf=%.3f receipt=%@",audio.samples.count,duration,elapsedSeconds,elapsedSeconds/duration,url.path)
        } catch { Self.recordFailure(error, filename:"reference-smoke-receipt.json", into:self) }
    }

    func runVariablePublicAPISmoke() async {
        guard !running else { return }
        running = true
        status = "RUNNING variable public API default + reference smoke..."
        receiptJSON = ""
        defer { running = false }

        for name in ["variable-public-api-smoke-receipt.json","variable-default.wav","variable-reference.wav"] {
            if let stale = try? Self.receiptURL(name) { try? FileManager.default.removeItem(at: stale) }
        }

        do {
            let progressURL = try Self.receiptURL("variable-public-api-smoke-receipt.json")
            let smokeRecordedAtUnix = Int(Date().timeIntervalSince1970)
            var progress: [String: Any] = [
                "schemaVersion": 1,
                "status": "RUNNING",
                "phase": "START",
                "recordedAtUnix": smokeRecordedAtUnix,
                "productionPromotion": false
            ]
            if let sourceCommit = Self.validationSourceCommit() { progress["sourceCommit"] = sourceCommit }
            _ = try Self.write(progress, to: progressURL)

            let fixture = try Self.fixture()
            let variable = try Self.variableManifestInfo(runtime: fixture.runtime)
            let profile = variable.profile
            let nmin = variable.speechTokenMinimum
            let nmax = variable.speechTokenMaximum

            let engine = try CosyVoice3Engine(assetRoot: fixture.runtime)
            let capabilities = try await engine.capabilities()
            guard capabilities.supportsReferenceAudio,
                  capabilities.supportsInstruction,
                  capabilities.outputSampleRate == 24_000,
                  capabilities.defaultFlowSteps == .steps6,
                  capabilities.supportedFlowSteps.map(\.rawValue) == [6,8,10] else {
                throw SmokeError("unexpected capabilities")
            }

            let clock = ContinuousClock()
            let defaultText = "This is a CosyVoice3 variable-length default voice validation."
            let boundSourceCommit = fixture.sourceCommit
            let boundHostReceiptSHA256 = fixture.hostReceiptSHA256
            let boundSpeechTokenBounds = [nmin,nmax]
            await engine.setValidationProgressObserver { stage in
                writeVariableEngineProgress(
                    url: progressURL,
                    lane: "DEFAULT",
                    stage: stage,
                    sourceCommit: boundSourceCommit,
                    hostReceiptSHA256: boundHostReceiptSHA256,
                    profile: profile,
                    speechTokenBounds: boundSpeechTokenBounds,
                    recordedAtUnix: smokeRecordedAtUnix
                )
            }
            progress["phase"] = "DEFAULT_SYNTHESIS"
            progress["profile"] = profile
            progress["schemaVersion"] = variable.schemaVersion
            progress["acousticShapeMode"] = variable.acousticShapeMode
            progress["speechTokenBounds"] = [nmin,nmax]
            progress["hostReceiptSha256"] = fixture.hostReceiptSHA256
            progress["text"] = defaultText
            progress["updatedAtUnix"] = Int(Date().timeIntervalSince1970)
            _ = try Self.write(progress, to: progressURL)

            let defaultStart = clock.now
            let defaultAudio = try await engine.synthesize(
                defaultText,
                parameters: CosyVoice3Parameters(flowSteps: .steps6)
            )
            let defaultMilliseconds = Self.seconds(defaultStart.duration(to: clock.now)) * 1000
            try Self.validate(defaultAudio)
            guard defaultAudio.samples.count % 960 == 0 else { throw SmokeError("default PCM sample count is not divisible by 960") }
            let defaultN = defaultAudio.samples.count / 960
            guard (nmin...nmax).contains(defaultN) else { throw SmokeError("default inferred N out of manifest bounds: \(defaultN)") }
            let defaultReport = await engine.lastSynthesisReport()
            let defaultWAV = Self.wavData(defaultAudio)
            try defaultWAV.write(to: Self.receiptURL("variable-default.wav"), options: .atomic)

            progress["phase"] = "REFERENCE_SYNTHESIS"
            progress["defaultSamples"] = defaultAudio.samples.count
            progress["defaultInferredSpeechTokensFromPCM"] = defaultN
            progress["defaultSynthesisMilliseconds"] = defaultMilliseconds
            if let function = variable.functionName(for: defaultN) { progress["defaultFunctionName"] = function }
            progress["updatedAtUnix"] = Int(Date().timeIntervalSince1970)
            _ = try Self.write(progress, to: progressURL)

            let boundDefaultSamples = defaultAudio.samples.count
            await engine.setValidationProgressObserver { stage in
                writeVariableEngineProgress(
                    url: progressURL,
                    lane: "REFERENCE",
                    stage: stage,
                    sourceCommit: boundSourceCommit,
                    hostReceiptSHA256: boundHostReceiptSHA256,
                    profile: profile,
                    speechTokenBounds: boundSpeechTokenBounds,
                    recordedAtUnix: smokeRecordedAtUnix,
                    defaultN: defaultN,
                    defaultSamples: boundDefaultSamples
                )
            }
            let referenceParameters = CosyVoice3Parameters(
                reference: fixture.reference,
                instruction: nil,
                flowSteps: .steps6
            )
            let referenceStart = clock.now
            let referenceAudio = try await engine.synthesize(
                fixture.text,
                parameters: referenceParameters
            )
            let referenceMilliseconds = Self.seconds(referenceStart.duration(to: clock.now)) * 1000
            try Self.validate(referenceAudio)
            guard referenceAudio.samples.count % 960 == 0 else { throw SmokeError("reference PCM sample count is not divisible by 960") }
            let referenceN = referenceAudio.samples.count / 960
            guard (nmin...nmax).contains(referenceN) else { throw SmokeError("reference inferred N out of manifest bounds: \(referenceN)") }
            let referenceReport = await engine.lastSynthesisReport()
            let referenceWAV = Self.wavData(referenceAudio)
            try referenceWAV.write(to: Self.receiptURL("variable-reference.wav"), options: .atomic)

            await engine.setValidationProgressObserver(nil)
            var receipt: [String: Any] = [
                "schemaVersion": 1,
                "status": "PASS_VARIABLE_PUBLIC_API_DEFAULT_AND_REFERENCE",
                "benchmark": "variable-public-api-default-and-reference-v1",
                "sourceCommit": fixture.sourceCommit,
                "recordedAtUnix": Int(Date().timeIntervalSince1970),
                "profile": profile,
                "assetSchemaVersion": variable.schemaVersion,
                "acousticShapeMode": variable.acousticShapeMode,
                "speechTokenBounds": [nmin,nmax],
                "flowSteps": CosyVoice3FlowSteps.productionDefault.rawValue,
                "generationContract": "maxN=min(targetTextTokens*20,450,512-logicalPrefixLength)",
                "logicalPrefixMaximumForFullN450Window": 62,
                "requestedComputePlacement": [
                    "llmPrefill": Self.requestedRolePlacement("llmPrefill", defaultValue: "CPU_AND_NE"),
                    "llmDecode": Self.requestedRolePlacement("llmDecode", defaultValue: "CPU_AND_NE"),
                    "acoustic": Self.requestedAcousticPlacement(),
                    "referenceEncoders": "CPU_ONLY",
                    "meaning": "requested MLComputeUnits; not measured accelerator residency"
                ],
                "default": [
                    "text": defaultText,
                    "samples": defaultAudio.samples.count,
                    "inferredSpeechTokensFromPCM": defaultN,
                    "durationSeconds": Self.audioDuration(defaultAudio),
                    "synthesisMilliseconds": defaultMilliseconds,
                    "wavSha256": SHA256.hash(data: defaultWAV).map { String(format:"%02x",$0) }.joined()
                ],
                "reference": [
                    "text": fixture.text,
                    "referenceTranscriptCharacters": fixture.transcript.count,
                    "samples": referenceAudio.samples.count,
                    "inferredSpeechTokensFromPCM": referenceN,
                    "durationSeconds": Self.audioDuration(referenceAudio),
                    "synthesisMilliseconds": referenceMilliseconds,
                    "wavSha256": SHA256.hash(data: referenceWAV).map { String(format:"%02x",$0) }.joined()
                ],
                "hostReceiptSha256": fixture.hostReceiptSHA256,
                "device": UIDevice.current.model,
                "deviceModelIdentifier": Self.machineIdentifier(),
                "systemName": UIDevice.current.systemName,
                "systemVersion": UIDevice.current.systemVersion,
                "productionPromotion": false
            ]
            if let payloadTreeSHA256 = fixture.payloadTreeSHA256 { receipt["payloadTreeSha256"] = payloadTreeSHA256 }
            if let exportReceiptSHA256 = fixture.exportReceiptSHA256 { receipt["exportReceiptSha256"] = exportReceiptSHA256 }
            if let assetExportSourceCommit = fixture.assetExportSourceCommit { receipt["assetExportSourceCommit"] = assetExportSourceCommit }
            if variable.schemaVersion == 2 {
                receipt["dynamicAcousticExecutionHints"] = [
                    "reshapeFrequency": "INFREQUENT",
                    "meaning": "schema-2 RangeDim comparison path"
                ]
            } else {
                receipt["enumeratedAcousticExecution"] = [
                    "padding": false,
                    "crop": false,
                    "defaultFunctionName": variable.functionName(for: defaultN) ?? "",
                    "referenceFunctionName": variable.functionName(for: referenceN) ?? "",
                    "familyCount": variable.families.count
                ]
            }
            if let defaultReport { receipt["defaultReport"] = Self.reportDictionary(defaultReport) }
            if let referenceReport { receipt["referenceReport"] = Self.reportDictionary(referenceReport) }
            let url = try Self.receiptURL("variable-public-api-smoke-receipt.json")
            receiptJSON = try Self.write(receipt, to: url)
            if !automatedNoPlayback { try play(referenceAudio) }
            status = "PASS variable default N=\(defaultN) reference N=\(referenceN) receipt=\(url.path)"
        } catch {
            Self.recordFailure(error, filename:"variable-public-api-smoke-receipt.json", into:self)
        }
    }

    func runWarmDecodePass() async {
        guard !running else { return };running=true;defer{running=false}
        let filename="warm-decode-pass-receipt.json"
        do {
            let modes=CommandLine.arguments.filter{$0.hasPrefix("--validation-warm-pass-mode=")}
            guard modes.count==1 else {throw SmokeError("warm pass requires exactly one mode")}
            let mode=String(modes[0].dropFirst("--validation-warm-pass-mode=".count))
            guard ["memory","repeat"].contains(mode) else {throw SmokeError("unsupported warm pass mode; no fallback")}
            guard CommandLine.arguments.contains("--validation-flow-partition=2"),
                  !CommandLine.arguments.contains("--reset-cosy-cache"),
                  !CommandLine.arguments.contains(where:{$0.hasPrefix("--validation-placement=") || $0.hasPrefix("--validation-single-function=")}),
                  Self.thermalName(ProcessInfo.processInfo.thermalState)=="nominal" else {throw SmokeError("warm pass requires SHARDS2/unchanged placement/noreset/nominal start")}
            let memory:WarmPassMemoryTimeline?=(mode=="memory" || CommandLine.arguments.contains("--validation-model-lifetime") || CommandLine.arguments.contains("--validation-execution-audit")) ? WarmPassMemoryTimeline():nil
            defer{_ = memory?.stop()}
            memory?.record("before_fixture_and_package_checks")
            let fixture=try Self.fixture(),experimental=try Self.validateExperimentalModels(runtime:fixture.runtime)
            memory?.record("before_engine_creation")
            let engine=try CosyVoice3Engine(assetRoot:fixture.runtime,idleBucketPreparation:false)
            memory?.record("after_engine_creation")
            await engine.setValidationSamplerSeed(42)
            await engine.setValidationProgressObserver { phase in
                memory?.record(phase)
                print("[COSY-WARM-PASS-STAGE] \(phase)")
            }
            let count=mode=="memory" ? 2:5
            var outputs=[CosyVoice3Audio](),rows=[[String:Any]]()
            for request in 1...count {
                memory?.record(request==2 ? "before_second_warm_request":"before_request_\(request)")
                let thermal=Self.thermalName(ProcessInfo.processInfo.thermalState),cpu=Self.processCPUMilliseconds(),start=ContinuousClock.now
                let audio=try await engine.synthesize(fixture.text,parameters:fixture.parameters)
                let ms=Self.seconds(start.duration(to:ContinuousClock.now))*1000,cpuMs=Self.processCPUMilliseconds()-cpu
                memory?.record("request_\(request)_completion")
                try Self.validate(audio)
                guard audio.samples.count==249600,let report=await engine.lastSynthesisReport(),report.flowSteps == .steps6 else {throw SmokeError("frozen warmpass invariant")}
                outputs.append(audio)
                rows.append(["request":request,"label":request==1 ? "first":(request==2 ? "warm_priming":"measured_warm"),"SHARDS":2,"flowSteps":6,"totalMilliseconds":ms,"RTF":ms/10400,"selfProcessCPUMilliseconds":cpuMs,"stages":Self.reportDictionary(report),"boundaryPhysicalFootprintBytes":Self.processFootprint(),"callerRetainedPCMBytes":outputs.count*249600*4,"thermalStart":thermal,"thermalEnd":Self.thermalName(ProcessInfo.processInfo.thermalState)])
                print("[COSY-WARM-PASS] SHARDS=2 request=\(request) totalMs=\(ms) thermal=\(Self.thermalName(ProcessInfo.processInfo.thermalState))")
                if mode=="memory" {
                    memory?.record("idle_after_request_\(request)")
                    // Only the explicit memory lane observes normal idle/30s cache expiry.
                    // No idle delay is used in performance repeats or reported as cooling.
                    if CommandLine.arguments.contains("--validation-model-lifetime") {
                        let checkpoints=request==1 ? [1,3]:[1,3,10,35]
                        var elapsed=0
                        for seconds in checkpoints {
                            try await Task.sleep(for:.seconds(seconds-elapsed)); elapsed=seconds
                            memory?.record("request_\(request)_idle_\(seconds)s")
                        }
                    } else {try await Task.sleep(for:.seconds(request==1 ? 3:35))}
                    memory?.record("idle_observation_end_\(request)")
                }
            }
            let timeline=memory?.stop() ?? []
            let pcmHashes=outputs.map { audio in audio.samples.withUnsafeBytes { SHA256.hash(data:Data($0)).map{String(format:"%02x",$0)}.joined() } }
            guard pcmHashes.allSatisfy({$0=="909a1b85650b172604fb2d39b6a35f8f3b5cbf80bd97beb76e775b73ee4cd694"}) else{throw SmokeError("STOP PCM identity differs")}
            let wav=Self.wavData(outputs.last!),wavSHA=SHA256.hash(data:wav).map{String(format:"%02x",$0)}.joined()
            guard wavSHA=="a04f69c7d01e08bc779c8a49dafa6fd7723397cf3da6864060f17f8d68277888" else{throw SmokeError("STOP WAV identity differs")}
            try wav.write(to:Self.receiptURL("warm-decode-pass.wav"),options:.atomic)
            let snapshot=try JSONSerialization.jsonObject(with:Data(await engine.persistentRuntimeSnapshotJSON().utf8))
            let receipt:[String:Any]=["schemaVersion":1,"status":"PASS_BIT_IDENTICAL_WARM_PASS","mode":mode,"SHARDS":2,"flowSteps":6,"N":260,"function":"n257_384","sampleRate":24000,"samples":249600,"sourceCommit":fixture.sourceCommit,"processID":ProcessInfo.processInfo.processIdentifier,"device":Self.machineIdentifier(),"iOS":UIDevice.current.systemVersion,"rows":rows,"memoryTimeline":timeline,"memoryMeaning":"100ms sampled process footprint, not exact peak/per-model attribution; diagnostic fixtures and retained caller PCM included","memoryIdleMeaning":"memory lane only observes3s then35s idle/cache expiry; NOT performance cooldown/throttle","PCM_SHA256":pcmHashes,"WAV_SHA256":wavSHA,"publicAPI":"CosyVoice3Engine.synthesize()","inputText":fixture.text,"inputTextSHA256":SHA256.hash(data:Data(fixture.text.utf8)).map{String(format:"%02x",$0)}.joined(),"referenceWAVSHA256":SHA256.hash(data:try Data(contentsOf:fixture.reference.audioURL)).map{String(format:"%02x",$0)}.joined(),"payloadTreeSHA256":fixture.payloadTreeSHA256 ?? "","experimentalModelIdentity":experimental,"persistentRuntime":snapshot,"noFileIOInsideTimedLoops":true,"noPlayback":true]
            _ = try Self.write(receipt,to:Self.receiptURL(filename))
            status="PASS warm decode pass SHARDS2 mode=\(mode)"
        } catch {Self.recordFailure(error,filename:filename,into:self)}
    }

    // Validation/export only: unchanged public synthesis, serial fixed corpus, exact device WAV.
    func runListeningCheckpoint() async {
        guard !running else { return }; running = true; defer { running = false }
        let receiptName = "listening-checkpoint-receipt.json"
        do {
            guard CommandLine.arguments.contains("--validation-flow-partition=2"),
                  !CommandLine.arguments.contains("--reset-cosy-cache"),
                  !CommandLine.arguments.contains(where: { $0.hasPrefix("--validation-single-function=") || $0.hasPrefix("--validation-placement=") }) else { throw SmokeError("listening requires SHARDS2 frozen multifunction default placement, no reset") }
            let fixture = try Self.fixture()
            let corpusData = try Data(contentsOf: Self.receiptURL("listening-corpus.json"))
            guard let corpus = try JSONSerialization.jsonObject(with: corpusData) as? [String: Any],
                  corpus["shards"] as? Int == 2, corpus["flowSteps"] as? Int == 6,
                  corpus["sampleRate"] as? Int == 24000, corpus["seed"] as? Int == 42,
                  let entries = corpus["samples"] as? [[String: Any]], (4...6).contains(entries.count) else { throw SmokeError("invalid fixed listening corpus") }
            func sha(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
            guard sha(try Data(contentsOf: fixture.reference.audioURL)) == corpus["referenceWavSHA256"] as? String,
                  sha(try Data(contentsOf: Self.generatedAssets().appendingPathComponent("reference.txt"))) == corpus["referenceTranscriptFileSHA256"] as? String,
                  sha(try Data(contentsOf: fixture.runtime.appendingPathComponent("cosyvoice3_enumerated.json"))) == corpus["manifestSHA256"] as? String,
                  fixture.payloadTreeSHA256 == corpus["payloadTreeSHA256"] as? String else { throw SmokeError("listening frozen identity mismatch") }
            guard let buildURL = Bundle.main.url(forResource:"validation-build-source",withExtension:"json",subdirectory:"GeneratedAssets"),
                  let build = try JSONSerialization.jsonObject(with:Data(contentsOf:buildURL)) as? [String:Any],
                  build["sourceCommit"] as? String == fixture.sourceCommit else { throw SmokeError("listening signed source mismatch") }
            let experimental = try Self.validateExperimentalModels(runtime:fixture.runtime)
            let variable = try Self.variableManifestInfo(runtime:fixture.runtime)
            let engine = try CosyVoice3Engine(assetRoot:fixture.runtime,idleBucketPreparation:false)
            await engine.setValidationSamplerSeed(42)
            await engine.setValidationProgressObserver { print("[COSY-LISTENING-STAGE] \($0)") }
            var rows = [[String:Any]]()
            var receipt: [String:Any] = ["schemaVersion":1,"status":"RUNNING","SHARDS":2,"flowSteps":6,"seed":42,"publicAPI":"CosyVoice3Engine.synthesize()","sourceCommit":fixture.sourceCommit,"processID":ProcessInfo.processInfo.processIdentifier,"device":Self.machineIdentifier(),"iOS":UIDevice.current.systemVersion,"corpusSHA256":sha(corpusData),"runtimeRoot":fixture.runtime.path,"payloadTreeSHA256":fixture.payloadTreeSHA256 ?? "","manifestSHA256":corpus["manifestSHA256"] ?? "","experimentalModelIdentity":experimental,"humanListening":"PENDING_HUMAN","LAST_KNOWN_GOOD":NSNull(),"playback":false]
            for entry in entries {
                guard let id = entry["id"] as? String, id.range(of:"^sample0[1-6]$",options:.regularExpression) != nil,
                      let text = entry["text"] as? String else { throw SmokeError("invalid corpus sample") }
                print("[COSY-LISTENING] SHARDS=2 Flow=6 begin \(id)")
                let cpu = Self.processCPUMilliseconds(), start = ContinuousClock.now
                let thermal = Self.thermalName(ProcessInfo.processInfo.thermalState)
                let audio = try await engine.synthesize(text,parameters:fixture.parameters)
                let elapsed = Self.seconds(start.duration(to:ContinuousClock.now))*1000
                let cpuMs = Self.processCPUMilliseconds()-cpu
                try Self.validate(audio)
                guard audio.samples.count % 960 == 0, let stages = await engine.lastSynthesisReport(), stages.flowSteps == .steps6 else { throw SmokeError("listening shape/Flow invariant") }
                let n = audio.samples.count/960
                if let expected = entry["expectedSamples"] as? Int, expected != audio.samples.count { throw SmokeError("listening expected sample count mismatch") }
                let pcmSHA = audio.samples.withUnsafeBytes { sha(Data($0)) }
                if let expected = entry["previousSamePlacementPCMSHA256"] as? String, expected != pcmSHA { throw SmokeError("listening frozen PCM changed") }
                let filename = "checkpoint_001_" + id + "_candidate.wav"
                let wav = Self.wavData(audio)
                try wav.write(to:Self.receiptURL(filename),options:.atomic)
                rows.append(["id":id,"text":text,"textSHA256":sha(Data(text.utf8)),"SHARDS":2,"flowSteps":6,"N":n,"functionName":variable.functionName(for:n) ?? "","samples":audio.samples.count,"sampleRate":audio.sampleRate,"audioSeconds":Self.audioDuration(audio),"totalMs":elapsed,"RTF":elapsed/1000/Self.audioDuration(audio),"processCPUMs":cpuMs,"stages":Self.reportDictionary(stages),"PCM_SHA256":pcmSHA,"WAV_SHA256":sha(wav),"WAV":filename,"outputClass":entry["previousSamePlacementPCMSHA256"].map { _ in "BIT_IDENTICAL" as Any } ?? NSNull(),"comparison":"FIRST_CORPUS_BASELINE_PENDING_HUMAN","thermalStart":thermal,"thermalEnd":Self.thermalName(ProcessInfo.processInfo.thermalState),"boundaryPhysicalFootprintBytes":Self.processFootprint()])
                receipt["samples"] = rows
                _ = try Self.write(receipt,to:Self.receiptURL(receiptName))
                print("[COSY-LISTENING] SHARDS=2 exported device WAV \(filename) N=\(n)")
            }
            receipt["status"] = "PASS_DEVICE_CORPUS_PENDING_HUMAN"
            receipt["persistentRuntime"] = try JSONSerialization.jsonObject(with:Data(await engine.persistentRuntimeSnapshotJSON().utf8))
            _ = try Self.write(receipt,to:Self.receiptURL(receiptName))
            status = "PASS listening corpus SHARDS=2 PENDING_HUMAN; WAV export to Mac still required"
        } catch { Self.recordFailure(error,filename:receiptName,into:self) }
    }

    func runCandidateBenchmark() async {
        guard !running else { return }; running = true; status = "RUNNING Candidate public-API cold/warm benchmark..."; defer { running = false }
        if let stale = try? Self.receiptURL("candidate-benchmark-receipt.json") { try? FileManager.default.removeItem(at: stale) }
        benchmarkPeakFootprint = Self.processFootprint()
        benchmarkThermalPeak = ProcessInfo.processInfo.thermalState
        let thermalMonitor = Task { @MainActor in
            while !Task.isCancelled {
                benchmarkPeakFootprint = max(benchmarkPeakFootprint, Self.processFootprint())
                if ProcessInfo.processInfo.thermalState.rawValue > benchmarkThermalPeak.rawValue { benchmarkThermalPeak = ProcessInfo.processInfo.thermalState }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { thermalMonitor.cancel() }
        do {
            if CommandLine.arguments.contains("--wait-thermal-nominal") {
                let started = Date()
                while ProcessInfo.processInfo.thermalState != .nominal && Date().timeIntervalSince(started) < 300 {
                    let waiting: [String: Any] = ["schemaVersion":1,"status":"RUNNING","phase":"THERMAL_WAIT","recordedAtUnix":Int(Date().timeIntervalSince1970),"thermalState":Self.thermalName(ProcessInfo.processInfo.thermalState)]
                    _ = try Self.write(waiting, to: Self.receiptURL("candidate-benchmark-receipt.json"))
                    try await Task.sleep(for: .seconds(5))
                }
            }
            let validationCacheReset = try Self.resetValidationCosyVoiceCachesIfRequested()
            let thermalStart = ProcessInfo.processInfo.thermalState
            benchmarkThermalPeak = thermalStart
            benchmarkPeakFootprint = Self.processFootprint()
            guard thermalStart == .nominal else {
                throw SmokeError("Candidate benchmark requires thermal nominal at start; actual=\(Self.thermalName(thermalStart))")
            }
            let fixture = try Self.fixture()
            let experimentalIdentity = try Self.validateExperimentalModels(runtime: fixture.runtime)
            _ = try Self.write(["status":"RUNNING","phase":"ENGINE_INIT","recordedAtUnix":Int(Date().timeIntervalSince1970),"processID":ProcessInfo.processInfo.processIdentifier,"physicalFootprintBytes":Self.processFootprint(),"sourceCommit":fixture.sourceCommit], to: Self.receiptURL("candidate-benchmark-receipt.json"))
            let activeManifest = try Self.activeManifest(runtime: fixture.runtime)
            let activeProfile = activeManifest.profile
            let variable = try? Self.variableManifestInfo(runtime: fixture.runtime)
            let speechTokenBounds = variable.map { [$0.speechTokenMinimum, $0.speechTokenMaximum] }
            let clock = ContinuousClock(); let initStart = clock.now
            let engine = try CosyVoice3Engine(assetRoot: fixture.runtime, idleBucketPreparation: false); let engineInitMilliseconds = Self.seconds(initStart.duration(to: clock.now))*1000
            await engine.setValidationProgressObserver { phase in print("[COSY-VALIDATION-STAGE] \(phase)") }
            let validationSamplerSeed: UInt64 = 42
            await engine.setValidationSamplerSeed(validationSamplerSeed)
            let capabilities = try await engine.capabilities()
            guard capabilities.supportsReferenceAudio,
                  capabilities.supportsInstruction,
                  capabilities.outputSampleRate == 24_000,
                  capabilities.defaultFlowSteps == .steps6,
                  capabilities.supportedFlowSteps.map(\.rawValue) == [6,8,10] else {
                throw SmokeError("unexpected capabilities")
            }
            var idlePreparationMilliseconds = 0.0
            var idleFamilyReadinessMilliseconds = 0.0
            if CommandLine.arguments.contains("--validation-idle-readiness") {
                let idleStarted = clock.now
                _ = try await engine.prepare(reference: fixture.reference)
                idleFamilyReadinessMilliseconds = try await engine.prepareValidationAcousticFamily(speechTokenCount: 260)
                idlePreparationMilliseconds = Self.seconds(idleStarted.duration(to: clock.now))*1000
            }
            let firstStart = clock.now; let first = try await engine.synthesize(fixture.text, parameters: fixture.parameters); let firstMilliseconds = Self.seconds(firstStart.duration(to: clock.now))*1000; try Self.validate(first)
            let firstStages = await engine.lastSynthesisReport()
            let warmCPUStart = Self.processCPUMilliseconds()
            let repeatStart = clock.now; let repeatAudio = try await engine.synthesize(fixture.text, parameters: fixture.parameters); let repeatMilliseconds = Self.seconds(repeatStart.duration(to: clock.now))*1000; try Self.validate(repeatAudio)
            let warmCPUMilliseconds = Self.processCPUMilliseconds()-warmCPUStart
            let repeatStages = await engine.lastSynthesisReport()
            let inputIdentity: [String: Any] = [
                "text": fixture.text,
                "textSha256": SHA256.hash(data: Data(fixture.text.utf8)).map { String(format: "%02x", $0) }.joined(),
                "referenceWavSha256": SHA256.hash(data: try Data(contentsOf: fixture.reference.audioURL)).map { String(format: "%02x", $0) }.joined(),
                "referenceTranscriptFileSha256": SHA256.hash(data: try Data(contentsOf: Self.generatedAssets().appendingPathComponent("reference.txt"))).map { String(format: "%02x", $0) }.joined(),
                "effectiveReferenceTranscriptSha256": SHA256.hash(data: Data(fixture.transcript.utf8)).map { String(format: "%02x", $0) }.joined(),
                "instructionSha256": SHA256.hash(data: Data((fixture.parameters.instruction ?? "").utf8)).map { String(format: "%02x", $0) }.joined(),
                "runtimeRoot": fixture.runtime.path,
                "manifestSha256": SHA256.hash(data: try Data(contentsOf: fixture.runtime.appendingPathComponent("cosyvoice3_enumerated.json"))).map { String(format: "%02x", $0) }.joined()
            ]
            guard first.samples.count == repeatAudio.samples.count else {
                throw SmokeError("deterministic Candidate cold/warm sample-count mismatch: \(first.samples.count) != \(repeatAudio.samples.count)")
            }
            let firstWAVSHA256 = SHA256.hash(data: Self.wavData(first)).map { String(format:"%02x",$0) }.joined()
            let repeatWAVSHA256 = SHA256.hash(data: Self.wavData(repeatAudio)).map { String(format:"%02x",$0) }.joined()
            guard firstWAVSHA256 == repeatWAVSHA256 else {
                throw SmokeError("deterministic Candidate cold/warm WAV mismatch")
            }
            let firstDuration = Self.audioDuration(first); let repeatDuration = Self.audioDuration(repeatAudio); let firstStats = Self.stats(first); let repeatStats = Self.stats(repeatAudio)
            var sustained = [[String: Any]]()
            var sustainedAudio = [CosyVoice3Audio]()
            let sustainedCount = CommandLine.arguments.first(where: { $0.hasPrefix("--validation-sustained-count=") }).flatMap { Int($0.dropFirst("--validation-sustained-count=".count)) } ?? 0
            guard (0...20).contains(sustainedCount) else { throw SmokeError("invalid sustained count") }
            if sustainedCount > 0 && CommandLine.arguments.contains("--validation-sustained-nominal-gate") {
                let started = Date()
                while ProcessInfo.processInfo.thermalState != .nominal && Date().timeIntervalSince(started) < 300 { try await Task.sleep(for: .seconds(5)) }
                guard ProcessInfo.processInfo.thermalState == .nominal else { throw SmokeError("sustained group nominal start gate failed") }
            }
            for index in 0..<sustainedCount {
                let thermalBefore = Self.thermalName(ProcessInfo.processInfo.thermalState)
                let cpuStart = Self.processCPUMilliseconds()
                let start = clock.now
                let audio = try await engine.synthesize(fixture.text, parameters: fixture.parameters)
                let ms = Self.seconds(start.duration(to: clock.now))*1000
                try Self.validate(audio)
                sustainedAudio.append(audio)
                let stages = await engine.lastSynthesisReport()
                var row: [String: Any] = ["index": index, "totalMilliseconds": ms, "RTF":ms/1000/Self.audioDuration(audio), "samples":audio.samples.count,"thermalStart":thermalBefore,"thermalEnd":Self.thermalName(ProcessInfo.processInfo.thermalState),"physicalFootprintBytes":Self.processFootprint(),"interRequestDelay":false,"hashingDeferredUntilGroupEnd":true]
                row["processCPUMilliseconds"] = Self.processCPUMilliseconds()-cpuStart
                if let stages { row["stages"] = Self.reportDictionary(stages) }
                sustained.append(row)
            }
            let thermalEnd = ProcessInfo.processInfo.thermalState
            for (index,audio) in sustainedAudio.enumerated() {
                let hash = SHA256.hash(data: Self.wavData(audio)).map { String(format:"%02x",$0) }.joined()
                guard hash == repeatWAVSHA256 else { throw SmokeError("sustained deterministic output diverged") }
                sustained[index]["wavSha256"] = hash
            }
            var receipt: [String: Any] = ["schemaVersion":1,"status":"PASS_CANDIDATE_BENCHMARK","benchmark":"public-api-candidate-v1","sourceCommit":fixture.sourceCommit,"recordedAtUnix":Int(Date().timeIntervalSince1970),"profile":activeProfile,"coldDefinition":"fresh process + fresh CosyVoice3Engine; automatic bounded model preparation is included; no validateReference prewarm","warmDefinition":"second identical public synthesize call on the same engine instance after automatic preparation","referenceValidationPrewarm":false,"engineInitMilliseconds":engineInitMilliseconds,"firstSynthesisMilliseconds":firstMilliseconds,"repeatSynthesisMilliseconds":repeatMilliseconds,"firstAudioSeconds":firstDuration,"repeatAudioSeconds":repeatDuration,"firstRTF":firstMilliseconds/1000/firstDuration,"repeatRTF":repeatMilliseconds/1000/repeatDuration,"firstSamples":first.samples.count,"repeatSamples":repeatAudio.samples.count,"sameSampleCount":first.samples.count == repeatAudio.samples.count,"sampleRate":first.sampleRate,"channels":first.channels,"finite":true,"firstPeakAbs":firstStats.peak,"firstRMS":firstStats.rms,"repeatPeakAbs":repeatStats.peak,"repeatRMS":repeatStats.rms,"referenceTranscriptCharacters":fixture.transcript.count,"flowSteps":fixture.parameters.flowSteps.rawValue,"hostReceiptSha256":fixture.hostReceiptSHA256,"device":UIDevice.current.model,"deviceModelIdentifier":Self.machineIdentifier(),"systemName":UIDevice.current.systemName,"systemVersion":UIDevice.current.systemVersion,"thermalStart":Self.thermalName(thermalStart),"thermalEnd":Self.thermalName(thermalEnd),"playbackDuringBenchmark":false,"validationCacheReset":validationCacheReset,"validationSamplerSeed":validationSamplerSeed,"matchedDeterministicSpeechLength":true,"matchedDeterministicWav":true,"firstWavSha256":firstWAVSHA256,"repeatWavSha256":repeatWAVSHA256]
            receipt["warmProcessCPUMilliseconds"] = warmCPUMilliseconds
            receipt["CPUTimeMeaning"] = "getrusage self user+system CPU; excludes driver/services outside process, no GPU/ANE power claim"
            receipt["idlePreparationMilliseconds"] = idlePreparationMilliseconds
            receipt["idleFamilyReadinessMilliseconds"] = idleFamilyReadinessMilliseconds
            if CommandLine.arguments.contains("--validation-idle-readiness") {
                receipt["coldDefinition"] = "idle-prepared first synthesis; preparation cost recorded separately; not a raw cold-start claim"
                receipt["referenceValidationPrewarm"] = true
                receipt["idleReadinessPredictions"] = false
            }
            receipt["materializeExistingTEOutput"] = CommandLine.arguments.contains("--validation-materialize-te")
            receipt["SHARDS"] = CommandLine.arguments.first(where: { $0.hasPrefix("--validation-flow-partition=") }).flatMap { Int($0.dropFirst("--validation-flow-partition=".count)) } ?? 6
            receipt["flowPartition"] = CommandLine.arguments.first(where: { $0.hasPrefix("--validation-flow-partition=") }) ?? "6"
            receipt["sustainedRuns"] = sustained
            receipt["inputIdentity"] = inputIdentity
            receipt["acousticCacheStrategy"] = CommandLine.arguments.first(where: { $0.hasPrefix("--validation-acoustic-cache=") }) ?? "none"
            receipt["firstFloat32PCMSha256"] = first.samples.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
            receipt["warmFloat32PCMSha256"] = repeatAudio.samples.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
            if let payloadTreeSHA256 = fixture.payloadTreeSHA256 { receipt["payloadTreeSha256"] = payloadTreeSHA256 }
            if let exportReceiptSHA256 = fixture.exportReceiptSHA256 { receipt["exportReceiptSha256"] = exportReceiptSHA256 }
            if let assetExportSourceCommit = fixture.assetExportSourceCommit { receipt["assetExportSourceCommit"] = assetExportSourceCommit }
            if let speechTokenBounds, let variable {
                receipt["speechTokenBounds"] = speechTokenBounds
                receipt["acousticShapeMode"] = variable.acousticShapeMode
                receipt["requestedComputePlacement"] = [
                    "llmPrefill": Self.requestedRolePlacement("llmPrefill", defaultValue: "CPU_AND_NE"),
                    "llmDecode": Self.requestedRolePlacement("llmDecode", defaultValue: "CPU_AND_NE"),
                    "acoustic": Self.requestedAcousticPlacement(),
                    "referenceEncoders": "CPU_ONLY",
                    "meaning": "requested MLComputeUnits; not measured accelerator residency"
                ]
                if variable.schemaVersion == 2 {
                    receipt["dynamicAcousticExecutionHints"] = [
                        "reshapeFrequency": "INFREQUENT",
                        "meaning": "schema-2 RangeDim comparison path"
                    ]
                } else {
                    let firstN = first.samples.count % 960 == 0 ? first.samples.count / 960 : -1
                    let repeatN = repeatAudio.samples.count % 960 == 0 ? repeatAudio.samples.count / 960 : -1
                    receipt["enumeratedAcousticExecution"] = [
                        "padding": false,
                        "crop": false,
                        "firstN": firstN,
                        "repeatN": repeatN,
                        "firstFunctionName": variable.functionName(for: firstN) ?? "",
                        "repeatFunctionName": variable.functionName(for: repeatN) ?? "",
                        "familyCount": variable.families.count
                    ]
                }
            }
            if let firstStages { receipt["firstStages"] = Self.reportDictionary(firstStages) }
            if let repeatStages { receipt["repeatStages"] = Self.reportDictionary(repeatStages) }
            try Self.wavData(first).write(to: Self.receiptURL("candidate-cold.wav"), options: .atomic)
            try Self.wavData(repeatAudio).write(to: Self.receiptURL("candidate-warm.wav"), options: .atomic)
            try repeatAudio.samples.withUnsafeBytes { try Data($0).write(to: Self.receiptURL("candidate-warm.f32"), options: .atomic) }
            receipt["experimentalModelIdentity"] = experimentalIdentity
            receipt["experimentalSingleFunctionRoles"] = CommandLine.arguments.filter { $0.hasPrefix("--validation-single-function=") }
            receipt["referenceConditioningCacheReset"] = CommandLine.arguments.contains("--reset-reference-conditioning")
            if let url = Bundle.main.url(forResource: "validation-build-source", withExtension: "json", subdirectory: "GeneratedAssets"),
               let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] {
                receipt["signedHostBuildSourceCommit"] = value["sourceCommit"]
                guard value["sourceCommit"] as? String == fixture.sourceCommit else { throw SmokeError("installed binary source binding mismatch") }
            }
            receipt["sampledPeakPhysicalFootprintBytes"] = benchmarkPeakFootprint
            receipt["memoryMeasurement"] = "task_info phys_footprint sampled at 1Hz; not exact transient peak"
            receipt["thermalPeak"] = Self.thermalName(benchmarkThermalPeak)
            receipt["requestedComputePlacementByRole"] = Self.requestedPlacements()
            receipt["residencyEvidence"] = "requested placement only, residency not proven"
            receipt["processID"] = ProcessInfo.processInfo.processIdentifier
            receipt["coldLane"] = CommandLine.arguments.first { $0.hasPrefix("--validation-cold-lane=") }.map { String($0.split(separator:"=").last!) } ?? "UNSPECIFIED_LEGACY"
            receipt["persistentRuntime"] = try JSONSerialization.jsonObject(with: Data(await engine.persistentRuntimeSnapshotJSON().utf8))
            receipt["sameProcessWarmLane"] = "IN_PROCESS_WARM"
            let url = try Self.receiptURL("candidate-benchmark-receipt.json"); receiptJSON = try Self.write(receipt, to: url)
            if !automatedNoPlayback { try play(repeatAudio) }
            status = String(format:"PASS Candidate first=%.3fs RTF=%.3f repeat=%.3fs RTF=%.3f receipt=%@",firstMilliseconds/1000,firstMilliseconds/1000/firstDuration,repeatMilliseconds/1000,repeatMilliseconds/1000/repeatDuration,url.path)
            if CommandLine.arguments.contains("--validation-persistent-idle") {
                persistentIdleEngine = engine
                resumePersistentIdleIfEnabled()
            }
        } catch { Self.recordFailure(error, filename:"candidate-benchmark-receipt.json", into:self) }
    }

    func runPersistentIdleBootstrap() async {
        guard !running else { return }; running = true; defer { running = false }
        let filename = "persistent-bootstrap-receipt.json"
        do {
            let waitStarted = Date()
            while ProcessInfo.processInfo.thermalState != .nominal && Date().timeIntervalSince(waitStarted) < 300 {
                _ = try Self.write(["status":"RUNNING","phase":"THERMAL_START_GATE","recordedAtUnix":Int(Date().timeIntervalSince1970)],to:Self.receiptURL(filename))
                try await Task.sleep(for: .seconds(5))
            }
            guard ProcessInfo.processInfo.thermalState == .nominal else { throw SmokeError("idle bootstrap nominal start gate not reached") }
            let reset = try Self.resetValidationCosyVoiceCachesIfRequested()
            let fixture = try Self.fixture()
            let engine = try CosyVoice3Engine(assetRoot:fixture.runtime,idleBucketPreparation:false)
            await engine.setValidationSamplerSeed(42)
            await engine.setValidationProgressObserver { print("[PERSISTENT-BOOTSTRAP] \($0)") }
            let clock = ContinuousClock(); let started = clock.now
            let pcm = try await engine.synthesize(fixture.text,parameters:fixture.parameters)
            let elapsed = Self.seconds(started.duration(to:clock.now))*1000
            try Self.validate(pcm)
            let snapshot = try JSONSerialization.jsonObject(with:Data(await engine.persistentRuntimeSnapshotJSON().utf8))
            let receipt: [String:Any] = ["status":"PASS_PUBLIC_FIRST_SYNTHESIS_IDLE_QUEUED","recordedAtUnix":Int(Date().timeIntervalSince1970),
                "sourceCommit":fixture.sourceCommit,"processID":ProcessInfo.processInfo.processIdentifier,"cacheReset":reset,
                "publicAPI":"CosyVoice3Engine.synthesize()","text":fixture.text,"seed":42,"flowSteps":6,
                "samples":pcm.samples.count,"sampleRate":pcm.sampleRate,"firstSynthesisMilliseconds":elapsed,
                "firstRTF":elapsed/1000/Self.audioDuration(pcm),"Float32PCMSHA256":SHA256.hash(data:pcm.samples.withUnsafeBytes { Data($0) }).map { String(format:"%02x",$0) }.joined(),
                "PCMReturnedToHostBeforeIdle":true,"secondSynthesisPerformed":false,"sameProcessWarmRTF":NSNull(),
                "thermalStart":"nominal","thermalEnd":Self.thermalName(ProcessInfo.processInfo.thermalState),"persistentBeforeIdle":snapshot,
                "backgroundModel":"foreground idle + finite beginBackgroundTask window; thermal nominal start only"]
            _ = try Self.write(receipt,to:Self.receiptURL(filename))
            persistentIdleEngine = engine
            resumePersistentIdleIfEnabled()
            status = "PASS first PCM returned; idle bucket preparation pending"
        } catch { Self.recordFailure(error,filename:filename,into:self) }
    }

    func runFlowStepHeadToHead() async {
        guard !running else { return }
        running = true
        status = "RUNNING Flow 10 / 8 / 6 head-to-head..."
        receiptJSON = ""
        availableFlowSteps = []
        flowStepAudios = [:]
        defer { running = false }

        for name in [
            "flow-steps-head-to-head-receipt.json",
            "flow-steps-10.wav",
            "flow-steps-8.wav",
            "flow-steps-6.wav"
        ] {
            if let stale = try? Self.receiptURL(name) { try? FileManager.default.removeItem(at: stale) }
        }

        do {
            let fixture = try Self.fixture()
            let engine = try CosyVoice3Engine(assetRoot: fixture.runtime)
            let report = try await engine.synthesizeFlowStepHeadToHead(
                fixture.text,
                parameters: fixture.parameters,
                flowSteps: [10,8,6]
            )

            var variants: [[String: Any]] = []
            var generated: [Int: CosyVoice3Audio] = [:]
            for result in report.variants {
                try Self.validate(result.audio)
                let stats = Self.stats(result.audio)
                let wav = Self.wavData(result.audio)
                let filename = "flow-steps-\(result.flowSteps).wav"
                let wavURL = try Self.receiptURL(filename)
                try wav.write(to: wavURL, options: .atomic)
                let wavSHA256 = SHA256.hash(data: wav).map { String(format:"%02x",$0) }.joined()
                generated[result.flowSteps] = result.audio
                let steadyComputeMilliseconds = report.llmGenerationMilliseconds + result.synthesisMilliseconds
                let steadyComputeRTF = steadyComputeMilliseconds / 1000 / result.audioSeconds
                variants.append([
                    "flowSteps": result.flowSteps,
                    "acousticSynthesisMilliseconds": result.synthesisMilliseconds,
                    "audioSeconds": result.audioSeconds,
                    "acousticRTF": result.rtf,
                    "steadyComputeMilliseconds": steadyComputeMilliseconds,
                    "steadyComputeRTF": steadyComputeRTF,
                    "samples": result.audio.samples.count,
                    "sampleRate": result.audio.sampleRate,
                    "channels": result.audio.channels,
                    "peakAbs": stats.peak,
                    "rms": stats.rms,
                    "wavFilename": filename,
                    "wavSha256": wavSHA256
                ])
            }
            guard Set(generated.keys) == Set([10,8,6]) else {
                throw SmokeError("head-to-head did not produce all 10/8/6 variants")
            }

            flowStepAudios = generated
            availableFlowSteps = Set(generated.keys)
            let receipt: [String: Any] = [
                "schemaVersion": 1,
                "status": "PASS_FLOW_STEPS_HEAD_TO_HEAD",
                "benchmark": "flow-steps-head-to-head-v1",
                "sourceCommit": fixture.sourceCommit,
                "recordedAtUnix": Int(Date().timeIntervalSince1970),
                "device": UIDevice.current.model,
                "deviceModelIdentifier": Self.machineIdentifier(),
                "systemName": UIDevice.current.systemName,
                "systemVersion": UIDevice.current.systemVersion,
                "hostReceiptSha256": fixture.hostReceiptSHA256,
                "referenceTranscriptCharacters": fixture.transcript.count,
                "productionDefaultFlowSteps": CosyVoice3FlowSteps.productionDefault.rawValue,
                "measuredFlowSteps": report.flowSteps,
                "warmupFlowSteps": report.warmupFlowSteps,
                "warmupMilliseconds": report.warmupMilliseconds,
                "speechTokenSha256": report.speechTokenSHA256,
                "sameSpeechTokensAcrossVariants": true,
                "sameReferenceConditioningAcrossVariants": true,
                "sameInitialNoiseAcrossVariants": true,
                "sameAcousticModelInstancesAcrossVariants": true,
                "timingDefinition": "acoustic synthesis only; shared model loading excluded; one 10-step acoustic warm-up precedes measured 10/8/6 variants",
                "sharedPreparationMilliseconds": report.preparationMilliseconds,
                "sharedFrontendMilliseconds": report.frontendMilliseconds,
                "sharedLLMModelLoadMilliseconds": report.llmModelLoadMilliseconds,
                "sharedLLMGenerationMilliseconds": report.llmGenerationMilliseconds,
                "sharedAcousticModelLoadMilliseconds": report.acousticModelLoadMilliseconds,
                "variants": variants
            ]
            let receiptURL = try Self.receiptURL("flow-steps-head-to-head-receipt.json")
            receiptJSON = try Self.write(receipt, to: receiptURL)

            let bySteps = Dictionary(uniqueKeysWithValues: report.variants.map { ($0.flowSteps, $0) })
            status = String(
                format: "PASS Flow H2H 10=%.3fs computeRTF=%.3f 8=%.3fs computeRTF=%.3f 6=%.3fs computeRTF=%.3f",
                (bySteps[10]?.synthesisMilliseconds ?? 0) / 1000,
                ((report.llmGenerationMilliseconds + (bySteps[10]?.synthesisMilliseconds ?? 0)) / 1000 / (bySteps[10]?.audioSeconds ?? 9)),
                (bySteps[8]?.synthesisMilliseconds ?? 0) / 1000,
                ((report.llmGenerationMilliseconds + (bySteps[8]?.synthesisMilliseconds ?? 0)) / 1000 / (bySteps[8]?.audioSeconds ?? 9)),
                (bySteps[6]?.synthesisMilliseconds ?? 0) / 1000,
                ((report.llmGenerationMilliseconds + (bySteps[6]?.synthesisMilliseconds ?? 0)) / 1000 / (bySteps[6]?.audioSeconds ?? 9))
            )
            if let productionDefault = generated[CosyVoice3FlowSteps.productionDefault.rawValue] { try play(productionDefault) }
        } catch {
            Self.recordFailure(error, filename:"flow-steps-head-to-head-receipt.json", into:self)
        }
    }

    func playFlowStep(_ steps: Int) {
        guard let audio = flowStepAudios[steps] else { return }
        do {
            try play(audio)
            status = "PLAYING Flow \(steps) steps"
        } catch {
            status = "FAIL playback Flow \(steps): \(String(describing:error))"
        }
    }

    private struct ShapeFamily {
        let minimum: Int
        let maximum: Int
        let functionName: String
        func contains(_ n: Int) -> Bool { n >= minimum && n <= maximum }
    }

    private struct ActiveManifestInfo {
        let url: URL
        let profile: String
        let schemaVersion: Int
    }

    private struct VariableManifestInfo {
        let profile: String
        let schemaVersion: Int
        let acousticShapeMode: String
        let speechTokenMinimum: Int
        let speechTokenMaximum: Int
        let families: [ShapeFamily]

        func functionName(for n: Int) -> String? {
            families.first(where: { $0.contains(n) })?.functionName
        }
    }

    private static func activeManifest(runtime: URL) throws -> ActiveManifestInfo {
        for name in ["cosyvoice3_enumerated.json","cosyvoice3_dynamic.json","cosyvoice3_fixed225.json"] {
            let url = runtime.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  let profile = value["profile"] as? String,
                  let schema = value["schemaVersion"] as? Int else {
                throw SmokeError("active manifest identity missing")
            }
            return ActiveManifestInfo(url: url, profile: profile, schemaVersion: schema)
        }
        throw SmokeError("no supported CosyVoice3 manifest")
    }

    private static func variableManifestInfo(runtime: URL) throws -> VariableManifestInfo {
        let active = try activeManifest(runtime: runtime)
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: active.url)) as? [String: Any]
        let key: String
        let mode: String
        if active.schemaVersion == 3 {
            key = "enumeratedAcoustic"
            mode = "ENUMERATED_EXACT"
        } else if active.schemaVersion == 2 {
            key = "dynamicAcoustic"
            mode = "RANGEDIM"
        } else {
            throw SmokeError("active profile is fixed-length, not variable")
        }
        guard let contract = value?[key] as? [String: Any],
              let nmin = contract["speechTokenMinimum"] as? Int,
              let nmax = contract["speechTokenMaximum"] as? Int else {
            throw SmokeError("variable manifest contract missing")
        }
        var families: [ShapeFamily] = []
        if active.schemaVersion == 3 {
            guard let rows = contract["families"] as? [[String: Any]] else {
                throw SmokeError("enumerated family list missing")
            }
            for row in rows {
                guard let lo = row["speechTokenMinimum"] as? Int,
                      let hi = row["speechTokenMaximum"] as? Int,
                      let function = row["functionName"] as? String else {
                    throw SmokeError("enumerated family entry invalid")
                }
                families.append(ShapeFamily(minimum: lo, maximum: hi, functionName: function))
            }
        }
        return VariableManifestInfo(
            profile: active.profile,
            schemaVersion: active.schemaVersion,
            acousticShapeMode: mode,
            speechTokenMinimum: nmin,
            speechTokenMaximum: nmax,
            families: families
        )
    }

    private struct Fixture {
        let runtime: URL
        let reference: CosyVoice3VoiceReference
        let transcript: String
        let hostReceiptSHA256: String
        let sourceCommit: String
        let payloadTreeSHA256: String?
        let exportReceiptSHA256: String?
        let assetExportSourceCommit: String?
        let text: String
        let parameters: CosyVoice3Parameters
    }

    private static func fixture() throws -> Fixture {
        let resources = try generatedAssets(); let runtime = resources.appendingPathComponent("Runtime", isDirectory:true); let wav = resources.appendingPathComponent("reference.wav"); let transcript = try String(contentsOf:resources.appendingPathComponent("reference.txt"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        let reference = CosyVoice3VoiceReference(audioURL:wav,transcript:transcript)
        let candidateMarker=resources.appendingPathComponent("candidate-benchmark-mode.json")
        let flowMarker=resources.appendingPathComponent("flow-step-head-to-head-mode.json")
        let variableMarker=resources.appendingPathComponent("variable-public-api-smoke-mode.json")
        let dynamicMarker=resources.appendingPathComponent("dynamic-public-api-smoke-mode.json")
        let variableBinding = FileManager.default.fileExists(atPath:variableMarker.path) ? variableMarker : (FileManager.default.fileExists(atPath:dynamicMarker.path) ? dynamicMarker : nil)
        let marker:URL? = variableBinding ?? (FileManager.default.fileExists(atPath:flowMarker.path) ? flowMarker : (FileManager.default.fileExists(atPath:candidateMarker.path) ? candidateMarker : nil))
        let hostSHA:String; let sourceCommit:String
        var payloadTreeSHA256:String?
        var exportReceiptSHA256:String?
        var assetExportSourceCommit:String?
        if let marker {
            let value=try JSONSerialization.jsonObject(with:Data(contentsOf:marker)) as? [String:Any]
            let hostBound = value?["hostReceiptSha256"] as? String
            let immutableBound = value?["immutableManifestSha256"] as? String
            guard hostBound?.count == 64 || immutableBound?.count == 64 else { throw SmokeError("validation marker host/immutable binding missing") }
            let bound = hostBound ?? ""
            guard let commit=value?["sourceCommit"] as? String, commit.range(of:"^[0-9a-f]{40}$",options:.regularExpression) != nil else { throw SmokeError("validation marker sourceCommit missing") }
            hostSHA=bound
            sourceCommit=commit
            payloadTreeSHA256=value?["payloadTreeSha256"] as? String
            exportReceiptSHA256=value?["exportReceiptSha256"] as? String
            assetExportSourceCommit=value?["assetExportSourceCommit"] as? String
        } else {
            let hostData=try Data(contentsOf:resources.appendingPathComponent("reference_host_parity_receipt.json"))
            hostSHA=SHA256.hash(data:hostData).map{String(format:"%02x",$0)}.joined()
            sourceCommit="unbound-noncandidate-smoke"
        }
        let textOption = CommandLine.arguments.first { $0.hasPrefix("--validation-workload-text=") }
        let text = textOption.map { String($0.dropFirst("--validation-workload-text=".count)) } ?? "This is a CosyVoice3 public API reference voice validation."
        return Fixture(runtime:runtime,reference:reference,transcript:transcript,hostReceiptSHA256:hostSHA,sourceCommit:sourceCommit,payloadTreeSHA256:payloadTreeSHA256,exportReceiptSHA256:exportReceiptSHA256,assetExportSourceCommit:assetExportSourceCommit,text:text,parameters:CosyVoice3Parameters(reference:reference,instruction:"You are a helpful assistant.<|endofprompt|>"+transcript))
    }

    private static func generatedAssets() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let staged = documents.appendingPathComponent("GeneratedAssets", isDirectory: true)
        if FileManager.default.fileExists(atPath: staged.appendingPathComponent("staging-complete.json").path) {
            let marker = try Data(contentsOf: staged.appendingPathComponent("staging-complete.json"))
            guard let value = try JSONSerialization.jsonObject(with: marker) as? [String: Any] else {
                throw SmokeError("staged identity marker is invalid")
            }
            if let expected = value["immutableManifestSha256"] as? String {
                let manifestData = try Data(contentsOf: staged.appendingPathComponent("Runtime/asset-manifest.json"))
                let actual = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { throw SmokeError("staged immutable manifest identity mismatch") }
            } else {
                guard let name = value["runtimeManifestName"] as? String,
                      let expected = value["runtimeManifestSha256"] as? String,
                      name == "cosyvoice3_enumerated.json" else {
                    throw SmokeError("staged local enumerated identity missing")
                }
                let runtime = staged.appendingPathComponent("Runtime", isDirectory: true)
                let manifestData = try Data(contentsOf: runtime.appendingPathComponent(name))
                let actual = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { throw SmokeError("staged local enumerated manifest identity mismatch") }
                guard let expectedExport = value["exportReceiptSha256"] as? String,
                      let expectedTree = value["payloadTreeSha256"] as? String,
                      let expectedAssetSource = value["assetExportSourceCommit"] as? String else {
                    throw SmokeError("staged local enumerated payload identity missing")
                }
                let exportURL = runtime.appendingPathComponent("enumerated-production-export-receipt.json")
                let exportData = try Data(contentsOf: exportURL)
                let actualExport = SHA256.hash(data: exportData).map { String(format: "%02x", $0) }.joined()
                guard actualExport == expectedExport else { throw SmokeError("staged local enumerated export receipt identity mismatch") }
                guard let exportReceipt = try JSONSerialization.jsonObject(with: exportData) as? [String: Any],
                      exportReceipt["payloadTreeSha256"] as? String == expectedTree,
                      exportReceipt["sourceCommit"] as? String == expectedAssetSource else {
                    throw SmokeError("staged local enumerated payload/source binding mismatch")
                }
            }
            return staged
        }
        guard let resourceRoot = Bundle.main.resourceURL else { throw SmokeError("bundle resource root unavailable") }
        let root = resourceRoot.appendingPathComponent("GeneratedAssets",isDirectory:true); var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath:root.path,isDirectory:&isDirectory), isDirectory.boolValue else { throw SmokeError("GeneratedAssets missing; run validation/prepare_device_smoke_assets.py") }
        return root
    }

    private static func receiptURL(_ name: String) throws -> URL { try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent(name) }
    private static func write(_ receipt: [String: Any], to url: URL) throws -> String { let data=try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]); try data.write(to:url,options:.atomic); return String(decoding:data,as:UTF8.self) }
    private static func recordFailure(_ error: Error, filename: String, into model: CosyVoice3SmokeModel) {
        var receipt:[String:Any]=["schemaVersion":1,"status":"FAIL","recordedAtUnix":Int(Date().timeIntervalSince1970),"error":String(describing:error),"device":UIDevice.current.model,"deviceModelIdentifier":machineIdentifier(),"systemVersion":UIDevice.current.systemVersion]
        if let sourceCommit = validationSourceCommit() { receipt["sourceCommit"] = sourceCommit }
        receipt["requestedAcousticPlacement"] = requestedAcousticPlacement()
        receipt["requestedComputePlacementByRole"] = requestedPlacements()
        receipt["residencyEvidence"] = "requested placement only, residency not proven"
        if let data=try? JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]) { if let url=try? receiptURL(filename) { try? data.write(to:url,options:.atomic) }; model.receiptJSON=String(decoding:data,as:UTF8.self) }
        model.status="FAIL \(String(describing:error))"
    }

    func runANEStatefulParity() async {
        guard !running else { return }; running = true; defer { running = false }
        let filename = "ane-llm-parity-receipt.json"
        do {
            let fixture = try Self.fixture()
            let cache = CosyVoice3CompiledModelCache()
            let prefillURL = try cache.compiledURL(for: fixture.runtime.appendingPathComponent("models/llm-opt-perlayer-prefill.mlpackage"))
            let decodeURL = try cache.compiledURL(for: fixture.runtime.appendingPathComponent("models/llm-opt-perlayer-decode-maskwrite512.mlpackage"))
            defer { try? FileManager.default.removeItem(at: prefillURL); try? FileManager.default.removeItem(at: decodeURL) }
            let textEmbeddings = try Data(contentsOf: fixture.runtime.appendingPathComponent("embeddings/text_embedding_fp16.bin"), options: .mappedIfSafe)
            let speechEmbeddings = try Data(contentsOf: fixture.runtime.appendingPathComponent("embeddings/speech_embedding_fp16.bin"), options: .mappedIfSafe)
            func array(_ shape: [Int]) throws -> MLMultiArray {
                let a = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float16)
                memset(a.dataPointer, 0, a.count*2); return a
            }
            func rope(_ position: Int) -> (Data, Data) {
                var c = [UInt16](repeating: 0, count: 64); var t = c
                for i in 0..<32 {
                    let angle = Double(position) / pow(1_000_000.0, Double(2*i)/64.0)
                    c[i] = Float16(cos(angle)).bitPattern; c[i+32] = c[i]
                    t[i] = Float16(sin(angle)).bitPattern; t[i+32] = t[i]
                }
                return (c.withUnsafeBytes { Data($0) }, t.withUnsafeBytes { Data($0) })
            }
            let x = try array([1,224,896]), c = try array([1,1,224,64]), t = try array([1,1,224,64]), mask = try array([1,1,224,224])
            for position in 0..<224 {
                if position < 54 {
                    let token = (position*997)%151936; let data = textEmbeddings.subdata(in: token*1792..<(token+1)*1792)
                    data.withUnsafeBytes { memcpy(x.dataPointer.advanced(by: position*1792), $0.baseAddress!, 1792) }
                }
                let r = rope(position)
                r.0.withUnsafeBytes { memcpy(c.dataPointer.advanced(by: position*128), $0.baseAddress!, 128) }
                r.1.withUnsafeBytes { memcpy(t.dataPointer.advanced(by: position*128), $0.baseAddress!, 128) }
                for j in 0..<224 { mask.dataPointer.assumingMemoryBound(to: UInt16.self)[position*224+j] = j <= position && j < 54 ? 0 : 0xfc00 }
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["x":x,"cos":c,"sin":t,"mask":mask])
            func run(_ prefillUnits: MLComputeUnits, _ decodeUnits: MLComputeUnits) throws -> [[Float]] {
                try autoreleasepool {
                    let pc = MLModelConfiguration(); pc.computeUnits = prefillUnits
                    let dc = MLModelConfiguration(); dc.computeUnits = decodeUnits
                    let prefill = try MLModel(contentsOf: prefillURL, configuration: pc)
                    let decode = try MLModel(contentsOf: decodeURL, configuration: dc)
                    let session = try CosyVoice3FP16StatefulLLMSession(prefillModel: prefill, decodeModel: decode, diagnosticHostWriteMask: true, logicalPrefixLength: 54)
                    var logits = [[Float]]()
                    func values(_ result: MLFeatureProvider) throws -> [Float] {
                        guard let a = result.featureValue(for: "logits")?.multiArrayValue else { throw SmokeError("logits missing") }
                        let count = 6761; let offset = 0
                        guard a.count >= offset+count else { throw SmokeError("logits ABI mismatch") }
                        return (0..<count).map { a[offset+$0].floatValue }
                    }
                    logits.append(try values(session.prefill(provider)))
                    for step in 0..<260 {
                        let token = (step*37)%6561; let embedding = speechEmbeddings.subdata(in: token*1792..<(token+1)*1792); let r = rope(54+step)
                        let result = try session.decode(embedding: embedding, cos: r.0, sin: r.1, absolutePosition: 54+step)
                        logits.append(try values(result))
                    }
                    return logits
                }
            }
            let control = try run(.cpuOnly, .cpuOnly)
            var rows = [[String: Any]]()
            for (name,prefill,decode) in [("prefill-ne",MLComputeUnits.cpuAndNeuralEngine,MLComputeUnits.cpuOnly),("decode-ne",MLComputeUnits.cpuOnly,MLComputeUnits.cpuAndNeuralEngine),("full-llm-ne",MLComputeUnits.cpuAndNeuralEngine,MLComputeUnits.cpuAndNeuralEngine)] {
                do {
                    let candidate = try run(prefill,decode)
                    var maxAbs = 0.0; var squaredError = 0.0; var squaredControl = 0.0; var finite = true; var top1Agreement = 0
                    for (a,b) in zip(control,candidate) {
                        let ai = a.indices.max(by: { a[$0] < a[$1] }); let bi = b.indices.max(by: { b[$0] < b[$1] })
                        if ai == bi { top1Agreement += 1 }
                        for (u,v) in zip(a,b) { let delta = Double(u)-Double(v); finite = finite && u.isFinite && v.isFinite; maxAbs = max(maxAbs,abs(delta)); squaredError += delta*delta; squaredControl += Double(u)*Double(u) }
                    }
                    rows.append(["variant":name,"status":finite ? "FINITE_NUMERICAL_DIAGNOSTIC" : "FAIL_NONFINITE","maxAbs":maxAbs,"relativeL2":sqrt(squaredError/max(squaredControl,1e-30)),"top1Agreement":top1Agreement,"logitSteps":control.count,"strictMaxAbs005Pass":finite && maxAbs <= 0.005])
                } catch { rows.append(["variant":name,"status":"FAIL","error":String(describing:error)]) }
            }
            let receipt: [String: Any] = ["schemaVersion":1,"status":"PASS_DIAGNOSTIC_COLLECTION","recordedAtUnix":Int(Date().timeIntervalSince1970),"sourceCommit":fixture.sourceCommit,"payloadTreeSha256":fixture.payloadTreeSHA256 ?? "","deviceModelIdentifier":Self.machineIdentifier(),"systemVersion":UIDevice.current.systemVersion,"logicalPrefix":54,"physicalPrefill":224,"decodeSteps":260,"fixture":"deterministic actual embedding rows + native RoPE, common teacher forcing; synthetic prompt, no sampler; not speech quality or endpoint parity","models":rows,"productionPromotion":false]
            _ = try Self.write(receipt, to: Self.receiptURL(filename)); status = "PASS numerical diagnostic collection"
        } catch { Self.recordFailure(error, filename:filename, into:self) }
    }

    func runIsolatedRequest() async {
        guard !running else { return }; running = true; defer { running = false }
        let filename = "isolated-request-receipt.json"
        do {
            let fixture = try Self.fixture()
            let selected = CommandLine.arguments.filter { $0.hasPrefix("--validation-isolated-stage=") }
            guard selected.count == 1, ["llm","flow","hift"].contains(String(selected[0].dropFirst("--validation-isolated-stage=".count))) else { throw SmokeError("one isolated stage required") }
            let started = Date()
            while ProcessInfo.processInfo.thermalState != .nominal && Date().timeIntervalSince(started) < 300 { try await Task.sleep(for: .seconds(5)) }
            guard ProcessInfo.processInfo.thermalState == .nominal else { throw SmokeError("nominal start gate not reached") }
            let engine = try CosyVoice3Engine(assetRoot: fixture.runtime, idleBucketPreparation: false)
            await engine.setValidationSamplerSeed(42)
            let audio = try await engine.synthesize(fixture.text, parameters: fixture.parameters)
            try Self.validate(audio)
            let raw = audio.samples.withUnsafeBytes { Data($0) }
            try raw.write(to:Self.receiptURL("isolated-output.f32"),options:.atomic)
            let persistent = try JSONSerialization.jsonObject(with:Data((await engine.persistentRuntimeSnapshotJSON()).utf8))
            let receipt: [String: Any] = ["persistentRuntime":persistent,"schemaVersion":1,"status":"PASS_DIAGNOSTIC_REQUEST","sourceCommit":fixture.sourceCommit,
                "processID":ProcessInfo.processInfo.processIdentifier,"deviceModelIdentifier":Self.machineIdentifier(),"systemVersion":UIDevice.current.systemVersion,
                "assetPayloadTreeSha256":fixture.payloadTreeSHA256 ?? "","manifestSha256":SHA256.hash(data:try Data(contentsOf:fixture.runtime.appendingPathComponent("cosyvoice3_enumerated.json"))).map { String(format:"%02x",$0) }.joined(),
                "textSha256":SHA256.hash(data:Data(fixture.text.utf8)).map { String(format:"%02x",$0) }.joined(),
                "referenceWavSha256":SHA256.hash(data:try Data(contentsOf:fixture.reference.audioURL)).map { String(format:"%02x",$0) }.joined(),
                "effectiveTranscriptSha256":SHA256.hash(data:Data(fixture.transcript.utf8)).map { String(format:"%02x",$0) }.joined(),
                "seed":42,"flowSteps":fixture.parameters.flowSteps.rawValue,"samples":audio.samples.count,"sampleRate":audio.sampleRate,
                "Float32PCMSha256":SHA256.hash(data:raw).map { String(format:"%02x",$0) }.joined(),"arguments":CommandLine.arguments,
                "scope":"expanded isolated-stage diagnostic; full elapsed time excluded from production RTF","productionPromotion":false]
            _ = try Self.write(receipt,to:Self.receiptURL(filename)); status = "PASS isolated request"
        } catch { Self.recordFailure(error,filename:filename,into:self) }
        print("[COSY-DIAGNOSTIC-DONE] \(filename)")
    }

    func runANEComputePlans() async {
        guard !running else { return }; running = true; defer { running = false }
        let filename = "ane-compute-plan-receipt.json"
        var rows = [[String: Any]]()
        do {
            let fixture = try Self.fixture()
            let paths = ["llmPrefill": "models/llm-opt-perlayer-prefill.mlpackage", "llmDecode": "models/llm-opt-perlayer-decode-maskwrite512.mlpackage", "conditions": "enumerated-acoustic/conditions.mlpackage", "hift": "enumerated-acoustic/hift.mlpackage", "speechTokenizer": "reference/speech-tokenizer-fixed605.mlpackage", "campPlus": "reference/campplus-fixed604.mlpackage"]
            let selected = CommandLine.arguments.filter { $0.hasPrefix("--validation-plan-role=") }.map { String($0.dropFirst("--validation-plan-role=".count)) }
            let roles = selected.isEmpty ? ["llmPrefill", "llmDecode", "conditions", "flow0", "flow1", "flow2", "flow3", "flow4", "flow5", "hift", "speechTokenizer", "campPlus"] : selected
            func save(_ status: String) throws {
                var receipt: [String: Any] = ["schemaVersion": 1, "status": status, "sourceCommit": fixture.sourceCommit, "recordedAtUnix": Int(Date().timeIntervalSince1970), "deviceModelIdentifier": Self.machineIdentifier(), "systemVersion": UIDevice.current.systemVersion, "models": rows, "meaning": "MLComputePlan preferred/supported devices; not measured runtime residency"]
                receipt["payloadTreeSha256"] = fixture.payloadTreeSHA256
                _ = try Self.write(receipt, to: Self.receiptURL(filename))
            }
            for role in roles {
                let relative = paths[role] ?? (role.hasPrefix("flow") ? "enumerated-acoustic/flow-shard-\(role.dropFirst(4)).mlpackage" : "")
                guard !relative.isEmpty else { throw SmokeError("unknown plan role \(role)") }
                let single = CommandLine.arguments.contains("--validation-single-function=\(role)")
                let partition = CommandLine.arguments.first { $0.hasPrefix("--validation-flow-partition=") }.flatMap { Int($0.dropFirst("--validation-flow-partition=".count)) } ?? 6
                let planFolderOption = CommandLine.arguments.first { $0.hasPrefix("--validation-plan-directory=") }.map { String($0.dropFirst("--validation-plan-directory=".count)) }
                if let option = planFolderOption { guard single && ["ANEFlowP2","ANEFlowP3"].contains(option) else { throw SmokeError("invalid isolated plan directory") } }
                let source: URL
                if single, let option = planFolderOption { source = fixture.runtime.deletingLastPathComponent().appendingPathComponent("\(option)/\(role).mlpackage") }
                else if single { source = fixture.runtime.deletingLastPathComponent().appendingPathComponent("\(CommandLine.arguments.contains("--validation-static-n260") ? "ANEStaticN260" : "ANEExperimental")/\(role).mlpackage") }
                else if role.hasPrefix("flow"), partition != 6, let index = Int(role.dropFirst(4)), index < partition {
                    source = fixture.runtime.deletingLastPathComponent().appendingPathComponent("FlowPartitions/p\(partition)/group-\(index).mlpackage")
                } else { source = fixture.runtime.appendingPathComponent(relative) }
                var row: [String: Any] = ["role": role, "path": source.path, "singleFunction": single, "requestedPlacement": Self.requestedRolePlacement(role, defaultValue: "CPU_AND_NE"), "stage": "compile", "status": "RUNNING"]
                rows.append(row); try save("RUNNING")
                do {
                    let compiled = try await MLModel.compileModel(at: source)
                    defer { try? FileManager.default.removeItem(at: compiled) }
                    let config = MLModelConfiguration()
                    let policy = Self.requestedRolePlacement(role, defaultValue: "CPU_AND_NE")
                    switch policy {
                    case "CPU_ONLY": config.computeUnits = .cpuOnly
                    case "CPU_AND_GPU": config.computeUnits = .cpuAndGPU
                    case "CPU_AND_NE": config.computeUnits = .cpuAndNeuralEngine
                    default: throw SmokeError("invalid compute policy \(policy)")
                    }
                    config.functionName = relative.hasPrefix("enumerated-acoustic/") && !single ? "n257_384" : nil
                    row["stage"] = "model-load"; rows[rows.count-1] = row; try save("RUNNING")
                    try autoreleasepool { _ = try MLModel(contentsOf: compiled, configuration: config) }
                    row["modelLoadStatus"] = "PASS"
                    row["stage"] = "compute-plan"; rows[rows.count-1] = row; try save("RUNNING")
                    let plan = try await MLComputePlan.load(contentsOf: compiled, configuration: config)
                    var costs = [String: Double](); var counts = [String: Int](); var operations = [[String: Any]]()
                    if case let .program(program) = plan.modelStructure {
                        func visit(_ block: MLModelStructure.Program.Block) {
                            for op in block.operations {
                                if let usage = plan.deviceUsage(for: op) {
                                    counts[usage.preferred.description, default: 0] += 1
                                    let cost = plan.estimatedCost(of: op)?.weight ?? 0
                                    costs[usage.preferred.description, default: 0] += cost
                                    operations.append(["operator": op.operatorName, "outputs":op.outputs.map { $0.name }, "inputs":op.inputs.mapValues { $0.bindings.map { binding in switch binding { case .name(let name): return name; case .value: return "<compile-time constant>"; @unknown default: return "<unknown binding>" } } }, "estimatedCostWeight": cost, "preferred": usage.preferred.description, "supported": usage.supported.map { $0.description }])
                                }
                                for child in op.blocks { visit(child) }
                            }
                        }
                        if let selected = program.functions[config.functionName ?? "main"] { visit(selected.block) }
                        else { for function in program.functions.values { visit(function.block) } }
                    }
                    row["estimatedCostByPreferredDevice"] = costs
                    row["preferredCounts"] = counts; row["operations"] = operations; row["status"] = "PASS_COMPUTE_PLAN"
                    print("[ANE-COMPUTE-PLAN] role=\(role) single=\(single) counts=\(counts)")
                } catch {
                    let error = error as NSError
                    row["status"] = "FAIL_COMPUTE_PLAN"; row["error"] = ["domain": error.domain, "code": error.code, "description": error.localizedDescription, "userInfo": String(describing: error.userInfo)]
                }
                rows[rows.count-1] = row; try save("RUNNING")
            }
            try save("PASS_DIAGNOSTIC_COLLECTION"); status = "PASS diagnostic compute-plan collection"
            print("[COSY-DIAGNOSTIC-DONE] ane-compute-plan-receipt.json")
        } catch { Self.recordFailure(error, filename: filename, into: self) }
    }

    private static func processCPUMilliseconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)*1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)/1000
    }

    private static func processFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func validateExperimentalModels(runtime: URL) throws -> [String: Any] {
        let partition = CommandLine.arguments.first(where: { $0.hasPrefix("--validation-flow-partition=") }).flatMap { Int($0.dropFirst("--validation-flow-partition=".count)) } ?? 6
        var partitionIdentity = [String: Any]()
        if partition != 6 {
            let folder = runtime.deletingLastPathComponent().appendingPathComponent("FlowPartitions")
            let data = try Data(contentsOf: folder.appendingPathComponent("partition-export-receipt.json"))
            guard let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any], let variants = receipt["variants"] as? [String: [String: Any]], let variant = variants[partition == 1 && CommandLine.arguments.contains("--validation-materialize-te") ? "1-te" : String(partition)], let packages = variant["packages"] as? [[String: Any]], packages.count == partition else { throw SmokeError("partition export receipt missing") }
            for (index,package) in packages.enumerated() {
                guard let identity = package["identity"] as? [String: Any], let files = identity["files"] as? [[String: Any]], package["weightBytesUnchanged"] as? Bool == true else { throw SmokeError("partition identity missing") }
                for file in files {
                    guard let path = file["path"] as? String, let bytes = file["bytes"] as? Int, let expected = file["sha256"] as? String else { throw SmokeError("partition file identity missing") }
                    let contents = try Data(contentsOf: folder.appendingPathComponent("\(partition == 1 && CommandLine.arguments.contains("--validation-materialize-te") ? "p1-te" : "p\(partition)")/group-\(index).mlpackage/\(path)"), options: .mappedIfSafe)
                    let actual = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
                    guard contents.count == bytes, actual == expected else { throw SmokeError("partition payload SHA mismatch") }
                }
                partitionIdentity["group\(index)"] = identity
            }
        }
        let roles = CommandLine.arguments.filter { $0.hasPrefix("--validation-single-function=") }.map { String($0.dropFirst("--validation-single-function=".count)) }
        if roles.isEmpty { return partitionIdentity }
        let folder = runtime.deletingLastPathComponent().appendingPathComponent(CommandLine.arguments.contains("--validation-static-n260") ? "ANEStaticN260" : "ANEExperimental")
        let exportData = try Data(contentsOf: folder.appendingPathComponent("export-receipt.json"))
        guard let receipt = try JSONSerialization.jsonObject(with: exportData) as? [String: Any], let models = receipt["models"] as? [String: [String: Any]] else { throw SmokeError("experimental export receipt missing") }
        var result = partitionIdentity
        for role in roles {
            guard let model = models[role], let identity = model["experimentalIdentity"] as? [String: Any], let files = identity["files"] as? [[String: Any]], (model["graphIdentical"] as? Bool == true || (model["operatorBlocksByteIdentical"] as? Bool == true && model["hostNumericalParityStatus"] as? String == "PASS")), model["weightsIdentical"] as? Bool == true else { throw SmokeError("single-function graph identity missing: \(role)") }
            for file in files {
                guard let path = file["path"] as? String, let bytes = file["bytes"] as? Int, let sha = file["sha256"] as? String else { throw SmokeError("experimental file identity missing") }
                let contents = try Data(contentsOf: folder.appendingPathComponent("\(role).mlpackage/\(path)"), options: .mappedIfSafe)
                let actual = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
                guard contents.count == bytes, actual == sha else { throw SmokeError("experimental payload SHA mismatch: \(role)/\(path)") }
            }
            result[role] = identity
        }
        return result
    }

    private static func requestedRolePlacement(_ role: String, defaultValue: String) -> String {
        let prefix = "--validation-placement=\(role):"
        return CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) } ?? defaultValue
    }
    private static func requestedPlacements() -> [String: String] {
        var result = [String: String]()
        for role in ["llmPrefill", "llmDecode", "conditions", "flow0", "flow1", "flow2", "flow3", "flow4", "flow5", "hift", "speechTokenizer", "campPlus"] {
            let acoustic = role == "conditions" || role == "hift" || role.hasPrefix("flow")
            let base = acoustic ? requestedAcousticPlacement().replacingOccurrences(of: "_VALIDATION_OVERRIDE", with: "") : (role.hasPrefix("llm") ? "CPU_AND_NE" : "CPU_ONLY")
            result[role] = requestedRolePlacement(role, defaultValue: base)
        }
        return result
    }

    private static func requestedAcousticPlacement() -> String {
        if CommandLine.arguments.contains("--validation-enumerated-cpu-gpu") { return "CPU_AND_GPU_VALIDATION_OVERRIDE" }
        if CommandLine.arguments.contains("--validation-enumerated-cpu-only") { return "CPU_ONLY_VALIDATION_OVERRIDE" }
        return "CPU_AND_GPU"
    }

    private static func validationSourceCommit() -> String? {
        guard let resources = try? generatedAssets() else { return nil }
        for name in ["variable-public-api-smoke-mode.json","dynamic-public-api-smoke-mode.json","flow-step-head-to-head-mode.json","candidate-benchmark-mode.json"] {
            let marker = resources.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: marker),
                  let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let commit = value["sourceCommit"] as? String,
                  commit.range(of:"^[0-9a-f]{40}$",options:.regularExpression) != nil else { continue }
            return commit
        }
        return nil
    }
    private static func reportDictionary(_ report: CosyVoice3SynthesisReport) -> [String: Any] {
        [
            "flowSteps": report.flowSteps.rawValue,
            "totalMilliseconds": report.totalMilliseconds,
            "preparationMilliseconds": report.preparationMilliseconds,
            "frontendMilliseconds": report.frontendMilliseconds,
            "llmModelLoadMilliseconds": report.llmModelLoadMilliseconds,
            "llmGenerationMilliseconds": report.llmGenerationMilliseconds,
            "acousticModelLoadMilliseconds": report.acousticModelLoadMilliseconds,
            "acousticSynthesisMilliseconds": report.acousticSynthesisMilliseconds,
            "modelPreparationCacheHit": report.modelPreparationCacheHit,
            "referenceCacheHit": report.referenceCacheHit,
            "warmedModelCount": report.warmedModelCount
        ]
    }
    private static func seconds(_ duration: Duration) -> Double { Double(duration.components.seconds)+Double(duration.components.attoseconds)/1e18 }
    private static func audioDuration(_ audio: CosyVoice3Audio) -> Double { Double(audio.samples.count)/Double(audio.sampleRate*audio.channels) }
    private static func stats(_ audio: CosyVoice3Audio) -> (peak: Float, rms: Double) { (audio.samples.reduce(Float.zero){max($0,abs($1))},sqrt(audio.samples.reduce(0.0){$0+Double($1*$1)}/Double(audio.samples.count))) }
    private static func machineIdentifier() -> String { var value=utsname(); uname(&value); let capacity=MemoryLayout.size(ofValue:value.machine); return withUnsafePointer(to:&value.machine){ $0.withMemoryRebound(to:CChar.self,capacity:capacity){ String(cString:$0) } } }

    private static func validate(_ audio: CosyVoice3Audio) throws {
        guard audio.sampleRate==24_000 else { throw SmokeError("unexpected sample rate \(audio.sampleRate)") }
        guard audio.channels==1 else { throw SmokeError("unexpected channel count \(audio.channels)") }
        guard !audio.samples.isEmpty else { throw SmokeError("empty PCM") }
        guard audio.samples.allSatisfy(\.isFinite) else { throw SmokeError("PCM contains NaN/Inf") }
        guard audio.samples.contains(where:{abs($0)>1e-6}) else { throw SmokeError("PCM is effectively silent") }
    }

    private func play(_ audio: CosyVoice3Audio) throws {
        let session=AVAudioSession.sharedInstance(); try session.setCategory(.playback,mode:.default); try session.setActive(true); let p=try AVAudioPlayer(data:Self.wavData(audio)); guard p.prepareToPlay(),p.play() else { throw SmokeError("playback could not start") }; player=p
    }

    private static func wavData(_ audio: CosyVoice3Audio) -> Data {
        let channels=UInt16(audio.channels),sampleRate=UInt32(audio.sampleRate),bitsPerSample:UInt16=16,bytesPerSample=UInt16(2),blockAlign=channels*bytesPerSample,byteRate=sampleRate*UInt32(blockAlign),dataBytes=UInt32(audio.samples.count)*UInt32(bytesPerSample)
        var data=Data(); data.appendASCII("RIFF"); data.appendLittleEndian(UInt32(36)+dataBytes); data.appendASCII("WAVE"); data.appendASCII("fmt "); data.appendLittleEndian(UInt32(16)); data.appendLittleEndian(UInt16(1)); data.appendLittleEndian(channels); data.appendLittleEndian(sampleRate); data.appendLittleEndian(byteRate); data.appendLittleEndian(blockAlign); data.appendLittleEndian(bitsPerSample); data.appendASCII("data"); data.appendLittleEndian(dataBytes)
        for sample in audio.samples { let clipped=max(-1.0,min(1.0,sample)); let scaled=clipped<0 ? clipped*32768.0 : clipped*32767.0; data.appendLittleEndian(Int16(max(-32768,min(32767,Int(scaled.rounded()))))) }
        return data
    }
}

private struct SmokeError: LocalizedError { let message:String; init(_ message:String){self.message=message}; var errorDescription:String?{message} }
private extension Data {
    mutating func appendASCII(_ value:String){append(value.data(using:.ascii)!)}
    mutating func appendLittleEndian<T:FixedWidthInteger>(_ value:T){var little=value.littleEndian; Swift.withUnsafeBytes(of:&little){append(contentsOf:$0)}}
}
// Code purpose: clean physical-device public API custom-reference smoke plus Candidate cold/warm public-API benchmark with machine-readable receipts.
// Upstream: CosyVoice3Core public API only; no private runtime/benchmark internals are invoked.
// Runtime: iOS18+, SwiftUI, AVFoundation.
// Generated: 2026-10-02 America/New_York.
// Changes 2026-10-02: retained the original smoke path; added bundled benchmark-mode auto-selection, fresh-engine first synthesis timing, same-engine repeat synthesis timing, physical device identifier, separate candidate-benchmark-receipt.json and explicit no-prewarm semantics.\n// Changes 2026-10-02: benchmark mode consumes the immutable promotion hostReceiptSha256 from its bundled marker; normal smoke mode still hashes the full staged host receipt.\n// Changes 2026-10-02: replaced Mirror-based uname parsing with direct CChar rebinding/String(cString:) for stable device model identifier extraction.

// Changes 2026-10-02: Candidate receipt records public engine stage timings for automatic preparation, frontend, LLM model load/generation and acoustic model load/synthesis; first measurement still includes all automatic cold preparation.

// Changes 2026-10-02: delete any prior Candidate receipt at benchmark start so a same-install process relaunch cannot be mistaken for a completed new run by host polling.

// Changes 2026-10-02: raw device Candidate receipts include recordedAtUnix so same-install relaunch probes can reject a stale receipt even if host polling races app startup cleanup.

// Changes 2026-10-02: bind Candidate PASS and FAIL receipts to the exact Git sourceCommit embedded at staging time; failures also carry recordedAtUnix so stale binaries/receipts are immediately distinguishable from the current run.

// Changes 2026-10-02: successful smoke/Candidate runs now publish the exact written receipt JSON into the observable UI state; Copy receipt JSON is enabled after PASS just as it already was after FAIL.

// Changes 2026-10-02: DeviceSmoke supports validation-only Flow 10/8/6 head-to-head mode, saves all three WAVs plus a bound receipt, exposes play buttons, and reads source/host identity from either Candidate or Flow validation markers.

// Changes 2026-10-02: head-to-head receipt now distinguishes acoustic-only RTF from steady compute RTF (shared LLM generation + each Flow/HiFT variant), matching the optimization question rather than conflating model-load/setup overhead.

// Changes 2026-10-02: smoke/Candidate receipts record the selected public Flow-step value; head-to-head metadata and automatic playback derive the production default from CosyVoice3FlowSteps.productionDefault (6).

// Changes 2026-10-03: smoke and Candidate modes fail closed unless capabilities expose exactly default 6 and supported 6/8/10.

// Changes 2026-10-04: dynamic-public-api-smoke mode runs two real public syntheses in one physical process: default/no-reference and custom reference with instruction=nil so reference transcript contributes to logicalPrefixLength. Receipt records active profile, manifest N bounds, PCM-derived N, stage timings, WAV hashes, source commit and device identity.

// Changes 2026-10-04: dynamic public-API smoke now creates its receipt immediately with RUNNING/START and atomically updates DEFAULT_SYNTHESIS then REFERENCE_SYNTHESIS progress before final PASS/FAIL, eliminating the normal no-file polling window and exposing durable device progress.

// Changes 2026-10-04: dynamic smoke installs the validation-only engine observer while continuing to call the public synthesize() API. Durable receipt phase now identifies prepare/model warming, frontend, LLM prefill/decode progress, acoustic model load, Conditions/Flow/F0/HiFT, separately for DEFAULT and REFERENCE lanes.

// Changes 2026-10-04: validation observer closures capture only Sendable scalar/value bindings rather than the non-Sendable Fixture aggregate, keeping Swift 6 concurrency checking explicit.

// Changes 2026-10-04: dynamic public-API PASS receipt records the validated requested mixed placement: LLM CPU_ONLY, dynamic acoustic CPU_AND_NE, reference encoders CPU_ONLY; this is not a residency claim.

// Changes 2026-10-04: dynamic public-API receipt now binds reshapeFrequency=INFREQUENT for dynamic acoustic MLModel loads, matching the physical shape-sweep execution configuration.

// Changes 2026-10-04: Candidate benchmark receipt records active runtime profile; dynamic profiles also record N bounds, validated requested mixed placement, and reshapeFrequency=INFREQUENT so host-side Candidate evidence can bind the exact dynamic execution contract.

// Changes 2026-10-04: support receipt-last external Documents/GeneratedAssets for exact hosted dynamic replay without bundling/copying 4.28GB on the host. Bind immutable manifest SHA explicitly; do not fabricate a historical host receipt. Original bundle staging and matching-reference recovery remain available.

// Changes 2026-10-05: generalize physical public-API validation and Candidate benchmark to schema-3 exact EnumeratedShapes. Active manifest precedence matches the SDK; receipts record exact EOS-derived N and selected multifunction name, no padding/crop, N450/62-prefix production contract, while schema-2 RangeDim remains a comparison path.

// Changes 2026-10-05: external Documents staging now accepts either immutable hosted asset-manifest binding or an exact local schema-3 cosyvoice3_enumerated.json SHA binding, enabling multi-GB production-candidate device validation without bundling assets into the app.

// Changes 2026-10-05: automated enumerated validation supports --no-playback; Candidate benchmark now fail-closes unless thermalStart is nominal and records thermalStart/thermalEnd plus playbackDuringBenchmark=false so smoke playback cannot contaminate performance evidence.

// Changes 2026-10-05: automated Candidate validation can pass --reset-cosy-cache to delete only this app's Library/Caches/CosyVoice3Core before engine construction. This makes first-call evidence cold with respect to compiled-model and warm-marker caches even across reinstall/re-run of the same bundle ID.

// Changes 2026-10-05: schema-3 device app verifies staged export-receipt SHA and its payloadTree/source binding before running, then carries payloadTreeSha256/exportReceiptSha256/assetExportSourceCommit into raw variable and Candidate receipts. Host remains responsible for recomputing the multi-GB payload tree before staging.

// Changes 2026-10-05: Candidate cold/warm benchmark sets validation-only sampler seed 42 before both public synthesize calls and fail-closes unless PCM-derived speech length/sample count matches. Production/default-reference smoke remains unseeded System RNG.

// Changes 2026-10-05: matched Candidate benchmark now also requires identical deterministic Int16 WAV SHA256 across cold/warm calls. Same duration alone is insufficient; a divergent seeded token/audio trajectory invalidates the performance comparison.

// Changes 2026-10-05: Candidate/variable receipts and FAIL receipts report the effective validation acoustic placement; schema-3 diagnostic command-line overrides are never labeled as production placement.

// Changes 2026-10-05 19:12 America/New_York: Candidate/FAIL receipts carry 12 requested role placements and explicit unproven residency. Upstream DeviceSmoke public API benchmark; environment physical iPhone/iOS18+, Swift6.

// Changes 2026-10-05: separate --ane-compute-plans diagnostic records supported/preferred devices/errors; baseline timing mode never loads a plan. Explicit validation reference cache reset; saved cold/warm WAVs for comparisons.

// Changes 2026-10-05: Candidate actual-input identity and Float32 PCM hashes, bounded sustained loop without sleep between public syntheses; memory/thermal sampling remains diagnostic. Upstream public Engine; environment physical iPhone/Swift6.

// Changes 2026-10-05 residency phase: real public-request isolated12stage diagnostic, signed input bindings and no production RTF claim; plan op SSA names and lossless partition paths. No model math changes. Swift6/iPhone27.2, upstream DeviceSmoke; line mapping via git diff.

// Changes2026-10-05 thermal phase: noWAVhash during sustainedloop; retain12smallPCM buffers thenverifyaftergroup. Optionalnominalgate onlybeforegroup, nointeriterationwait. IsolatedrawPCM savedafterloopfornumericparity, no playback. Swift6/iPhone27.2; upstreamvalidationlane, changedlines gitdiff.

// Changes2026-10-06: plan-only whitelistdirectoryANEFlowP2/P3 probesexactselectedsingle-functionpartition; public loader/benchmark paths unchanged. SourceSwift6/Xcode27.2; no operator/weight/algorithm change. Linesgitdiff.

// Change2026-10-06: additive validation-only six-sample listening/export lane; public synthesize/math untouched.
// Upstream existing DeviceSmoke fixture/WAV/report utilities; Swift6/iOS18+ physical device; generated07:48 EDT America/New_York.
// Changed regions: runAutoMode dispatch and new runListeningCheckpoint before candidate benchmark.

// Measurement-only process telemetry. Rows/stage are lock protected; no tensors/pointers retained.
private final class WarmPassMemoryTimeline: @unchecked Sendable {
    private let lock=NSLock()
    private var stage="launch"
    private var rows=[[String:Any]]()
    private var timer:DispatchSourceTimer?
    private var closed=false
    init() {
        let timer=DispatchSource.makeTimerSource(queue:.global(qos:.utility))
        timer.schedule(deadline:.now(),repeating:.milliseconds(100))
        timer.setEventHandler { [weak self] in self?.record(nil) }
        self.timer=timer;timer.resume()
    }
    func record(_ boundary:String?) {
        var info=task_vm_info_data_t();var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let result=withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }
        lock.lock();defer { lock.unlock() };guard !closed,rows.count<5000 else{return}
        if let boundary { stage=boundary }
        var row:[String:Any]=["uptimeNanoseconds":DispatchTime.now().uptimeNanoseconds,"stage":stage,"boundary":boundary != nil,"physicalFootprintBytes":result==KERN_SUCCESS ? info.phys_footprint:0,"thermalState":ProcessInfo.processInfo.thermalState.rawValue]
        if CommandLine.arguments.contains("--validation-execution-audit") { row["cpuMilliseconds"]=CosyVoice3Engine.validationExecutionCPUTime(); row["CPUOnlyEnergyNanojoules"]=CosyVoice3Engine.validationExecutionCPUEnergy().map{ $0 as Any } ?? NSNull() }
        rows.append(row)
    }
    func stop()->[[String:Any]] { timer?.cancel();timer=nil;record("sampler_stop");lock.lock();defer{lock.unlock()};closed=true;return rows }
    deinit { timer?.cancel() }
}
// Purpose:100ms validation memory timeline, not exact peak/per-model attribution. Swift6/iOS18+;
// generated2026-10-06; dictionary/token/logit audit storage is accounted separately from inference state.

// PhaseA2026-10-06: validation-only public warm/memory lane; sampling/state/input algorithm unchanged.
// Native memory idle observation separate from no-delay performance repeats; exact line map git diff.

// Measurement2026-10-06: all stage boundaries,100ms lifetime mode,1/3/10/35s idle probes onlymemory lane.
// Upstream DeviceSmoke warm lane; Swift6/physical iPhone; no inter-request performance delay or synthesis change.

// Measurement2026-10-06: execution-audit timeline adds CPU-only OSenergy/CPU counters tostage boundaries; no synthesis mutation.

// ResourceEfficiency validation: frozen public inference, one-chunk generate-ahead virtual consumption.
// The waits below are playback deadlines / explicit PRETEST gates, never model throttling.
extension CosyVoice3SmokeModel {
    func runResourceEfficiency() async {
        guard !running else{return}; running=true; defer{running=false}
        let filename="resource-efficiency-receipt.json"
        let oldBrightness=UIScreen.main.brightness
        UIDevice.current.isBatteryMonitoringEnabled=true
        UIScreen.main.brightness=0.2
        defer{UIScreen.main.brightness=oldBrightness}
        var rows=[[String:Any]](), priming=[CosyVoice3Audio]()
        var lastAudio:CosyVoice3Audio?
        let monitor=ResourceEfficiencyTimeline()
        defer{_ = monitor.stop()}
        do {
            func option(_ prefix:String)->String? {CommandLine.arguments.first{$0.hasPrefix(prefix)}.map{String($0.dropFirst(prefix.count))}}
            let mode=option("--validation-resource-lane=") ?? "screen"
            let policy=option("--validation-acoustic-cache=") ?? "none"
            let count=mode=="screen" ? 5:(Int(option("--validation-resource-chunks=") ?? "60") ?? 0)
            let chargingAllowed=CommandLine.arguments.contains("--validation-resource-allow-charging")
            guard ["screen","continuous"].contains(mode),["selected-family","decoder","none"].contains(policy),
                  mode=="screen" || (58...115).contains(count),
                  CommandLine.arguments.contains("--validation-flow-partition=2"),
                  !CommandLine.arguments.contains("--reset-cosy-cache"),
                  !CommandLine.arguments.contains(where:{$0.hasPrefix("--validation-placement=") || $0.hasPrefix("--validation-single-function=")}),
                  !CommandLine.arguments.contains("--validation-execution-audit") else {throw SmokeError("resource lane requires frozen SHARDS2/Flow6/placement, bounded duration, no reset/per-token audit")}
            let fixture=try Self.fixture()
            let models=try Self.validateExperimentalModels(runtime:fixture.runtime)
            let id=UUID().uuidString
            let eventsURL=try Self.receiptURL("resource-efficiency-events.jsonl")
            try Data().write(to:eventsURL)
            let eventHandle=try FileHandle(forWritingTo:eventsURL)
            defer{try? eventHandle.close()}
            func saveStatus(_ state:String) throws {
                _ = try Self.write(["schemaVersion":1,"status":state,"runID":id,"sourceCommit":fixture.sourceCommit,
                    "mode":mode,"cachePolicy":policy,"SHARDS":2,"flowSteps":6,"chargingAllowed":chargingAllowed,
                    "environment":Self.resourceEnvironment(),"rows":rows,"productionPromotion":false],to:Self.receiptURL(filename))
            }
            let engine=try CosyVoice3Engine(assetRoot:fixture.runtime,idleBucketPreparation:false)
            await engine.setValidationSamplerSeed(42)
            await engine.setValidationProgressObserver {phase in monitor.record(phase)}
            monitor.record("engine_created")
            // Two priming outputs remain retained for the complete run in ALL policies.
            if mode=="continuous" {
                for n in 1...2 {
                    status="PRIMING \(policy) \(n)/2"
                    let a=try await engine.synthesize(fixture.text,parameters:fixture.parameters)
                    try Self.validate(a);priming.append(a)
                }
            }
            let gateStart=ContinuousClock.now
            while ProcessInfo.processInfo.thermalState != .nominal ||
                (mode=="continuous" && !chargingAllowed && UIDevice.current.batteryState != .unplugged) {
                status="WAIT_RESOURCE_GATE policy=\(policy) nominal + unplugged required"
                try saveStatus("WAITING_FOR_NOMINAL_UNPLUGGED")
                monitor.record("pretest_gate_wait")
                guard Self.seconds(gateStart.duration(to:.now))<1800 else{throw SmokeError("formal gate timeout; no charged/hot result silently accepted")}
                try await Task.sleep(for:.seconds(5))
            }
            // Launch may deliver SwiftUI.task before the scene is active. Readiness only, outside timed inference.
            let foregroundDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while UIApplication.shared.applicationState != .active, ContinuousClock.now < foregroundDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard UIApplication.shared.applicationState == .active else{throw SmokeError("foreground screen-on required")}
            let environmentStart=Self.resourceEnvironment()
            monitor.record("formal_begin")
            let overallStart=ContinuousClock.now
            var origin:ContinuousClock.Instant?
            var buffered=[(end:ContinuousClock.Instant,audio:CosyVoice3Audio)]()
            var starvationSeconds=0.0, maxBuffered=0
            for n in 1...count {
                if mode=="continuous", n>1, let origin {
                    let producerStart=origin.advanced(by:.seconds(Double(n-2)*10.4))
                    if producerStart>ContinuousClock.now {try await ContinuousClock().sleep(until:producerStart)}
                }
                guard UIApplication.shared.applicationState == .active else{throw SmokeError("foreground changed; consumer test invalid")}
                if mode=="continuous",!chargingAllowed,UIDevice.current.batteryState != .unplugged{throw SmokeError("charging/unknown battery state during formal comparison")}
                if ProcessInfo.processInfo.thermalState == .critical {throw SmokeError("critical thermal: stop starting new inference")}
                if mode=="continuous" {buffered.removeAll{$0.end<=ContinuousClock.now}}
                let env=Self.resourceEnvironment(),cpu=Self.processCPUMilliseconds(),energy=Self.resourceCPUEnergy()
                monitor.active(true);monitor.record("request_\(n)_begin")
                let start=ContinuousClock.now
                let audio=try await engine.synthesize(fixture.text,parameters:fixture.parameters)
                let finish=ContinuousClock.now,ms=Self.seconds(start.duration(to:finish))*1000
                let endEnergy=Self.resourceCPUEnergy(),cpuMs=Self.processCPUMilliseconds()-cpu
                monitor.record("request_\(n)_completion");monitor.active(false)
                try Self.validate(audio)
                let pcm=audio.samples.withUnsafeBytes{SHA256.hash(data:Data($0)).map{String(format:"%02x",$0)}.joined()}
                let tokens=await engine.validationResourceSpeechTokens()
                let tokenSHA=SHA256.hash(data:try JSONSerialization.data(withJSONObject:tokens)).map{String(format:"%02x",$0)}.joined()
                guard pcm=="909a1b85650b172604fb2d39b6a35f8f3b5cbf80bd97beb76e775b73ee4cd694",
                      tokenSHA=="5227af1bfe2461b352e1d8747f63df8d54fd7b4c7640e001b81152a8b455a64d",tokens.count==260,
                      audio.samples.count==249600,audio.sampleRate==24000,
                      let report=await engine.lastSynthesisReport(),report.flowSteps == .steps6 else{
                    try Self.wavData(audio).write(to:Self.receiptURL("resource-quality-difference.wav"))
                    throw SmokeError("STOP resource candidate identity changed; no automatic promotion")
                }
                if origin==nil {origin=finish}
                var late=0.0
                if mode=="continuous",n>1,let origin {
                    let deadline=origin.advanced(by:.seconds(Double(n-1)*10.4))
                    late=max(0,Self.seconds(deadline.duration(to:finish)));starvationSeconds+=late
                }
                if mode=="continuous",let origin {buffered.append((origin.advanced(by:.seconds(Double(n)*10.4)),audio))}
                else {buffered.append((finish,audio))}
                maxBuffered=max(maxBuffered,buffered.count);lastAudio=audio
                let delta:UInt64?=energy.flatMap{before in endEnergy.flatMap{after in after>=before ? after-before:nil}}
                let row:[String:Any]=["request":n,"elapsedSeconds":Self.seconds(overallStart.duration(to:finish)),
                    "totalMilliseconds":ms,"RTF":ms/10400,"computeDutyCycle":ms/10400,"idleHeadroom":max(0,1-ms/10400),
                    "audioSeconds":10.4,"cpuMilliseconds":cpuMs,"CPUOnlyAttributedEnergyNanojoules":delta.map{$0 as Any} ?? NSNull(),
                    "CPUOnlyEnergyPerPlaybackSecondMillijoules":delta.map{Double($0)/1e6/10.4 as Any} ?? NSNull(),
                    "energyPerPlaybackSecondMillijoules":NSNull(),"averageTotalActivePowerMilliwatts":NSNull(),
                    "thermalStart":env["thermalState"]!,"thermalEnd":Self.thermalName(ProcessInfo.processInfo.thermalState),
                    "environmentStart":env,"environmentEnd":Self.resourceEnvironment(),"stageTimings":Self.reportDictionary(report),
                    "completionPhysicalFootprintBytes":Self.processFootprint(),"callerRetainedPCMBytes":(priming.count+buffered.count)*249600*4,
                    "readyDeadlineLatenessSeconds":late,"virtualStarvation":late>0,"PCM_SHA256":pcm,"tokenSequenceSHA256":tokenSHA,
                    "N":260,"function":"n257_384","SHARDS":2,"flowSteps":6,"sampleRate":24000,"samples":249600]
                rows.append(row)
                let line=try JSONSerialization.data(withJSONObject:row,options:.sortedKeys)
                try eventHandle.write(contentsOf:line+Data([10]))
                status="RESOURCE \(policy) \(n)/\(count) RTF=\(String(format:"%.4f",ms/10400)) thermal=\(Self.thermalName(ProcessInfo.processInfo.thermalState))"
                print("[COSY-RESOURCE] \(status)")
                // Checkpoint is outside public inference; no device transfer during run.
                if n%3==0 {try saveStatus("RUNNING_RESOURCE")}
            }
            if mode=="continuous",let origin {
                let consumptionEnd=origin.advanced(by:.seconds(Double(count)*10.4))
                if consumptionEnd>ContinuousClock.now {try await ContinuousClock().sleep(until:consumptionEnd)}
            }
            monitor.record("formal_consumption_end")
            let formalSeconds=Self.seconds(overallStart.duration(to:.now))
            let environmentEnd=Self.resourceEnvironment()
            if mode=="continuous" {
                for seconds in [1,3,10,35] {
                    let prior=seconds==1 ? 0:seconds==3 ? 1:seconds==10 ? 3:10
                    try await Task.sleep(for:.seconds(seconds-prior));monitor.record("post_consumption_idle_\(seconds)s")
                }
            }
            let timeline=monitor.stop()
            let snapshot=try JSONSerialization.jsonObject(with:Data(await engine.persistentRuntimeSnapshotJSON().utf8))
            let wav=Self.wavData(lastAudio!),wavSHA=SHA256.hash(data:wav).map{String(format:"%02x",$0)}.joined()
            guard wavSHA=="a04f69c7d01e08bc779c8a49dafa6fd7723397cf3da6864060f17f8d68277888" else{throw SmokeError("STOP WAV identity")}
            try wav.write(to:Self.receiptURL("resource-efficiency.wav"))
            let receipt:[String:Any]=["schemaVersion":1,"status":"PASS_FROZEN_RESOURCE_RUN","runID":id,"sourceCommit":fixture.sourceCommit,
                "processID":ProcessInfo.processInfo.processIdentifier,"mode":mode,"cachePolicy":policy,"SHARDS":2,"flowSteps":6,
                "device":Self.machineIdentifier(),"iOS":UIDevice.current.systemVersion,"environmentStart":environmentStart,"environmentEnd":environmentEnd,
                "chargingAllowed":chargingAllowed,"idleBucketPreparationDisabledForMatchedSteadyState":true,"formalSeconds":formalSeconds,"producedAudioSeconds":Double(count)*10.4,
                "virtuallyConsumedAudioSeconds":mode=="continuous" ? Double(count)*10.4:0,"synthesisWallMilliseconds":rows.reduce(0){$0+($1["totalMilliseconds"] as! Double)},
                "virtualStarvationSeconds":starvationSeconds,"maximumBufferedChunks":maxBuffered,
                "consumptionMode":"virtual monotonic24kHz PCM availability; foreground onechunk generateahead; no physical audiohardware underrun claim",
                "idleMeaning":"consumer deadlines, not cooldown/throttle; post35s memory-expiry observation excludedfromformalwindow",
                "rows":rows,"memoryThermalCPUCounterTimeline":timeline,"persistentRuntime":snapshot,"experimentalModelIdentity":models,
                "payloadTreeSHA256":fixture.payloadTreeSHA256 ?? "","inputTextSHA256":SHA256.hash(data:Data(fixture.text.utf8)).map{String(format:"%02x",$0)}.joined(),
                "PCM_SHA256":"909a1b85650b172604fb2d39b6a35f8f3b5cbf80bd97beb76e775b73ee4cd694","WAV_SHA256":wavSHA,
                "energyScope":"selfprocess CPU-only recount/context-switch granularity; totalANE/GPUenergy andmJ/playback-second N/A",
                "publicAPI":"CosyVoice3Engine.synthesize()","productionPromotion":false]
            _ = try Self.write(receipt,to:Self.receiptURL(filename))
            status="PASS resource \(mode) policy=\(policy) SHARDS2 Flow6"
        } catch {
            let partial=monitor.stop()
            Self.recordFailure(error,filename:filename,into:self)
            if let url=try? Self.receiptURL(filename),let data=try? Data(contentsOf:url),var failure=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
                failure["partialRows"]=rows; failure["partialTimeline"]=partial;failure["environment"]=Self.resourceEnvironment()
                _ = try? Self.write(failure,to:url)
            }
        }
    }
    private static func resourceCharging()->Bool {UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full}
    private static func resourceCPUEnergy()->UInt64? {CosyVoice3Engine.validationExecutionCPUEnergy()}
    private static func resourceEnvironment()->[String:Any] {
        ["thermalState":thermalName(ProcessInfo.processInfo.thermalState),"batteryStateRaw":UIDevice.current.batteryState.rawValue,
         "batteryLevel":UIDevice.current.batteryLevel,"chargingConnected":resourceCharging(),"screenBrightness":Double(UIScreen.main.brightness),
         "foreground":UIApplication.shared.applicationState == .active,"idleTimerDisabled":UIApplication.shared.isIdleTimerDisabled,
         "lowPowerMode":ProcessInfo.processInfo.isLowPowerModeEnabled,"ambientTemperatureC":NSNull()]
    }
}
private final class ResourceEfficiencyTimeline:@unchecked Sendable {
    private let lock=NSLock()
    private var rows=[[String:Any]](),stage="setup",closed=false
    private var timer:DispatchSourceTimer?
    init(){let t=DispatchSource.makeTimerSource(queue:.global(qos:.utility));t.schedule(deadline:.now(),repeating:.seconds(1));t.setEventHandler{[weak self] in self?.record(nil)};timer=t;t.resume()}
    func active(_ value:Bool){timer?.schedule(deadline:.now(),repeating:value ? .milliseconds(100):.seconds(1))}
    func record(_ boundary:String?){
        let time=DispatchTime.now().uptimeNanoseconds,cpu=CosyVoice3Engine.validationExecutionCPUTime(),energy=CosyVoice3Engine.validationExecutionCPUEnergy()
        var info=task_vm_info_data_t(),count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let code=withUnsafeMutablePointer(to:&info){p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}}
        lock.lock();defer{lock.unlock()};guard !closed,rows.count<30000 else{return};if let boundary{stage=boundary}
        rows.append(["uptimeNanoseconds":time,"stage":stage,"boundary":boundary != nil,"physicalFootprintBytes":code==KERN_SUCCESS ? info.phys_footprint:0,
            "thermalStateRaw":ProcessInfo.processInfo.thermalState.rawValue,"cpuMilliseconds":cpu,"CPUOnlyEnergyNanojoules":energy.map{$0 as Any} ?? NSNull()])
    }
    func stop()->[[String:Any]]{timer?.cancel();timer=nil;record("sampler_stop");lock.lock();defer{lock.unlock()};closed=true;return rows}
    deinit{timer?.cancel()}
}
// Purpose: boundedscreen/10-20minute realdevice pacedconsumption resource comparisons, not productionmode.
// All model/state/precision/placement/Flow/sampling code unchanged. Scalartelemetry is lock protected;
// actor-scoped serialsynthesis; timer weakcapture; latesttokens/callerPCM bounded equallyacrosspolicies.
// Upstream existingpublic Engine/DeviceSmoke/OSCPUCounters; Swift6/iOS18+; generated2026-10-06 America/New_York.
// Changed runAutoMode dispatch andaddedresourcehelper only. Post-expirywait outside formalwindow.

// Validation-only2026-10-06: await initialsceneactive up5s beforetimedresource inference; timeoutstillFAIL, notthermal throttle.
// Upstream DeviceSmoke resourcegate; Swift6/iOS18+; changedrunResourceEfficiency initialforegroundguard only.
