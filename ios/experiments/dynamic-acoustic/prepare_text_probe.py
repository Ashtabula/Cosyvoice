# prepare_text_probe.py
# Requirement: create an isolated SDK copy for real-text LLM stop/token provenance without changing shipping code, sampler, cap or model bytes.
import argparse,hashlib,json,shutil,subprocess
from pathlib import Path
from probe_symbolic_conditions import ROOT,sha

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--library',action='store_true');p.add_argument('--llm-backend',choices=('CPU_ONLY','CPU_AND_NE'),default='CPU_AND_NE');a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=False)
    dest=a.output/'Sources/Probe';shutil.copytree(ROOT/'ios/Sources/CosyVoice3Core',dest)
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
    identity={'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
              'sdkSourceHashes':{f.name:sha(f) for f in (ROOT/'ios/Sources/CosyVoice3Core').glob('*.swift')},
              'instrumentation':'stop token/reason only; unchanged cap225/native RAS; no shipping edits',
              'llmBackend':a.llm_backend,'generatorSha256':sha(Path(__file__))}
    (a.output/'identity.json').write_text(json.dumps(identity,indent=2)+'\n');print(json.dumps(identity,indent=2))
if __name__=='__main__':main()
# Purpose: make reviewable real-text provenance using an isolated instrumented copy.
# Upstream: current CosyVoice3 SDK. Environment: local macOS Python3.11 + Swift6.
# Generated: 2026-10-04 America/New_York. New file, all lines; cap unchanged.

# 2026-10-04: optional isolated iOS library for same native real-text generation
# in physical probe; no production target or SDK edits.

# 2026-10-04: explicit experiment-only LLM backend selection; no hidden fallback
# after physical CPU_AND_NE prefill execution-plan -14. RAS and cap unchanged.
