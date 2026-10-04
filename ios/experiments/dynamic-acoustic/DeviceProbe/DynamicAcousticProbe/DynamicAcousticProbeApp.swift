// DynamicAcousticProbeApp.swift
// Requirement: physically test the same symbolic conditioning/shard0 family at N186 and N225, independently for CPU_ONLY and CPU_AND_NE, with phase-specific durable receipts.
import Accelerate
import CoreML
import Foundation
import SwiftUI
import Probe

@main
struct DynamicAcousticProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}
struct ProbeView: View {
    @State private var status = "Dynamic acoustic probe"
    var body: some View {
        Text(status).padding().task {
            UIApplication.shared.isIdleTimerDisabled = true
            let backend = ProcessInfo.processInfo.arguments.contains("CPU_AND_NE") ? "CPU_AND_NE" : "CPU_ONLY"
            do { try await Task.detached { try await Probe.run(backend: backend) }.value; status = "Completed \(backend); inspect receipt" }
            catch { status = String(describing: error) }
        }
    }
}
struct Probe {
    static func run(backend: String) async throws {
        if ProcessInfo.processInfo.arguments.contains("LLM_SWEEP") { try await LLMLengthSweepProbe.run(); return }
        if ProcessInfo.processInfo.arguments.contains("ACOUSTIC_SWEEP") { try await AcousticShapeSweepProbe.run(backend: backend); return }
        if ProcessInfo.processInfo.arguments.contains("ACOUSTIC") || ProcessInfo.processInfo.arguments.contains("TEXT") { try await AcousticProbe.run(backend: backend); return }
        let root = Bundle.main.resourceURL!.appendingPathComponent("GeneratedAssets")
        let document = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = document.appendingPathComponent("dynamic-probe-\(backend).json")
        let identity = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("identity.json")))
        var receipt: [String: Any] = ["recordedAtUnix": Date().timeIntervalSince1970, "schemaVersion": 1, "status": "RUNNING", "backend": backend, "backendMeaning": "requested MLComputeUnits; not ANE residency", "physicalDevice": true, "deviceOS": ProcessInfo.processInfo.operatingSystemVersionString, "assetIdentity": identity, "tests": [[String: Any]]()]
        func save() throws {
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: path, options: .atomic)
        }
        try save()
        var rows = [[String: Any]]()
        for role in ["conditions", "shard0"] {
            var model: MLModel?
            var phase = "compilation"
            do {
                receipt["phase"] = "\(role)_\(phase)"; try save()
                let compiled = try await MLModel.compileModel(at: root.appendingPathComponent("\(role).mlpackage"))
                receipt["\(role)Compilation"] = "PASS"
                phase = "loading"; receipt["phase"] = "\(role)_\(phase)"; try save()
                let config = MLModelConfiguration()
                config.computeUnits = backend == "CPU_ONLY" ? .cpuOnly : .cpuAndNeuralEngine
                config.optimizationHints.reshapeFrequency = .infrequent
                model = try await MLModel(contentsOf: compiled, configuration: config)
                receipt["\(role)Loading"] = "PASS"; try save()
                do {
                    let plan = try await MLComputePlan.load(contentsOf: compiled, configuration: config)
                    var counts = [String: Int]()
                    if case let .program(program) = plan.modelStructure {
                        func visit(_ block: MLModelStructure.Program.Block) {
                            for op in block.operations {
                                if let usage = plan.deviceUsage(for: op) {
                                    counts[usage.preferred.description, default:0] += 1
                                }
                                for child in op.blocks { visit(child) }
                            }
                        }
                        for function in program.functions.values { visit(function.block) }
                    }
                    receipt["\(role)ComputePlanPreferredCounts"] = counts
                    receipt["computePlanMeaning"] = "preferred placement hints; not measured execution residency"
                } catch { receipt["\(role)ComputePlanError"] = errorRecord(error) }
                try save()
            } catch {
                receipt["\(role)Failure"] = ["phase": phase, "error": errorRecord(error)]
                try save(); continue
            }
            for n in [186,225] {
                let t = 302+2*n
                var row: [String: Any] = ["role": role, "N": n, "G": 2*n, "P": 302, "T": t, "status": "RUNNING", "backend": backend, "symbolicSourceGraph": true]
                var phase = "input_loading"
                do {
                    receipt["phase"] = "\(role)_N\(n)_\(phase)"; try save()
                    let shapes: [String: [Int]] = role == "conditions" ? ["tokens":[1,n],"prompt_tokens":[1,151],"prompt_feat":[1,302,80],"speaker":[1,192]] : ["x":[2,80,t],"mask":[2,1,t],"mu":[2,80,t],"t":[2],"spks":[2,80],"cond":[2,80,t]]
                    let folder = root.appendingPathComponent("\(role)/N\(n)")
                    var feed = [String: MLMultiArray]()
                    for (name,shape) in shapes {
                        let data = try Data(contentsOf: folder.appendingPathComponent("\(name).bin"))
                        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: role == "conditions" && ["tokens","prompt_tokens"].contains(name) ? .int32 : .float32)
                        guard data.count == array.count*4 else { throw NSError(domain: "ProbeInputSize", code: 1, userInfo: [NSLocalizedDescriptionKey:name]) }
                        data.withUnsafeBytes { array.dataPointer.copyMemory(from:$0.baseAddress!,byteCount:data.count) }
                        feed[name] = array
                    }
                    row["inputShapes"] = shapes
                    phase = "first_prediction"; receipt["phase"] = "\(role)_N\(n)_\(phase)"; receipt["pendingTest"] = row; try save()
                    let start = Date()
                    let prediction = try await model!.prediction(from: MLDictionaryFeatureProvider(dictionary: feed))
                    row["milliseconds"] = Date().timeIntervalSince(start)*1000
                    var outputMetrics = [String: Any]()
                    for name in role == "conditions" ? ["mu","spks","cond"] : ["h","te"] {
                        guard let actual = prediction.featureValue(for: name)?.multiArrayValue else { throw NSError(domain:"ProbeOutput",code:1) }
                        let expectedShape = role == "conditions" ? (name == "spks" ? [2,80] : [2,80,t]) : (name == "h" ? [2,t,1024] : [2,1024])
                        guard actual.shape.map(\.intValue) == expectedShape else { throw NSError(domain:"ProbeOutputShape",code:1,userInfo:[NSLocalizedDescriptionKey: "\(name) \(actual.shape)"]) }
                        let data = try Data(contentsOf: folder.appendingPathComponent("expected-\(name).bin"))
                        let expected = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                        guard actual.count == expected.count else { throw NSError(domain:"ProbeOutputSize",code:actual.count) }
                        var maxAbs = 0.0, absSum = 0.0, sqSum = 0.0, aa = 0.0, bb = 0.0, ab = 0.0, finite = true
                        for i in expected.indices {
                            let a = Double(expected[i]), b = actual[i].doubleValue, d = a-b
                            finite = finite && a.isFinite && b.isFinite
                            maxAbs = max(maxAbs,abs(d)); absSum += abs(d); sqSum += d*d; aa += a*a; bb += b*b; ab += a*b
                        }
                        var metric: [String: Any] = ["outputShape":actual.shape.map(\.intValue), "finite":finite]
                        if finite {
                            metric["maxAbsError"] = maxAbs
                            metric["meanAbsError"] = absSum/Double(expected.count)
                            metric["rmse"] = sqrt(sqSum/Double(expected.count))
                            metric["cosineSimilarity"] = aa*bb>0 ? ab/sqrt(aa*bb) : 1.0
                        }
                        outputMetrics[name] = metric
                    }
                    row["outputs"] = outputMetrics; row["status"] = "EXECUTED_NUMERICS_RECORDED_NOT_ACCEPTED"
                } catch {
                    row["status"] = "FAIL"; row["failurePhase"] = phase; row["error"] = errorRecord(error)
                }
                rows.append(row); receipt["tests"] = rows; receipt.removeValue(forKey:"pendingTest"); try save()
                print("DYNAMIC_ACOUSTIC_PROBE \(role) N\(n) \(row["status"]!)")
            }
            model = nil
        }
        receipt["status"] = rows.count == 4 && rows.allSatisfy { $0["status"] as? String == "EXECUTED_NUMERICS_RECORDED_NOT_ACCEPTED" } ? "EXECUTED_ALL_NUMERICS_RECORDED_NOT_ACCEPTED" : "FAIL"
        receipt["phase"] = "complete"; try save()
        print("DYNAMIC_ACOUSTIC_RECEIPT \(path.path)")
    }
    static func errorRecord(_ error: Error) -> [String: Any] {
        let e = error as NSError
        return ["domain":e.domain,"code":e.code,"description":e.localizedDescription,"debug":String(reflecting:error),"userInfo":String(describing:e.userInfo)]
    }
}
// Purpose: isolated physical dynamic graph probe; failures remain machine-readable and both natural lengths share identical model bytes.
// Upstream: symbolic exact official Flow conditions and FirstShard, CosyVoice3_NPU@8789402; no LLM/EOS change.
// Environment: signed Release iOS18+ CoreML, physical iPhone. Generated: 2026-10-03 America/New_York.
// New file, all lines; numerical acceptance is separate from successful execution and requested backend.

