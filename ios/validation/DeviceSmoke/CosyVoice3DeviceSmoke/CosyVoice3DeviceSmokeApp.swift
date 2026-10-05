// CosyVoice3DeviceSmokeApp.swift
// Requirement: physical-device smoke/Candidate paths use the stable public CosyVoice3Core API; variable-length validation covers schema-2 RangeDim and schema-3 exact-enumerated profiles, default/no-reference and custom-reference lanes.

import AVFoundation
import Combine
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

    func runAutoMode() async {
        let idleSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleSetting }
        do {
            let resources = try Self.generatedAssets()
            if ProcessInfo.processInfo.arguments.contains("--candidate-benchmark") { await runCandidateBenchmark() }
            else if FileManager.default.fileExists(atPath: resources.appendingPathComponent("variable-public-api-smoke-mode.json").path)
                 || FileManager.default.fileExists(atPath: resources.appendingPathComponent("dynamic-public-api-smoke-mode.json").path) {
                await runVariablePublicAPISmoke()
            }
            else if FileManager.default.fileExists(atPath: resources.appendingPathComponent("flow-step-head-to-head-mode.json").path) { await runFlowStepHeadToHead() }
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
                    "llmPrefill": "CPU_ONLY",
                    "llmDecode": "CPU_ONLY",
                    "acoustic": "CPU_AND_NE",
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

    func runCandidateBenchmark() async {
        guard !running else { return }; running = true; status = "RUNNING Candidate public-API cold/warm benchmark..."; defer { running = false }
        if let stale = try? Self.receiptURL("candidate-benchmark-receipt.json") { try? FileManager.default.removeItem(at: stale) }
        do {
            let thermalStart = ProcessInfo.processInfo.thermalState
            guard thermalStart == .nominal else {
                throw SmokeError("Candidate benchmark requires thermal nominal at start; actual=\(Self.thermalName(thermalStart))")
            }
            let fixture = try Self.fixture()
            let activeManifest = try Self.activeManifest(runtime: fixture.runtime)
            let activeProfile = activeManifest.profile
            let variable = try? Self.variableManifestInfo(runtime: fixture.runtime)
            let speechTokenBounds = variable.map { [$0.speechTokenMinimum, $0.speechTokenMaximum] }
            let clock = ContinuousClock(); let initStart = clock.now
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
            let thermalEnd = ProcessInfo.processInfo.thermalState
            var receipt: [String: Any] = ["schemaVersion":1,"status":"PASS_CANDIDATE_BENCHMARK","benchmark":"public-api-candidate-v1","sourceCommit":fixture.sourceCommit,"recordedAtUnix":Int(Date().timeIntervalSince1970),"profile":activeProfile,"coldDefinition":"fresh process + fresh CosyVoice3Engine; automatic bounded model preparation is included; no validateReference prewarm","warmDefinition":"second identical public synthesize call on the same engine instance after automatic preparation","referenceValidationPrewarm":false,"engineInitMilliseconds":engineInitMilliseconds,"firstSynthesisMilliseconds":firstMilliseconds,"repeatSynthesisMilliseconds":repeatMilliseconds,"firstAudioSeconds":firstDuration,"repeatAudioSeconds":repeatDuration,"firstRTF":firstMilliseconds/1000/firstDuration,"repeatRTF":repeatMilliseconds/1000/repeatDuration,"firstSamples":first.samples.count,"repeatSamples":repeatAudio.samples.count,"sameSampleCount":first.samples.count == repeatAudio.samples.count,"sampleRate":first.sampleRate,"channels":first.channels,"finite":true,"firstPeakAbs":firstStats.peak,"firstRMS":firstStats.rms,"repeatPeakAbs":repeatStats.peak,"repeatRMS":repeatStats.rms,"referenceTranscriptCharacters":fixture.transcript.count,"flowSteps":fixture.parameters.flowSteps.rawValue,"hostReceiptSha256":fixture.hostReceiptSHA256,"device":UIDevice.current.model,"deviceModelIdentifier":Self.machineIdentifier(),"systemName":UIDevice.current.systemName,"systemVersion":UIDevice.current.systemVersion,"thermalStart":Self.thermalName(thermalStart),"thermalEnd":Self.thermalName(thermalEnd),"playbackDuringBenchmark":false]
            if let speechTokenBounds, let variable {
                receipt["speechTokenBounds"] = speechTokenBounds
                receipt["acousticShapeMode"] = variable.acousticShapeMode
                receipt["requestedComputePlacement"] = [
                    "llmPrefill": "CPU_ONLY",
                    "llmDecode": "CPU_ONLY",
                    "acoustic": "CPU_AND_NE",
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
            let url = try Self.receiptURL("candidate-benchmark-receipt.json"); receiptJSON = try Self.write(receipt, to: url)
            if !automatedNoPlayback { try play(repeatAudio) }
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
        if let marker {
            let value=try JSONSerialization.jsonObject(with:Data(contentsOf:marker)) as? [String:Any]
            let hostBound = value?["hostReceiptSha256"] as? String
            let immutableBound = value?["immutableManifestSha256"] as? String
            guard hostBound?.count == 64 || immutableBound?.count == 64 else { throw SmokeError("validation marker host/immutable binding missing") }
            let bound = hostBound ?? ""
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
                let manifestData = try Data(contentsOf: staged.appendingPathComponent("Runtime").appendingPathComponent(name))
                let actual = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { throw SmokeError("staged local enumerated manifest identity mismatch") }
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
        if let data=try? JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]) { if let url=try? receiptURL(filename) { try? data.write(to:url,options:.atomic) }; model.receiptJSON=String(decoding:data,as:UTF8.self) }
        model.status="FAIL \(String(describing:error))"
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
