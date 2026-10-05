// FlowSpecializationParityTests.swift
// Requirement: compare default vs fastPrediction complete acoustic outputs using identical frozen token/conditioning/noise inputs.
import CoreML
import Darwin
import Foundation
import XCTest
@testable import CosyVoice3Core
@available(iOS 18.0, macOS 15.0, *)
final class FlowSpecializationParityTests: XCTestCase {
    func testFrozenAcousticHintParity() async throws {
        guard let path = ProcessInfo.processInfo.environment["COSYVOICE3_FROZEN_ASSET_ROOT"] else { throw XCTSkip("Set frozen asset root for isolated host component comparison") }
        let root = URL(fileURLWithPath: path)
        let m = try CosyVoice3AssetLoader.loadManifest(root: root)
        let d = try XCTUnwrap(m.dynamicAcoustic)
        let tokens = try CosyVoice3AssetLoader.array(root: root, path: d.defaultPromptTokens, shape: [1,151], type: .int32)
        let feat = try CosyVoice3AssetLoader.array(root: root, path: d.defaultPromptFeat, shape: [1,302,80], type: .float32)
        let speaker = try CosyVoice3AssetLoader.array(root: root, path: d.defaultSpeaker, shape: [1,192], type: .float32)
        let noise = try CosyVoice3AssetLoader.array(root: root, path: d.flowNoiseMaximum, shape: [1,80,d.maximumFlowFrames], type: .float32)
        let excitation = try CosyVoice3AssetLoader.array(root: root, path: d.hiftExcitationMaximum, shape: [1,d.maximumPCMSamples,9], type: .float32)
        let f0 = try CosyVoice3HiFTDoubleF0(folder: root.appendingPathComponent(m.f0Folder))
        let prepared = CosyVoice3PreparedRequest(prefillInput: try MLDictionaryFeatureProvider(dictionary: [:]), minimumSpeechTokenCount: 1, maximumSpeechTokenCount: 479, logicalPrefixLength: 224)
        defer { unsetenv("COSYVOICE3_VALIDATION_FLOW_FAST_PREDICTION") }
        for n in [186,225] {
            let speech = (0..<n).map { tokens[$0 % 151].intValue }
            var outputs: [[Float]] = []
            var times: [Double] = []
            for fast in [false,true] {
                setenv("COSYVOICE3_VALIDATION_FLOW_FAST_PREDICTION", fast ? "1" : "0", 1)
                let runtime = try CosyVoice3DynamicAcousticRuntime(assetRoot: root, conditionsPath: m.flowConditions, flowShardPaths: m.flowShards, hiftPath: m.hift, f0: f0, contract: d, defaultPromptTokens: tokens, defaultPromptFeat: feat, defaultSpeaker: speaker, flowNoiseMaximum: noise, hiftExcitationMaximum: excitation)
                let start = DispatchTime.now().uptimeNanoseconds
                let audio = try await runtime.synthesize(speechTokens: speech, prepared: prepared)
                times.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e9)
                outputs.append(audio.samples)
            }
            XCTAssertEqual(outputs[0].count, outputs[1].count)
            let maxAbs = zip(outputs[0],outputs[1]).map { abs(Double($0.0)-Double($0.1)) }.max() ?? 0
            print("[COSY-HINT-PARITY] N=\(n) maxAbs=\(maxAbs) beforeSeconds=\(times[0]) afterSeconds=\(times[1]) samples=\(outputs[0].count) scope=HOST_COMPONENT_ONLY")
            XCTAssertEqual(maxAbs, 0, "Do not promote a hint with changed endpoint PCM")
        }
    }
}
// Purpose: full acoustic fixed-input equality gate before physical hint timing; upstream: frozen dynamic SDK and buffers.
// Environment: macOS15+ Swift XCTest; generated 2026-10-05 America/New_York; added lines 1-51.
