// DynamicAcousticProbeApp.swift
// Requirement: physically test the same symbolic conditioning/shard0 family at N186 and N225, independently for CPU_ONLY and CPU_AND_NE, with phase-specific durable receipts.
import CoreML
import Foundation
import SwiftUI

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
