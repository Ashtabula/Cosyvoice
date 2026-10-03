// CosyVoice3DeviceSmokeApp.swift
// Requirement: physical-device smoke/Candidate paths use the stable public CosyVoice3Core API; Flow-step head-to-head uses only the explicit Validation SPI.

import AVFoundation
import Combine
import CryptoKit
import Darwin
import SwiftUI
import UIKit
@_spi(Validation) import CosyVoice3Core

@main
struct CosyVoice3DeviceSmokeApp: App {
    @StateObject private var model = CosyVoice3SmokeModel()
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("CosyVoice3 Device Smoke").font(.title2.bold())
                Text(model.status).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Button("Run public API reference smoke") { Task { await model.runSmoke() } }.disabled(model.running)
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
    private var player: AVAudioPlayer?
    private var flowStepAudios: [Int: CosyVoice3Audio] = [:]

    func runAutoMode() async {
        do {
            let resources = try Self.generatedAssets()
            if FileManager.default.fileExists(atPath: resources.appendingPathComponent("flow-step-head-to-head-mode.json").path) { await runFlowStepHeadToHead() }
            else if FileManager.default.fileExists(atPath: resources.appendingPathComponent("candidate-benchmark-mode.json").path) { await runCandidateBenchmark() }
            else { await runSmoke() }
        } catch { status = "FAIL \(String(describing: error))" }
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

    func runCandidateBenchmark() async {
        guard !running else { return }; running = true; status = "RUNNING Candidate public-API cold/warm benchmark..."; defer { running = false }
        if let stale = try? Self.receiptURL("candidate-benchmark-receipt.json") { try? FileManager.default.removeItem(at: stale) }
        do {
            let fixture = try Self.fixture(); let clock = ContinuousClock(); let initStart = clock.now
            let engine = try CosyVoice3Engine(assetRoot: fixture.runtime); let engineInitMilliseconds = Self.seconds(initStart.duration(to: clock.now))*1000
            let capabilities = try await engine.capabilities()
            guard capabilities.supportsReferenceAudio,
                  capabilities.supportsInstruction,
                  capabilities.outputSampleRate == 24_000,
                  capabilities.defaultFlowSteps == .steps6,
                  capabilities.supportedFlowSteps.map(\.rawValue) == [6,8,10] else {
                throw SmokeError("unexpected capabilities")
            }
            let firstStart = clock.now; let first = try await engine.synthesize(fixture.text, parameters: fixture.parameters); let firstMilliseconds = Self.seconds(firstStart.duration(to: clock.now))*1000; try Self.validate(first)
            let firstStages = await engine.lastSynthesisReport()
            let repeatStart = clock.now; let repeatAudio = try await engine.synthesize(fixture.text, parameters: fixture.parameters); let repeatMilliseconds = Self.seconds(repeatStart.duration(to: clock.now))*1000; try Self.validate(repeatAudio)
            let repeatStages = await engine.lastSynthesisReport()
            let firstDuration = Self.audioDuration(first); let repeatDuration = Self.audioDuration(repeatAudio); let firstStats = Self.stats(first); let repeatStats = Self.stats(repeatAudio)
            var receipt: [String: Any] = ["schemaVersion":1,"status":"PASS_CANDIDATE_BENCHMARK","benchmark":"public-api-candidate-v1","sourceCommit":fixture.sourceCommit,"recordedAtUnix":Int(Date().timeIntervalSince1970),"coldDefinition":"fresh process + fresh CosyVoice3Engine; automatic bounded model preparation is included; no validateReference prewarm","warmDefinition":"second identical public synthesize call on the same engine instance after automatic preparation","referenceValidationPrewarm":false,"engineInitMilliseconds":engineInitMilliseconds,"firstSynthesisMilliseconds":firstMilliseconds,"repeatSynthesisMilliseconds":repeatMilliseconds,"firstAudioSeconds":firstDuration,"repeatAudioSeconds":repeatDuration,"firstRTF":firstMilliseconds/1000/firstDuration,"repeatRTF":repeatMilliseconds/1000/repeatDuration,"firstSamples":first.samples.count,"repeatSamples":repeatAudio.samples.count,"sameSampleCount":first.samples.count == repeatAudio.samples.count,"sampleRate":first.sampleRate,"channels":first.channels,"finite":true,"firstPeakAbs":firstStats.peak,"firstRMS":firstStats.rms,"repeatPeakAbs":repeatStats.peak,"repeatRMS":repeatStats.rms,"referenceTranscriptCharacters":fixture.transcript.count,"flowSteps":fixture.parameters.flowSteps.rawValue,"hostReceiptSha256":fixture.hostReceiptSHA256,"device":UIDevice.current.model,"deviceModelIdentifier":Self.machineIdentifier(),"systemName":UIDevice.current.systemName,"systemVersion":UIDevice.current.systemVersion]
            if let firstStages { receipt["firstStages"] = Self.reportDictionary(firstStages) }
            if let repeatStages { receipt["repeatStages"] = Self.reportDictionary(repeatStages) }
            let url = try Self.receiptURL("candidate-benchmark-receipt.json"); receiptJSON = try Self.write(receipt, to: url); try play(repeatAudio)
            status = String(format:"PASS Candidate first=%.3fs RTF=%.3f repeat=%.3fs RTF=%.3f receipt=%@",firstMilliseconds/1000,firstMilliseconds/1000/firstDuration,repeatMilliseconds/1000,repeatMilliseconds/1000/repeatDuration,url.path)
        } catch { Self.recordFailure(error, filename:"candidate-benchmark-receipt.json", into:self) }
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

    private struct Fixture {
        let runtime: URL
        let reference: CosyVoice3VoiceReference
        let transcript: String
        let hostReceiptSHA256: String
        let sourceCommit: String
        let text: String
        let parameters: CosyVoice3Parameters
    }

    private static func fixture() throws -> Fixture {
        let resources = try generatedAssets(); let runtime = resources.appendingPathComponent("Runtime", isDirectory:true); let wav = resources.appendingPathComponent("reference.wav"); let transcript = try String(contentsOf:resources.appendingPathComponent("reference.txt"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        let reference = CosyVoice3VoiceReference(audioURL:wav,transcript:transcript)
        let candidateMarker=resources.appendingPathComponent("candidate-benchmark-mode.json")
        let flowMarker=resources.appendingPathComponent("flow-step-head-to-head-mode.json")
        let marker:URL? = FileManager.default.fileExists(atPath:flowMarker.path) ? flowMarker : (FileManager.default.fileExists(atPath:candidateMarker.path) ? candidateMarker : nil)
        let hostSHA:String; let sourceCommit:String
        if let marker {
            let value=try JSONSerialization.jsonObject(with:Data(contentsOf:marker)) as? [String:Any]
            guard let bound=value?["hostReceiptSha256"] as? String, bound.count==64 else { throw SmokeError("validation marker host binding missing") }
            guard let commit=value?["sourceCommit"] as? String, commit.range(of:"^[0-9a-f]{40}$",options:.regularExpression) != nil else { throw SmokeError("validation marker sourceCommit missing") }
            hostSHA=bound
            sourceCommit=commit
        } else {
            let hostData=try Data(contentsOf:resources.appendingPathComponent("reference_host_parity_receipt.json"))
            hostSHA=SHA256.hash(data:hostData).map{String(format:"%02x",$0)}.joined()
            sourceCommit="unbound-noncandidate-smoke"
        }
        let text = "This is a CosyVoice3 public API reference voice validation."
        return Fixture(runtime:runtime,reference:reference,transcript:transcript,hostReceiptSHA256:hostSHA,sourceCommit:sourceCommit,text:text,parameters:CosyVoice3Parameters(reference:reference,instruction:"You are a helpful assistant.<|endofprompt|>"+transcript))
    }

    private static func generatedAssets() throws -> URL {
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
        if let data=try? JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]) { if let url=try? receiptURL(filename) { try? data.write(to:url,options:.atomic) }; model.receiptJSON=String(decoding:data,as:UTF8.self) }
        model.status="FAIL \(String(describing:error))"
    }

    private static func validationSourceCommit() -> String? {
        guard let resources = try? generatedAssets() else { return nil }
        for name in ["flow-step-head-to-head-mode.json","candidate-benchmark-mode.json"] {
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
