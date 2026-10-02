// CosyVoice3AssetLoader.swift
// Requirement: fail-closed SDK asset loading for the validated fixed225 production lane.
import CoreML
import Foundation

enum CosyVoice3AssetError: Error, Equatable { case missing(String); case invalidJSON(String); case unsupportedProfile(String) }

struct CosyVoice3Fixed225AssetManifest: Codable, Sendable {
    let schemaVersion:Int, profile:String, llmPrefill:String, llmDecode:String, speechEmbedding:String, flowConditions:String, flowShards:[String], hift:String, f0Folder:String, flowMask:String, flowNoise:String, ropeTheta:Double
    func validate() throws { guard schemaVersion==1,profile=="ios18-fixed225",flowShards.count==6,ropeTheta>0 else { throw CosyVoice3AssetError.unsupportedProfile(profile) } }
}

@available(iOS 18.0, macOS 15.0, *)
enum CosyVoice3AssetLoader {
    static func loadManifest(root:URL) throws -> CosyVoice3Fixed225AssetManifest {
        let url=root.appendingPathComponent("cosyvoice3_fixed225.json"); guard FileManager.default.fileExists(atPath:url.path) else { throw CosyVoice3AssetError.missing(url.path) }
        do { let m=try JSONDecoder().decode(CosyVoice3Fixed225AssetManifest.self,from:Data(contentsOf:url)); try m.validate(); return m } catch let e as CosyVoice3AssetError { throw e } catch { throw CosyVoice3AssetError.invalidJSON(String(describing:error)) }
    }
    static func model(root:URL,path:String,computeUnits:MLComputeUnits=.cpuAndNeuralEngine) throws -> MLModel {
        let url=root.appendingPathComponent(path); guard FileManager.default.fileExists(atPath:url.path) else { throw CosyVoice3AssetError.missing(url.path) }
        let compiled=url.pathExtension=="mlmodelc" ? url:try MLModel.compileModel(at:url), config=MLModelConfiguration(); config.computeUnits=computeUnits; return try MLModel(contentsOf:compiled,configuration:config)
    }
    static func array(root:URL,path:String,shape:[Int],type:MLMultiArrayDataType) throws -> MLMultiArray {
        let url=root.appendingPathComponent(path); guard FileManager.default.fileExists(atPath:url.path) else { throw CosyVoice3AssetError.missing(url.path) }
        let data=try Data(contentsOf:url), a=try MLMultiArray(shape:shape.map(NSNumber.init),dataType:type), bytes=a.count*(type==.float16 ? 2:4); guard data.count==bytes else { throw CosyVoice3AssetError.invalidJSON("asset byte count mismatch \(path)") }; data.withUnsafeBytes { a.dataPointer.copyMemory(from:$0.baseAddress!,byteCount:bytes) }; return a
    }
}

// Purpose: centralize immutable asset names instead of leaking benchmark Documents paths into runtime.
// Upstream: validated CoreML artifacts from CosyVoice3_NPU@8789402.
// Runtime: iOS18+.
// Generated: 2026-10-02 America/New_York.