// Changes 2026-10-03: line45 sets reshapeFrequency through optimizationHints; lines85-92 split metrics for reliable Swift type checking.

// Changes 2026-10-03: async compute-plan preferred placement hints, wall-clock receipt timestamp, exact output-shape guards; physical execution still does not establish residency.


enum LLMLengthSweepProbe {
    static let corpus=[
        "Hi.",
        "Hello.",
        "Good morning.",
        "Please read this sentence.",
        "This is a short CosyVoice3 synthesis test.",
        "This is a CosyVoice3 production clean-room public API validation.",
        "This is a CosyVoice3 public API reference voice validation.",
        "CosyVoice3 should synthesize natural speech from arbitrary input text while preserving the model's native stochastic sampling behavior and stopping when the real end-of-speech token is generated."
    ]
    static func run() async throws {
        let root=Bundle.main.resourceURL!.appendingPathComponent("GeneratedAssets/text-runtime")
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let repeats=ProcessInfo.processInfo.arguments.compactMap { $0.hasPrefix("RUNS=") ? Int($0.dropFirst(5)) : nil }.first ?? 32
        guard repeats>0 else { throw NSError(domain:"LLMLengthSweepRuns",code:repeats) }
        let path=docs.appendingPathComponent("llm-length-sweep.json")
        let identity=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("identity.json")))
        var receipt:[String:Any]=["schemaVersion":1,"status":"RUNNING","recordedAtUnix":Date().timeIntervalSince1970,"physicalDevice":true,"deviceOS":ProcessInfo.processInfo.operatingSystemVersionString,"runtimeIdentity":identity,"sampling":"unchanged native SystemRandomNumberGenerator RAS","repeatsPerText":repeats,"productionPromotion":false,"runs":[[String:Any]]()]
        func save() throws { try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:path,options:.atomic) }
        try save()
        let engine=try CosyVoice3Engine(assetRoot:root)
        var rows=[[String:Any]]()
        for (textIndex,text) in corpus.enumerated() {
            for runIndex in 0..<repeats {
                receipt["phase"]="text\(textIndex)_run\(runIndex)";try save()
                let one=docs.appendingPathComponent("llm-length-sweep-t\(textIndex)-r\(runIndex).json")
                var row:[String:Any]=["textIndex":textIndex,"runIndex":runIndex,"text":text,"status":"RUNNING"]
                do {
                    try await engine.experimentGenerate(text:text,output:one)
                    let trace=try JSONSerialization.jsonObject(with:Data(contentsOf:one)) as! [String:Any]
                    row["N"]=trace["N"];row["stopToken"]=trace["stopToken"];row["stopReason"]=trace["stopReason"];row["actualEarlyEOS"]=trace["actualEarlyEOS"];row["logicalPrefixLength"]=trace["logicalPrefixLength"];row["minimumSpeechTokenCount"]=trace["minimumSpeechTokenCount"];row["maximumSpeechTokenCount"]=trace["maximumSpeechTokenCount"];row["status"]="PASS_RECORDED"
                } catch { row["status"]="FAIL";row["error"]=Probe.errorRecord(error) }
                try? FileManager.default.removeItem(at:one)
                rows.append(row);receipt["runs"]=rows;try save()
                print("LLM_LENGTH_SWEEP text\(textIndex) run\(runIndex) N=\(row["N"] ?? "NA") stop=\(row["stopReason"] ?? "NA") status=\(row["status"]!)")
            }
        }
        let successful=rows.filter { $0["status"] as? String == "PASS_RECORDED" }, ns=successful.compactMap { $0["N"] as? Int }
        var histogram=[String:Int]();for n in ns { histogram[String(n),default:0]+=1 }
        let earlyEOS=successful.filter { $0["actualEarlyEOS"] as? Bool == true }.count
        let capHits=successful.filter { $0["stopReason"] as? String == "MAX_LENGTH" }.count
        receipt["summary"]=["successfulRuns":successful.count,"failedRuns":rows.count-successful.count,"minN":ns.min() as Any? ?? NSNull(),"maxN":ns.max() as Any? ?? NSNull(),"uniqueN":Array(Set(ns)).sorted(),"histogram":histogram,"earlyEOSRuns":earlyEOS,"maxLengthRuns":capHits]
        receipt["phase"]="complete";receipt["status"]=successful.count==rows.count ? "PASS_LLM_LENGTH_SWEEP_RECORDED_NOT_PROMOTED":"COMPLETE_LLM_LENGTH_SWEEP_WITH_FAILURES_NOT_PROMOTED";try save()
        print("LLM_LENGTH_SWEEP_RECEIPT \(path.path)")
    }
}
// Purpose: physical-device production-RAS output-length distribution sweep; no seed injection, EOS suppression, cap change or shipping edit.
// Upstream: isolated TextProbeRuntime generated from current CosyVoice3 SDK.
// Runtime: physical iPhone, LLM backend recorded by staged text-runtime identity.
// Generated: 2026-10-04 America/New_York.

