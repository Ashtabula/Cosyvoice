// CosyVoice3HiFTDoubleF0.swift
// Requirement: preserve validated official FP64 F0 inference using effective original weights and CPU Accelerate.
import Accelerate
import CoreML
import Foundation

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
        try prediction(mel: mel, reuseWorkspace: !CommandLine.arguments.contains("--validation-f0-workspace-baseline"))
    }
    func prediction(mel: MLMultiArray, reuseWorkspace: Bool, workspaceObserver: ((Int, UInt, UInt) -> Void)? = nil) throws -> MLMultiArray {
        if !reuseWorkspace { return try predictionFreshWorkspace(mel: mel) }
        let frames = mel.shape[2].intValue, shape = mel.shape.map(\.intValue)
        guard shape == [1,80,frames] else { throw CosyVoice3HiFTError.invalidMelShape(shape) }
        var x = (0..<mel.count).map { mel[$0].doubleValue }
        let maximumColumns = layers.reduce(0) { max($0, $1.inputs * $1.kernel * frames) }
        let maximumOutput = layers.reduce(0) { max($0, $1.outputs * frames) }
        var columns = [Double](repeating: 0, count: maximumColumns)
        var y = [Double](repeating: 0, count: maximumOutput)
        for (index, layer) in layers.enumerated() {
            let k = layer.inputs * layer.kernel
            for c in 0..<layer.inputs {
                for tap in 0..<layer.kernel {
                    let offset = layer.right ? tap : tap - (layer.kernel - 1)
                    let row = (c * layer.kernel + tap) * frames
                    for t in 0..<frames {
                        let source = t + offset
                        columns[row+t] = source >= 0 && source < frames ? x[c*frames+source] : 0
                    }
                }
            }
            // All previous-layer input reads are complete. Detach the COW alias before reusing y.
            x = []
            y.withUnsafeMutableBufferPointer { output in
                output.baseAddress!.update(repeating: 0, count: layer.outputs * frames)
            }
            layer.weights.withUnsafeBufferPointer { w in
                columns.withUnsafeBufferPointer { input in
                    y.withUnsafeMutableBufferPointer { output in
                        workspaceObserver?(index, UInt(bitPattern: input.baseAddress!), UInt(bitPattern: output.baseAddress!))
                        cblas_dgemm(CblasRowMajor,CblasNoTrans,CblasNoTrans,Int32(layer.outputs),Int32(frames),Int32(k),1,w.baseAddress!,Int32(k),input.baseAddress!,Int32(frames),0,output.baseAddress!,Int32(frames))
                    }
                }
            }
            for c in 0..<layer.outputs {
                for t in 0..<frames {
                    let v = y[c*frames+t] + layer.bias[c]
                    y[c*frames+t] = v > 0 ? v : expm1(v)
                }
            }
            x = y
        }
        let result = try MLMultiArray(shape:[1,NSNumber(value:frames)],dataType:.float32)
        let pointer = result.dataPointer.assumingMemoryBound(to:Float.self)
        for t in 0..<frames {
            var value = classifierBias
            for c in 0..<512 { value += x[c*frames+t] * classifier[c] }
            pointer[t] = Float(abs(value))
        }
        return result
    }
    private func predictionFreshWorkspace(mel:MLMultiArray) throws -> MLMultiArray {
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

// Changes2026-10-06: predictiondispatch/request-local FP64columns+y workspace, detachxafterpackingbeforeoverwrite, identicaldgemm/ELU/classifier.
// Purpose remove8large allocations andpreviousx/newyoverlap withoutprecision/math/orderchanges; originalfreshpath retainedvalidationonly.
// Upstream validatedHiFTDoubleF0, Swift6/Accelerate/CoreML iOS18+/macOS15+; generated2026-10-06 America/New_York.
// Observer is host-testonly nonescaping addressintegers, no pointerescapes; productionnil, noengineglobal scratch.
