// CosyVoice3ModelLifetimeAudit.swift
// Requirement: optional weak-only MLModel lifetime observations, without altering cache policy.
import CoreML
import Foundation

final class CosyVoice3ModelLifetimeAudit: @unchecked Sendable {
    private final class Entry {
        weak var model: MLModel?
        let path: String
        init(_ model: MLModel, _ path: String) { self.model=model; self.path=path }
    }
    static let shared=CosyVoice3ModelLifetimeAudit()
    static let enabled=CommandLine.arguments.contains("--validation-model-lifetime")
    private let lock=NSLock()
    private var entries=[String:Entry]()
    static func event(_ name:String, detail:String) {
        guard enabled else{return}
        emit(["event":name,"detail":detail])
    }
    static func loaded(_ model:MLModel,path:String,function:String?,units:String) {
        guard enabled else{return}
        let id=UUID().uuidString
        shared.lock.lock(); shared.entries[id]=Entry(model,path); shared.lock.unlock()
        emit(["event":"MODEL_LOAD_END","id":id,"path":path,"function":function ?? "default","requestedUnits":units])
    }
    static func boundary(_ phase:String) {
        guard enabled else{return}
        shared.lock.lock()
        var alive=[[String:String]](), released=[[String:String]]()
        for (id,entry) in shared.entries {
            if entry.model != nil {alive.append(["id":id,"path":entry.path])}
            else {released.append(["id":id,"path":entry.path])}
        }
        for item in released {shared.entries.removeValue(forKey:item["id"]!)}
        shared.lock.unlock()
        // Weak-object disappearance is NOT proof that Core ML private resources deallocated.
        emit(["event":"MODEL_STAGE_OBSERVATION","phase":phase,"aliveSwiftModels":alive,"newlyObservedSwiftOwnerReleased":released])
    }
    private static func emit(_ fields:[String:Any]) {
        var row=fields; row["uptimeNanoseconds"]=DispatchTime.now().uptimeNanoseconds
        if let data=try? JSONSerialization.data(withJSONObject:row,options:.sortedKeys),let text=String(data:data,encoding:.utf8) {print("[COSY-MODEL-LIFETIME] " + text)}
    }
}
// Purpose: correlate load/shelf/stage timestamps and weak Swift object lifetimes with process footprint.
// Owner: loader/caller/shelf owns models; this lock-protected registry owns weak wrappers only.
// No tensor/pointer escape, no prediction mutation, no shared strong model capture.
// Upstream AssetLoader/Engine validation observer; Swift6/iOS18+/macOS15+; generated2026-10-06 America/New_York.