enum CosyVoice3HiFTError: Error { case sizeMismatch(String,Int,Int); case invalidMelShape([Int]) }

final class CosyVoice3HiFTDoubleF0 {
    private struct Layer { let inputs:Int; let outputs:Int; let kernel:Int; let right:Bool; let weights:[Double]; let bias:[Double] }
    private var layers:[Layer]=[]
    private let classifier:[Double]
    private let classifierBias:Double
    init(folder:URL) throws {
        func read(_ name:String,count:Int) throws -> [Double] { let data=try Data(contentsOf:folder.appendingPathComponent(name+".bin")); guard data.count==count*8 else { throw CosyVoice3HiFTError.sizeMismatch(name,count*8,data.count) }; return data.withUnsafeBytes { Array($0.bindMemory(to:Double.self)) } }
        classifier=try read("f0-classifier-weight",count:512); classifierBias=try read("f0-classifier-bias",count:1)[0]
        for i in 0..<5 { let inputs=i==0 ? 80:512, kernel=i==0 ? 4:3; layers.append(.init(inputs:inputs,outputs:512,kernel:kernel,right:i==0,weights:try read("f0-\(i)-weight",count:512*inputs*kernel),bias:try read("f0-\(i)-bias",count:512))) }
    }
    func prediction(mel:MLMultiArray) throws -> MLMultiArray {
        let frames=mel.shape[2].intValue, shape=mel.shape.map(\.intValue); guard shape == [1,80,frames] else { throw CosyVoice3HiFTError.invalidMelShape(shape) }
        var x=(0..<mel.count).map { mel[$0].doubleValue }
        for layer in layers {
            let k=layer.inputs*layer.kernel; var columns=[Double](repeating:0,count:k*frames)
            for c in 0..<layer.inputs { for tap in 0..<layer.kernel { let offset=layer.right ? tap:tap-(layer.kernel-1), row=(c*layer.kernel+tap)*frames; for t in 0..<frames { let source=t+offset; if source>=0 && source<frames { columns[row+t]=x[c*frames+source] } } } }
            var y=[Double](repeating:0,count:layer.outputs*frames)
            layer.weights.withUnsafeBufferPointer { w in columns.withUnsafeBufferPointer { input in y.withUnsafeMutableBufferPointer { out in cblas_dgemm(CblasRowMajor,CblasNoTrans,CblasNoTrans,Int32(layer.outputs),Int32(frames),Int32(k),1,w.baseAddress!,Int32(k),input.baseAddress!,Int32(frames),0,out.baseAddress!,Int32(frames)) } } }
            for c in 0..<layer.outputs { for t in 0..<frames { let v=y[c*frames+t]+layer.bias[c]; y[c*frames+t]=v>0 ? v:expm1(v) } }; x=y
        }
        let result=try MLMultiArray(shape:[1,NSNumber(value:frames)],dataType:.float32), ptr=result.dataPointer.assumingMemoryBound(to:Float.self)
        for t in 0..<frames { var value=classifierBias; for c in 0..<512 { value += x[c*frames+t]*classifier[c] }; ptr[t]=Float(abs(value)) }
        return result
    }
}

