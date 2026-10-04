# prepare_text_probe.py
# Requirement: create an isolated SDK copy for real-text LLM stop/token provenance; optionally remove only the fixed225 generation cap while preserving shipping code, native RAS, EOS semantics, upstream 20x policy and model bytes.
import argparse,hashlib,json,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]

def sha(path):
    h=hashlib.sha256()
    for f in sorted(path.rglob('*')) if path.is_dir() else [path]:
        if f.is_file():
            if path.is_dir():h.update(str(f.relative_to(path)).encode())
            with f.open('rb') as stream:
                for b in iter(lambda:stream.read(8*1024*1024),b''):h.update(b)
    return h.hexdigest()

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--library',action='store_true');p.add_argument('--llm-backend',choices=('CPU_ONLY','CPU_AND_NE'),default='CPU_AND_NE');p.add_argument('--remove-fixed225-cap',action='store_true');a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=False)
    dest=a.output/'Sources/Probe';shutil.copytree(ROOT/'ios/Sources/CosyVoice3Core',dest)
    if a.remove_fixed225_cap:
        contracts=dest/'CosyVoice3RuntimeContracts.swift';c=contracts.read_text()
        needle='    static let speechTokenCapacity = 225'
        replacement='    static let speechTokenCapacity = CosyVoice3FP16StatefulLLMSession.capacity'
        if needle not in c:raise RuntimeError('fixed225 generation-cap anchor not found')
        contracts.write_text(c.replace(needle,replacement,1))
    llm=dest/'CosyVoice3LLMRuntime.swift';s=llm.read_text()
    s=s.replace('    private let prefillModel:MLModel','    var experimentStopToken: Int?\n    var experimentStopReason = "RUNNING"\n    private let prefillModel:MLModel',1)
    s=s.replace('                return decoded\n','                experimentStopToken=token; experimentStopReason="STOP_REGION"\n                return decoded\n',1)
    s=s.replace('            if decoded.count == prepared.maximumSpeechTokenCount {\n                return decoded','            if decoded.count == prepared.maximumSpeechTokenCount {\n                experimentStopReason="MAX_LENGTH"\n                return decoded',1)
    llm.write_text(s)
    engine=dest/'CosyVoice3Engine.swift'
    engine.write_text(engine.read_text()+'''
// Experiment-only diagnostics in this isolated copy; production code remains unchanged.
extension CosyVoice3Engine {
    public func experimentGenerate(text: String, output: URL) async throws {
        let frontend=try await reusableBaseFrontend()
        let prepared=try await frontend.prepare(text:text,reference:nil,instruction:nil)
        var receipt:[String:Any]=["text":text,"logicalPrefixLength":prepared.logicalPrefixLength,
            "minimumSpeechTokenCount":prepared.minimumSpeechTokenCount,"maximumSpeechTokenCount":prepared.maximumSpeechTokenCount,
            "sampling":"unchanged native SystemRandomNumberGenerator RAS","status":"RUNNING","productionPromotion":false]
        func save() throws { try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic) }
        try save()
        do {
            let prefill=try CosyVoice3AssetLoader.model(root:assetRoot,path:manifest.llmPrefill)
            let decode=try CosyVoice3AssetLoader.model(root:assetRoot,path:manifest.llmDecode)
            let llm=CosyVoice3LLMRuntime(prefillModel:prefill,decodeModel:decode,conditioner:try reusableConditioner())
            let tokens=try llm.generate(prepared)
            receipt["speechTokens"]=tokens;receipt["N"]=tokens.count
            receipt["stopToken"]=llm.experimentStopToken as Any? ?? NSNull()
            receipt["stopReason"]=llm.experimentStopReason
            receipt["actualEarlyEOS"]=(llm.experimentStopToken == CosyVoice3TokenSemantics.eos && tokens.count<prepared.maximumSpeechTokenCount)
            receipt["status"]="PASS_REAL_TEXT_LLM_TRACE_ACOUSTIC_PENDING";try save()
        } catch { receipt["status"]="FAIL";receipt["error"]=String(reflecting:error);try save();throw error }
    }

    public func experimentCapacityWalk(output: URL) async throws {
        let frontend=try await reusableBaseFrontend()
        var bestText="",bestPrepared:CosyVoice3PreparedRequest?
        for words in 1...64 {
            let candidate=Array(repeating:"test",count:words).joined(separator:" ")
            if let prepared=try? await frontend.prepare(text:candidate,reference:nil,instruction:nil) {
                if bestPrepared == nil || prepared.maximumSpeechTokenCount > bestPrepared!.maximumSpeechTokenCount {
                    bestText=candidate;bestPrepared=prepared
                }
            }
        }
        guard let prepared=bestPrepared else { throw NSError(domain:"LLMCapacityWalk",code:1) }
        var receipt:[String:Any]=[
            "schemaVersion":1,"status":"RUNNING","phase":"PREPARE_DONE",
            "text":bestText,"logicalPrefixLength":prepared.logicalPrefixLength,
            "targetTextTokenCount":prepared.minimumSpeechTokenCount/2,
            "minimumSpeechTokenCount":prepared.minimumSpeechTokenCount,
            "targetSpeechTokenCapacity":prepared.maximumSpeechTokenCount,
            "contextCapacity":CosyVoice3FP16StatefulLLMSession.capacity,
            "policy":"min(targetTextTokens*20,512-logicalPrefixLength)",
            "forcedSpeechToken":0,"forcedTokenMeaning":"capacity-only state walk; not semantic generation",
            "completedSpeechTokenCapacity":0,"productionPromotion":false,
            "progressUnix":Date().timeIntervalSince1970
        ]
        func save() throws {
            receipt["progressUnix"]=Date().timeIntervalSince1970
            try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
        }
        try save()
        do {
            receipt["phase"]="MODEL_LOAD_START";try save()
            let prefill=try CosyVoice3AssetLoader.model(root:assetRoot,path:manifest.llmPrefill)
            let decode=try CosyVoice3AssetLoader.model(root:assetRoot,path:manifest.llmDecode)
            let conditioner=try reusableConditioner()
            receipt["phase"]="MODEL_LOAD_DONE";try save()

            receipt["phase"]="SESSION_INIT_START";try save()
            let session=try CosyVoice3FP16StatefulLLMSession(
                prefillModel:prefill,decodeModel:decode,prefixLength:224,
                diagnosticHostWriteMask:true,logicalPrefixLength:prepared.logicalPrefixLength)
            receipt["phase"]="SESSION_INIT_DONE";try save()

            receipt["phase"]="PREFILL_START";try save()
            _=try session.prefill(prepared.prefillInput)
            receipt["phase"]="PREFILL_DONE"
            receipt["completedSpeechTokenCapacity"]=1
            try save()

            let token=0
            let embedding=try conditioner.embeddingFP16(token:token)
            if prepared.maximumSpeechTokenCount > 1 {
                for step in 0..<(prepared.maximumSpeechTokenCount-1) {
                    let absolutePosition=prepared.logicalPrefixLength+step
                    let rope=try conditioner.ropeFP16(position:absolutePosition)
                    receipt["phase"]="DECODE_START"
                    receipt["decodeStep"]=step
                    receipt["absolutePosition"]=absolutePosition
                    try save()
                    _=try autoreleasepool {
                        try session.decode(
                            embedding:embedding,cos:rope.cos,sin:rope.sin,
                            absolutePosition:absolutePosition)
                    }
                    receipt["phase"]="DECODE_DONE"
                    receipt["completedSpeechTokenCapacity"]=step+2
                    try save()
                }
            }
            receipt["phase"]="COMPLETE"
            receipt["status"]="PASS_LLM_STATE_CAPACITY_WALK_NOT_PROMOTED"
            try save()
        } catch {
            receipt["status"]="FAIL"
            receipt["error"]=String(reflecting:error)
            try save()
            throw error
        }
    }
}
''')
    (dest/'Entry.swift').write_text('''// Entry.swift
// Requirement: real text -> unchanged native LLM, with actual EOS/token count receipts.
import Foundation
@main struct TextProbe {
    static func main() async throws {
        let args=CommandLine.arguments
        let engine=try CosyVoice3Engine(assetRoot:URL(fileURLWithPath:args[1]))
        let out=URL(fileURLWithPath:args[2]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        for (i,text) in ["This is a CosyVoice3 production clean-room public API validation.","This is a CosyVoice3 public API reference voice validation."].enumerated() {
            print("REAL_TEXT_LLM_START \\(i) \\(text)")
            try await engine.experimentGenerate(text:text,output:out.appendingPathComponent("text-\\(i).json"))
            print("REAL_TEXT_LLM_COMPLETE \\(i)")
        }
    }
}
// Purpose: isolated experiment LLM trace. Upstream: current SDK copy.
// Environment: macOS15+ CoreML. Generated: 2026-10-04 America/New_York.
''')
    (a.output/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package=Package(name:"DynamicTextProbe",platforms:[.macOS(.v15)],
 dependencies:[.package(url:"https://github.com/huggingface/swift-transformers.git",exact:"1.3.4")],
 targets:[.executableTarget(name:"Probe",dependencies:[.product(name:"Tokenizers",package:"swift-transformers")],linkerSettings:[.linkedFramework("CoreML"),.linkedFramework("AVFoundation"),.linkedFramework("Accelerate")])])
''')
    engine_source=engine.read_text()
    marker='// Experiment-only diagnostics in this isolated copy; production code remains unchanged.'
    before,diagnostics=engine_source.split(marker,1)
    if a.llm_backend=='CPU_ONLY':
        diagnostics=diagnostics.replace('path:manifest.llmPrefill)','path:manifest.llmPrefill,computeUnits:.cpuOnly)').replace('path:manifest.llmDecode)','path:manifest.llmDecode,computeUnits:.cpuOnly)')
    diagnostics=diagnostics.replace('"sampling":"unchanged native SystemRandomNumberGenerator RAS"','"llmBackend":"'+a.llm_backend+'", "sampling":"unchanged native SystemRandomNumberGenerator RAS"')
    engine.write_text(before+marker+diagnostics)
    if a.library:
        (dest/'Entry.swift').unlink()
        package=(a.output/'Package.swift').read_text()
        package=package.replace('platforms:[.macOS(.v15)],','platforms:[.iOS(.v18),.macOS(.v15)],products:[.library(name:"TextProbeRuntime",targets:["Probe"])],')
        package=package.replace('.executableTarget(name:"Probe"','.target(name:"Probe"')
        (a.output/'Package.swift').write_text(package)
    identity={'sourceCommit':subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),
              'sdkSourceHashes':{f.name:sha(f) for f in (ROOT/'ios/Sources/CosyVoice3Core').glob('*.swift')},
              'experimentSourceHashes':{f.name:sha(f) for f in dest.glob('*.swift')},
              'instrumentation':'stop token/reason plus experiment-only deterministic state-capacity walk; native RAS/EOS and shipping source/assets unchanged',
              'fixed225CapRemoved':a.remove_fixed225_cap,
              'generationPolicy':('min(targetTextTokens*20,512-logicalPrefixLength)' if a.remove_fixed225_cap else 'min(targetTextTokens*20,225,512-logicalPrefixLength)'),
              'llmBackend':a.llm_backend,'generatorSha256':sha(Path(__file__))}
    (a.output/'identity.json').write_text(json.dumps(identity,indent=2)+'\n');print(json.dumps(identity,indent=2))
if __name__=='__main__':main()
# Purpose: make reviewable real-text provenance using an isolated instrumented copy.
# Upstream: current CosyVoice3 SDK. Environment: local macOS Python3.11 + Swift6.
# Generated: 2026-10-04 America/New_York. New file, all lines; cap unchanged.

# 2026-10-04: optional isolated iOS library for same native real-text generation
# in physical probe; no production target or SDK edits.

# 2026-10-04: explicit experiment-only LLM backend selection; no hidden fallback
# after physical CPU_AND_NE prefill execution-plan -14. Native RAS/EOS remain unchanged; cap225 removal is explicit opt-in only.

# 2026-10-04: --remove-fixed225-cap changes only the isolated probe copy from cap225 to the existing 512-context/20x generation policy; production SDK source and release assets remain byte-identical.

# 2026-10-04: remove accidental coremltools dependency from this lightweight generator; ROOT/sha are now local and require only Python stdlib.

# 2026-10-04: add deterministic experiment-only LLM state capacity walk targeting the maximum existing 20x/512 policy capacity; no sampler/model/shipping edits.