// Purpose: exact validated Double convolution/ELU/linear F0 math extracted from StatefulLLMBench without benchmark dependencies.
// Upstream: HiFTDoubleF0.swift at CosyVoice3_NPU@8789402; only BenchmarkError was replaced by SDK-local typed errors.
// Runtime: iOS Accelerate + CoreML.
// Generated: 2026-10-02 America/New_York.

// Experiment-only complete acoustic probe; existing Phase1 probe remains selectable.
enum AcousticProbe {
    static func array(_ values: [Float], _ shape: [Int]) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        guard a.count == values.count else { throw NSError(domain:"AcousticInputShape",code:1) }
        values.withUnsafeBufferPointer { a.dataPointer.assumingMemoryBound(to:Float.self).update(from:$0.baseAddress!,count:values.count) }
        return a
    }
    static func values(_ a: MLMultiArray) -> [Float] {
        var contiguous=true, stride=1
        for axis in a.shape.indices.reversed() { if a.shape[axis].intValue>1 && a.strides[axis].intValue != stride { contiguous=false }; stride *= a.shape[axis].intValue }
        if contiguous && a.dataType == .float32 { return Array(UnsafeBufferPointer(start:a.dataPointer.assumingMemoryBound(to:Float.self),count:a.count)) }
        return (0..<a.count).map { a[$0].floatValue }
    }
    static func floats(_ path: URL) throws -> [Float] {
        try Data(contentsOf:path).withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
    }
    static func read(_ folder: URL, _ name: String, _ shape: [Int], integer: Bool=false) throws -> MLMultiArray {
        let data=try Data(contentsOf:folder.appendingPathComponent(name+".bin"))
        let a=try MLMultiArray(shape:shape.map(NSNumber.init),dataType:integer ? .int32:.float32)
        guard a.count*4==data.count else { throw NSError(domain:"AcousticInputBytes",code:data.count) }
        data.withUnsafeBytes { a.dataPointer.copyMemory(from:$0.baseAddress!,byteCount:data.count) }
        return a
    }
    static func output(_ result: MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        guard let a=result.featureValue(for:name)?.multiArrayValue else { throw NSError(domain:"AcousticOutput",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }; return a
    }
    static func metric(_ expected: [Float], _ actual: [Float]) throws -> [String:Any] {
        guard expected.count==actual.count else { throw NSError(domain:"AcousticMetricShape",code:actual.count) }
        var aa=0.0,bb=0.0,ab=0.0,ss=0.0,maximum=0.0
        for i in actual.indices { let a=Double(expected[i]),b=Double(actual[i]),d=a-b; aa+=a*a;bb+=b*b;ab+=a*b;ss+=d*d;maximum=max(maximum,abs(d)) }
        guard actual.allSatisfy(\.isFinite) else { return ["finite":false] }
        return ["finite":true,"maxAbsError":maximum,"rmse":sqrt(ss/Double(actual.count)),"relativeL2":sqrt(ss/max(aa,1e-30)),"cosineSimilarity":ab/sqrt(max(aa*bb,1e-30))]
    }
    static func run(backend: String) async throws {
        let root=Bundle.main.resourceURL!.appendingPathComponent("GeneratedAssets/acoustic")
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let textMode=ProcessInfo.processInfo.arguments.contains("TEXT")
        let prefix=textMode ? "dynamic-text-acoustic":"dynamic-acoustic"
        let path=docs.appendingPathComponent("\(prefix)-\(backend).json")
        let identity=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("identity.json")))
        var receipt:[String:Any]=["schemaVersion":1,"status":"RUNNING","recordedAtUnix":Date().timeIntervalSince1970,"physicalDevice":true,"deviceOS":ProcessInfo.processInfo.operatingSystemVersionString,"backend":backend,"backendMeaning":"requested compute units; no residency claim","assetIdentity":identity,"productionPromotion":false,"tests":[[String:Any]]()]
        func save() throws { try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:path,options:.atomic) }
        try save()
        do {
            var traces=[[String:Any]]()
            if textMode {
                let textRoot=Bundle.main.resourceURL!.appendingPathComponent("GeneratedAssets/text-runtime")
                receipt["textRuntimeIdentity"]=try JSONSerialization.jsonObject(with:Data(contentsOf:textRoot.appendingPathComponent("identity.json")));try save()
                func trace(_ text: String, _ index: Int) async throws -> [String:Any] {
                    let engine=try CosyVoice3Engine(assetRoot:textRoot)
                    let output=docs.appendingPathComponent("device-text-\(index).json")
                    try await engine.experimentGenerate(text:text,output:output)
                    return try JSONSerialization.jsonObject(with:Data(contentsOf:output)) as! [String:Any]
                }
                for (index,text) in ["This is a CosyVoice3 production clean-room public API validation.","This is a CosyVoice3 public API reference voice validation."].enumerated() {
                    receipt["phase"]="real_text_llm_\(index)";try save()
                    traces.append(try await trace(text,index));receipt["realTextTraces"]=traces;try save()
                    print("DYNAMIC_REAL_TEXT_LLM \(index) N=\(traces.last!["N"]!) stop=\(traces.last!["stopToken"]!)")
                }
            }
            let config=MLModelConfiguration(); config.computeUnits=backend=="CPU_ONLY" ? .cpuOnly:.cpuAndNeuralEngine; config.optimizationHints.reshapeFrequency = .infrequent
            var compiledModels=[URL](), placements=[String:Any]()
            for role in ["conditions"]+(0..<6).map({"flow-\($0)"})+["hift"] {
                receipt["phase"]="\(role)_compile";try save()
                let compiled=try await MLModel.compileModel(at:root.appendingPathComponent("\(role).mlpackage"))
                receipt["phase"]="\(role)_load";try save()
                compiledModels.append(compiled)
                do {
                    let plan=try await MLComputePlan.load(contentsOf:compiled,configuration:config)
                    var counts=[String:Int]()
                    if case let .program(program)=plan.modelStructure {
                        func visit(_ block:MLModelStructure.Program.Block) { for op in block.operations { if let use=plan.deviceUsage(for:op) { counts[use.preferred.description,default:0]+=1 }; for child in op.blocks { visit(child) } } }
                        for function in program.functions.values { visit(function.block) }
                    }
                    placements[role]=counts
                } catch { placements[role]=Probe.errorRecord(error) }
                receipt["computePlanPreferredCounts"]=placements;try save()
            }
            receipt["modelLifecycle"]="One request-scoped MLModel per prediction, released through autoreleasepool; compiled URLs shared across lengths"
            func predict(_ index: Int, _ feed: [String:MLMultiArray]) throws -> MLFeatureProvider {
                try autoreleasepool {
                    let model=try MLModel(contentsOf:compiledModels[index],configuration:config)
                    return try model.prediction(from:MLDictionaryFeatureProvider(dictionary:feed))
                }
            }
            let f0=try CosyVoice3HiFTDoubleF0(folder:root.appendingPathComponent("f0-double"))
            var rows=[[String:Any]]()
            let counts=textMode ? traces.map { $0["N"] as! Int } : ((identity as? [String:Any])?["counts"] as? [Int] ?? [186,225])
            let supported=(identity as? [String:Any])?["supportedNBounds"] as? [Int] ?? [151,225]
            for n in counts { guard n>=supported[0] && n<=supported[1] else { throw NSError(domain:"ObservedTextOutsideExportedRange",code:n) } }
            let baseFolder=root.appendingPathComponent("N225")
            for (testIndex,n) in counts.enumerated() {
                let t=302+2*n,g=2*n,samples=g*480,folder=textMode ? baseFolder:root.appendingPathComponent("N\(n)")
                receipt["phase"]="conditions_N\(n)";try save()
                let tokenArray: MLMultiArray
                if textMode {
                    tokenArray=try MLMultiArray(shape:[1,NSNumber(value:n)],dataType:.int32)
                    let tokens=traces[testIndex]["speechTokens"] as! [Int]
                    for i in 0..<n { tokenArray[i]=NSNumber(value:tokens[i]) }
                } else { tokenArray=try read(folder,"tokens",[1,n],integer:true) }
                let feed=["tokens":tokenArray,"prompt_tokens":try read(folder,"prompt_tokens",[1,151],integer:true),"prompt_feat":try read(folder,"prompt_feat",[1,302,80]),"speaker":try read(folder,"speaker",[1,192])]
                let conditions=try predict(0,feed)
                let mu=try output(conditions,"mu"),spks=try output(conditions,"spks"),cond=try output(conditions,"cond")
                let mask=try array([Float](repeating:1,count:2*t),[2,1,t])
                var x=try floats(folder.appendingPathComponent("noise.bin"))
                if textMode { let original=x; x=[Float](repeating:0,count:80*t); for c in 0..<80 { for j in 0..<t { x[c*t+j]=original[c*752+j] } } }
                let span=(0...6).map { 1-cos(Float($0)/6*Float.pi/2) }
                for step in 0..<6 {
                    receipt["phase"]="flow_N\(n)_step\(step)";try save()
                    var shardFeed=["x":try array(x+x,[2,80,t]),"mask":mask,"mu":mu,"spks":spks,"cond":cond,"t":try array([span[step],span[step]],[2])]
                    var velocity:[Float]=[]
                    for shard in 0..<6 {
                        receipt["phase"]="flow_N\(n)_step\(step)_shard\(shard)";try save()
                        let result=try predict(shard+1,shardFeed)
                        if shard==0 { shardFeed=["h":try output(result,"h"),"te":try output(result,"te"),"mask":mask] }
                        else if shard<5 { shardFeed["h"]=try output(result,"h_out") }
                        else { velocity=values(try output(result,"velocity")) }
                    }
                    guard velocity.count==x.count*2 else { throw NSError(domain:"AcousticVelocityShape",code:velocity.count) }
                    let dt=span[step+1]-span[step]
                    for i in x.indices { x[i]+=dt*(1.7*velocity[i]-0.7*velocity[i+x.count]) }
                    print("DYNAMIC_ACOUSTIC_FLOW N\(n) step\(step) complete")
                }
                var melValues=[Float](repeating:0,count:80*g)
                for c in 0..<80 { for j in 0..<g { melValues[c*g+j]=x[c*t+302+j] } }
                let mel=try array(melValues,[1,80,g])
                receipt["phase"]="f0_N\(n)";try save()
                let f0Values=try f0.prediction(mel:mel)
                var phase=[Float](repeating:0,count:g*9),sums=[Double](repeating:0,count:9)
                for j in 0..<g { for h in 0..<9 { let rad=(f0Values[j].floatValue*Float(h+1)/24000).truncatingRemainder(dividingBy:1);sums[h]+=Double(rad);phase[j*9+h]=Float(sums[h])*Float(2*Double.pi) } }
                receipt["phase"]="hift_N\(n)";try save()
                let excitation: MLMultiArray, norm: MLMultiArray
                if textMode {
                    excitation=try array(Array(try floats(baseFolder.appendingPathComponent("hift-noise.bin")).prefix(samples*9)),[1,samples,9])
                    let window=(0..<16).map { Float(0.5-0.5*cos(2*Double.pi*Double($0)/16)) }
                    var weights=[Float](repeating:0,count:samples)
                    for j in 0..<samples { let pos=j+8; let low=max(0,(pos-15+3)/4),high=min(samples/4,pos/4); if low<=high { for k in low...high { weights[j]+=window[pos-4*k]*window[pos-4*k] } } }
                    norm=try array(weights,[1,1,samples])
                } else { excitation=try read(folder,"hift-noise",[1,samples,9]);norm=try read(folder,"norm",[1,1,samples]) }
                let hiftFeed=["mel":mel,"f0":f0Values,"phase":try array(phase,[1,g,9]),"noise":excitation,"norm":norm]
                let result=try predict(7,hiftFeed)
                let pcmArray=try output(result,"pcm"),pcm=values(pcmArray)
                guard pcmArray.shape.map(\.intValue)==[1,samples],pcm.allSatisfy(\.isFinite),melValues.allSatisfy(\.isFinite) else { throw NSError(domain:"AcousticPCMShapeOrFinite",code:pcm.count) }
                var row:[String:Any]=["N":n,"T":t,"G":g,"samples":pcm.count,"finite":true,"pcmShape":pcmArray.shape.map(\.intValue),"status":"PASS_PHYSICAL_EXECUTION_NUMERICS_RECORDED_NOT_PROMOTED"]
                if !textMode {
                    row["melVsHost"]=try metric(floats(folder.appendingPathComponent("expected-mel.bin")),melValues)
                    row["pcmVsHost"]=try metric(floats(folder.appendingPathComponent("expected-pcm.bin")),pcm)
                } else { row["textIndex"]=testIndex;row["actualEarlyEOS"]=traces[testIndex]["actualEarlyEOS"] }
                let pcmName=textMode ? "\(prefix)-\(backend)-text\(testIndex)-N\(n).f32" : "\(prefix)-\(backend)-N\(n).f32"
                row["pcmFileName"]=pcmName
                try pcm.withUnsafeBytes { try Data($0).write(to:docs.appendingPathComponent(pcmName)) }
                if textMode { try melValues.withUnsafeBytes { try Data($0).write(to:docs.appendingPathComponent("device-text-\(testIndex)-mel.f32")) } }
                rows.append(row);receipt["tests"]=rows;try save()
                print("DYNAMIC_ACOUSTIC_PCM N\(n) samples=\(pcm.count)")
            }
            receipt["phase"]="complete";receipt["status"]=textMode ? (traces.allSatisfy { $0["actualEarlyEOS"] as? Bool == true } ? "PASS_PHYSICAL_REAL_TEXT_NATURAL_PCM_EXECUTION_NOT_PROMOTED":"FAIL_REAL_TEXT_EARLY_EOS_NOT_OBSERVED") : "PASS_PHYSICAL_DYNAMIC_ACOUSTIC_EXECUTION_NOT_PROMOTED";try save()
        } catch { receipt["status"]="FAIL";receipt["error"]=Probe.errorRecord(error);try save();throw error }
        print("DYNAMIC_ACOUSTIC_RECEIPT \(path.path)")
    }
}
// 2026-10-04 America/New_York: adds isolated full six-step dynamic Flow -> FP64 F0
// -> host phase -> HiFT physical probe; copies unchanged SDK F0 math above. Same
// packages serve both lengths, durable per-shard phases and preferred-plan hints.

// 2026-10-04: replace simultaneous MLModel retention with per-prediction
// autoreleasepool lifetime after SIGKILL at flow-4_load; model math/bytes unchanged.

// 2026-10-04: host-bound identity supplies observed EOS counts; PCM write errors
// propagate into durable failure receipt instead of being discarded.

// 2026-10-04: TEXT mode runs unchanged native frontend/LLM in isolated SDK
// library, releases LLM scope, feeds actual tokens into the dynamic acoustic
// family; validates exported bounds, records EOS/count and natural PCM.

// 2026-10-04: close TEXT mel receipt write scope; distinct text-index PCM names
// preserve both utterances even when their sampled token counts happen to match.


enum AcousticShapeSweepProbe {
    static func run(backend:String) async throws {
        let root=Bundle.main.resourceURL!.appendingPathComponent("GeneratedAssets/acoustic")
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let identity=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("identity.json"))) as! [String:Any]
        let exported=identity["supportedNBounds"] as? [Int] ?? [151,225]
        let requestedMin=ProcessInfo.processInfo.arguments.compactMap { $0.hasPrefix("NMIN=") ? Int($0.dropFirst(5)) : nil }.first ?? exported[0]
        let requestedMax=ProcessInfo.processInfo.arguments.compactMap { $0.hasPrefix("NMAX=") ? Int($0.dropFirst(5)) : nil }.first ?? exported[1]
        guard requestedMin>=exported[0],requestedMax<=exported[1],requestedMin<=requestedMax else { throw NSError(domain:"AcousticShapeSweepBounds",code:1,userInfo:[NSLocalizedDescriptionKey:"requested \(requestedMin)...\(requestedMax), exported \(exported)"]) }
        let path=docs.appendingPathComponent("dynamic-acoustic-shape-sweep-\(backend)-N\(requestedMin)-\(requestedMax).json")
        var receipt:[String:Any]=["schemaVersion":1,"status":"RUNNING","recordedAtUnix":Date().timeIntervalSince1970,"physicalDevice":true,"deviceOS":ProcessInfo.processInfo.operatingSystemVersionString,"backend":backend,"backendMeaning":"requested compute units; no residency claim","assetIdentity":identity,"exportedNBounds":exported,"requestedNBounds":[requestedMin,requestedMax],"productionPromotion":false,"tests":[[String:Any]]()]
        func save() throws { try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:path,options:.atomic) }
        try save()
        let config=MLModelConfiguration();config.computeUnits=backend=="CPU_ONLY" ? .cpuOnly:.cpuAndNeuralEngine;config.optimizationHints.reshapeFrequency = .infrequent
        var compiled=[URL]()
        for role in ["conditions"]+(0..<6).map({"flow-\($0)"})+["hift"] {
            receipt["phase"]="compile_\(role)";try save()
            compiled.append(try await MLModel.compileModel(at:root.appendingPathComponent("\(role).mlpackage")))
        }
        func predict(_ index:Int,_ feed:[String:MLMultiArray]) throws -> MLFeatureProvider {
            try autoreleasepool { let model=try MLModel(contentsOf:compiled[index],configuration:config);return try model.prediction(from:MLDictionaryFeatureProvider(dictionary:feed)) }
        }
        let base=root.appendingPathComponent("N225"),baseTokens=try AcousticProbe.read(base,"tokens",[1,225],integer:true),promptTokens=try AcousticProbe.read(base,"prompt_tokens",[1,151],integer:true),promptFeat=try AcousticProbe.read(base,"prompt_feat",[1,302,80]),speaker=try AcousticProbe.read(base,"speaker",[1,192]),baseNoise=try AcousticProbe.floats(base.appendingPathComponent("noise.bin")),baseExcitation=try AcousticProbe.floats(base.appendingPathComponent("hift-noise.bin"))
        let f0=try CosyVoice3HiFTDoubleF0(folder:root.appendingPathComponent("f0-double"))
        func tokens(_ n:Int) throws -> MLMultiArray { let a=try MLMultiArray(shape:[1,NSNumber(value:n)],dataType:.int32);for i in 0..<n { a[i]=i<225 ? baseTokens[i]:0 };return a }
        func conditioningFeed(_ n:Int) throws -> [String:MLMultiArray] { ["tokens":try tokens(n),"prompt_tokens":promptTokens,"prompt_feat":promptFeat,"speaker":speaker] }
        func norm(_ samples:Int) throws -> MLMultiArray {
            let window=(0..<16).map { Float(0.5-0.5*cos(2*Double.pi*Double($0)/16)) };var weights=[Float](repeating:0,count:samples)
            for j in 0..<samples { let pos=j+8,low=max(0,(pos-15+3)/4),high=min(samples/4,pos/4);if low<=high { for k in low...high { weights[j]+=window[pos-4*k]*window[pos-4*k] } } }
            return try AcousticProbe.array(weights,[1,1,samples])
        }
        var boundary=[[String:Any]]()
        if requestedMin==exported[0] && requestedMax==exported[1] {
            for n in [exported[0]-1,exported[1]+1] {
                var row:[String:Any]=["N":n,"expected":"REJECT_OUT_OF_RANGE"]
                do { _=try predict(0,try conditioningFeed(n));row["status"]="FAIL_ACCEPTED_OUT_OF_RANGE" }
                catch { row["status"]="PASS_REJECTED_OUT_OF_RANGE";row["error"]=Probe.errorRecord(error) }
                boundary.append(row);receipt["negativeBoundaryTests"]=boundary;try save()
            }
        }
        var rows=[[String:Any]]()
        for n in requestedMin...requestedMax {
            let start=Date(),t=302+2*n,g=2*n,samples=960*n
            var row:[String:Any]=["N":n,"T":t,"G":g,"expectedSamples":samples,"status":"RUNNING"]
            do {
                receipt["phase"]="N\(n)_conditions";try save()
                let conditions=try predict(0,try conditioningFeed(n)),mu=try AcousticProbe.output(conditions,"mu"),spks=try AcousticProbe.output(conditions,"spks"),cond=try AcousticProbe.output(conditions,"cond")
                guard mu.shape.map(\.intValue)==[2,80,t],spks.shape.map(\.intValue)==[2,80],cond.shape.map(\.intValue)==[2,80,t] else { throw NSError(domain:"AcousticShapeSweepConditionsShape",code:n) }
                let mask=try AcousticProbe.array([Float](repeating:1,count:2*t),[2,1,t]);var x=[Float](repeating:0,count:80*t)
                for c in 0..<80 { for j in 0..<t { x[c*t+j]=baseNoise[c*752+j] } }
                let span=(0...6).map { 1-cos(Float($0)/6*Float.pi/2) }
                for step in 0..<6 {
                    receipt["phase"]="N\(n)_flow_step\(step)";try save()
                    var feed=["x":try AcousticProbe.array(x+x,[2,80,t]),"mask":mask,"mu":mu,"spks":spks,"cond":cond,"t":try AcousticProbe.array([span[step],span[step]],[2])],velocity:[Float]=[]
                    for shard in 0..<6 {
                        let result=try predict(shard+1,feed)
                        if shard==0 { let h=try AcousticProbe.output(result,"h"),te=try AcousticProbe.output(result,"te");guard h.shape.map(\.intValue)==[2,t,1024],te.shape.map(\.intValue)==[2,1024] else { throw NSError(domain:"AcousticShapeSweepShard0Shape",code:n) };feed=["h":h,"te":te,"mask":mask] }
                        else if shard<5 { let h=try AcousticProbe.output(result,"h_out");guard h.shape.map(\.intValue)==[2,t,1024] else { throw NSError(domain:"AcousticShapeSweepShardShape",code:n) };feed["h"]=h }
                        else { velocity=AcousticProbe.values(try AcousticProbe.output(result,"velocity")) }
                    }
                    guard velocity.count==x.count*2 else { throw NSError(domain:"AcousticShapeSweepVelocityShape",code:velocity.count) }
                    let dt=span[step+1]-span[step];for i in x.indices { x[i]+=dt*(1.7*velocity[i]-0.7*velocity[i+x.count]) }
                }
                var melValues=[Float](repeating:0,count:80*g);for c in 0..<80 { for j in 0..<g { melValues[c*g+j]=x[c*t+302+j] } }
                let mel=try AcousticProbe.array(melValues,[1,80,g]),f0Values=try f0.prediction(mel:mel)
                var phase=[Float](repeating:0,count:g*9),sums=[Double](repeating:0,count:9)
                for j in 0..<g { for h in 0..<9 { let rad=(f0Values[j].floatValue*Float(h+1)/24000).truncatingRemainder(dividingBy:1);sums[h]+=Double(rad);phase[j*9+h]=Float(sums[h])*Float(2*Double.pi) } }
                receipt["phase"]="N\(n)_hift";try save()
                let excitation=try AcousticProbe.array(Array(baseExcitation.prefix(samples*9)),[1,samples,9]),result=try predict(7,["mel":mel,"f0":f0Values,"phase":try AcousticProbe.array(phase,[1,g,9]),"noise":excitation,"norm":try norm(samples)]),pcm=try AcousticProbe.output(result,"pcm"),values=AcousticProbe.values(pcm)
                guard pcm.shape.map(\.intValue)==[1,samples],values.allSatisfy(\.isFinite),melValues.allSatisfy(\.isFinite) else { throw NSError(domain:"AcousticShapeSweepPCM",code:n) }
                row["pcmShape"]=pcm.shape.map(\.intValue);row["finite"]=true;row["milliseconds"]=Date().timeIntervalSince(start)*1000;row["status"]="PASS_SHAPE_EXECUTION"
            } catch { row["milliseconds"]=Date().timeIntervalSince(start)*1000;row["status"]="FAIL";row["error"]=Probe.errorRecord(error) }
            rows.append(row);receipt["tests"]=rows;try save();print("ACOUSTIC_SHAPE_SWEEP N\(n) \(row["status"]!)")
        }
        let shapePass=rows.count==requestedMax-requestedMin+1 && rows.allSatisfy { $0["status"] as? String == "PASS_SHAPE_EXECUTION" }
        let boundaryPass=boundary.isEmpty || boundary.allSatisfy { $0["status"] as? String == "PASS_REJECTED_OUT_OF_RANGE" }
        receipt["phase"]="complete";receipt["status"]=shapePass && boundaryPass ? "PASS_EXHAUSTIVE_INTEGER_DYNAMIC_SHAPE_SWEEP_NOT_PROMOTED":"FAIL_DYNAMIC_SHAPE_SWEEP";try save()
        print("ACOUSTIC_SHAPE_SWEEP_RECEIPT \(path.path)")
    }
}
// Purpose: exhaustively execute every integer N in the exported dynamic acoustic interval and prove fail-closed boundary behavior.
// Upstream: unchanged observed-family Core ML packages and N225 fixture only as deterministic input material; no padding or bucket substitution.
// Runtime: signed Release on physical iPhone; NMIN/NMAX arguments permit chunked execution, full range is default.
// Generated: 2026-10-04 America/New_York.
// Changes: experiment-only validation mode; shipping SDK, release assets and productionPromotion remain unchanged.
