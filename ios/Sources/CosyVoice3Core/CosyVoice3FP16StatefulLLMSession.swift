// CosyVoice3FP16StatefulLLMSession.swift
// Requirement: reuse FP16 models and 48 per-layer KV states; prefill in-state, then decode exact prefixes with preallocated inputs and no host KV round-trip.
import Foundation
import CoreML

@available(iOS 18.0, macOS 15.0, *)
public final class CosyVoice3FP16StatefulLLMSession {
    public enum SessionError: Error {
        case incompatibleStateSchema
        case invalidPrefill
        case invalidPosition(expected: Int, actual: Int)
        case invalidInputBytes(expected: Int, actual: Int)
        case contextExhausted
        case invalidatedAfterPredictionError
    }

    public static let capacity = 512
    public static let physicalPrefillLength = 224
    public static let persistentStateBytes = 6_291_456
    public let prefillModel: MLModel
    public let decodeModel: MLModel
    private let state: MLState
    private let lock = NSLock()
    private var validLength = 0
    private var invalidated = false
    private let x: MLMultiArray
    private let cos: MLMultiArray
    private let sin: MLMultiArray
    private var inputs: [Int: MLFeatureProvider] = [:]
    private var fixedInput: MLFeatureProvider?
    private var fixedMask: MLMultiArray?
    private let diagnosticPosition: MLMultiArray?
    private let diagnosticWriteMask: MLMultiArray?
    private var previousWritePosition: Int?
    private let prefixLength: Int
    private let physicalPrefixLength: Int
    private let activityObserver: ((String, Bool) -> Void)?

    public var contextLength: Int {
        lock.lock()
        defer { lock.unlock() }
        return validLength
    }

    public init(prefillModel: MLModel, decodeModel: MLModel, prefixLength: Int = 224,
                activityObserver: ((String, Bool) -> Void)? = nil,
                diagnosticMaximumAttentionLength: Int? = nil,
                diagnosticHostWriteMask: Bool = false,
                logicalPrefixLength: Int? = nil) throws {
        let hostWriteMask = diagnosticHostWriteMask || decodeModel.modelDescription.inputDescriptionsByName["write_mask"] != nil
        let maximumAttentionLength = diagnosticMaximumAttentionLength ?? (hostWriteMask ? decodeModel.modelDescription.inputDescriptionsByName["mask"]?.multiArrayConstraint?.shape.last?.intValue : nil)
        let logicalLength = logicalPrefixLength ?? prefixLength
        guard maximumAttentionLength == nil || maximumAttentionLength == 449 || (hostWriteMask && maximumAttentionLength == 512) else { throw SessionError.invalidPrefill }
        if hostWriteMask {
            guard [449,512].contains(maximumAttentionLength ?? 0),
                  decodeModel.modelDescription.inputDescriptionsByName["mask"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,1,1,maximumAttentionLength!],
                  decodeModel.modelDescription.inputDescriptionsByName["write_mask"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,1,512,1],
                  decodeModel.modelDescription.inputDescriptionsByName["write_mask"]?.multiArrayConstraint?.dataType == .float16,
                  decodeModel.modelDescription.inputDescriptionsByName["position"] == nil
            else { throw SessionError.invalidPrefill }
        }
        guard prefixLength == Self.physicalPrefillLength, (1...prefixLength).contains(logicalLength),
              logicalLength == prefixLength || (hostWriteMask && maximumAttentionLength == Self.capacity)
        else { throw SessionError.invalidPrefill }
        let expected = Set((0..<24).flatMap { i in
            [String(format: "keys_state_%02d", i), String(format: "values_state_%02d", i)]
        })
        for model in [prefillModel, decodeModel] {
            let descriptions = model.modelDescription.stateDescriptionsByName
            guard Set(descriptions.keys) == expected,
                  descriptions.values.allSatisfy({ description in
                      guard let constraint = description.stateConstraint else { return false }
                      return constraint.bufferShape == [1, 2, 512, 64]
                          && constraint.dataType == .float16
                  }) else { throw SessionError.incompatibleStateSchema }
        }
        self.prefillModel = prefillModel
        self.decodeModel = decodeModel
        self.prefixLength = logicalLength
        self.physicalPrefixLength = prefixLength
        self.activityObserver = activityObserver
        activityObserver?("llm.make_state", true)
        self.state = prefillModel.makeState()
        activityObserver?("llm.make_state", false)
        activityObserver?("llm.preallocate_inputs", true)
        defer { activityObserver?("llm.preallocate_inputs", false) }
        self.x = try Self.array([1, 1, 896])
        self.cos = try Self.array([1, 1, 1, 64])
        self.sin = try Self.array([1, 1, 1, 64])
        diagnosticPosition = try (hostWriteMask ? nil : maximumAttentionLength).map { _ in try MLMultiArray(shape:[1],dataType:.int32) }
        diagnosticWriteMask = hostWriteMask ? try Self.array([1,1,512,1]) : nil
        // Fixed-width masks share one provider; exact-length model inputs retain the original path.
        let lengths = maximumAttentionLength.map { [$0] } ?? Array((logicalLength + 1)...Self.capacity)
        for length in lengths {
            let mask = try Self.array([1, 1, 1, length])
            if maximumAttentionLength != nil {
                try Self.initializeFixedMask(mask, validLength: logicalLength + 1)
                fixedMask = mask
            }
            var features: [String:MLFeatureValue] = [
                "x": MLFeatureValue(multiArray: x), "cos": MLFeatureValue(multiArray: cos),
                "sin": MLFeatureValue(multiArray: sin), "mask": MLFeatureValue(multiArray: mask)
            ]
            if let position = diagnosticPosition { features["position"] = MLFeatureValue(multiArray:position) }
            if let writeMask = diagnosticWriteMask { features["write_mask"] = MLFeatureValue(multiArray:writeMask) }
            let provider = try MLDictionaryFeatureProvider(dictionary:features)
            if maximumAttentionLength != nil { fixedInput = provider }
            else { inputs[length] = provider }
        }
    }

    static func initializeFixedMask(_ mask: MLMultiArray, validLength: Int) throws {
        guard mask.dataType == .float16, validLength > 0, validLength <= mask.count else { throw SessionError.invalidPrefill }
        let bits = mask.dataPointer.assumingMemoryBound(to: UInt16.self)
        for i in 0..<mask.count { bits[i] = i < validLength ? 0 : 0xfc00 }
    }
    static func advanceFixedMask(_ mask: MLMultiArray, absolutePosition: Int) throws {
        guard mask.dataType == .float16, absolutePosition >= 0, absolutePosition < mask.count else { throw SessionError.contextExhausted }
        mask.dataPointer.assumingMemoryBound(to: UInt16.self)[absolutePosition] = 0
    }

    private func predict(_ model: MLModel, input: MLFeatureProvider, name: String) throws -> MLFeatureProvider {
        activityObserver?(name, true)
        defer { activityObserver?(name, false) }
        return try model.prediction(from: input, using: state)
    }

    private static func array(_ shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
        memset(array.dataPointer, 0, array.count * MemoryLayout<UInt16>.size)
        return array
    }

    private static func copy(_ data: Data, to array: MLMultiArray) throws {
        let expected = array.count * MemoryLayout<UInt16>.size
        guard data.count == expected else {
            throw SessionError.invalidInputBytes(expected: expected, actual: data.count)
        }
        data.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress { memcpy(array.dataPointer, source, expected) }
        }
    }

    /// Call from a worker thread. Models persist across sessions; a session owns one utterance's KV.
    public func prefill(_ input: MLFeatureProvider) throws -> MLFeatureProvider {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { throw SessionError.invalidatedAfterPredictionError }
        guard validLength == 0,
              ["x", "cos", "sin", "mask"].allSatisfy({ input.featureValue(for: $0)?.multiArrayValue?.dataType == .float16 }),
              input.featureValue(for: "x")?.multiArrayValue?.shape.map(\.intValue) == [1, physicalPrefixLength, 896],
              input.featureValue(for: "cos")?.multiArrayValue?.shape.map(\.intValue) == [1, 1, physicalPrefixLength, 64],
              input.featureValue(for: "sin")?.multiArrayValue?.shape.map(\.intValue) == [1, 1, physicalPrefixLength, 64],
              input.featureValue(for: "mask")?.multiArrayValue?.shape.map(\.intValue) == [1, 1, physicalPrefixLength, physicalPrefixLength]
        else { throw SessionError.invalidPrefill }
        let output: MLFeatureProvider
        do { output = try predict(prefillModel, input: input, name: "llm.prefill.prediction") }
        catch { invalidated = true; throw error }
        validLength = prefixLength
        return output
    }

    /// FP16 little-endian embedding and cached absolute-position RoPE. Sampling remains the caller's original RAS.
    public func decode(embedding: Data, cos: Data, sin: Data, absolutePosition: Int,
                       diagnosticModelOverride: MLModel? = nil) throws -> MLFeatureProvider {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { throw SessionError.invalidatedAfterPredictionError }
        guard validLength >= prefixLength, absolutePosition == validLength else {
            throw SessionError.invalidPosition(expected: validLength, actual: absolutePosition)
        }
        guard validLength < Self.capacity, let input = fixedInput ?? inputs[validLength + 1] else { throw SessionError.contextExhausted }
        if let mask = fixedMask { try Self.advanceFixedMask(mask, absolutePosition: validLength) }
        activityObserver?("llm.decode.input_copy", true)
        do {
            defer { activityObserver?("llm.decode.input_copy", false) }
            try Self.copy(embedding, to: x)
            try Self.copy(cos, to: self.cos)
            try Self.copy(sin, to: self.sin)
        }
        diagnosticPosition?.dataPointer.assumingMemoryBound(to:Int32.self).pointee = Int32(absolutePosition)
        if let mask = diagnosticWriteMask {
            activityObserver?("llm.decode.write_mask", true)
            let bits = mask.dataPointer.assumingMemoryBound(to:UInt16.self)
            if let previous = previousWritePosition { bits[previous] = 0 }
            bits[absolutePosition] = 0x3c00 // FP16 one, real host position; no graph integer-index input.
            previousWritePosition = absolutePosition
            activityObserver?("llm.decode.write_mask", false)
        }
        let output: MLFeatureProvider
        do { output = try predict(diagnosticModelOverride ?? decodeModel, input: input, name: "llm.decode.prediction") }
        catch { invalidated = true; throw error }
        validLength += 1
        return output
    }

    /// Correctness-only host readback. Never called by the production or timing-only path.
    public func diagnosticStateSnapshot() throws -> [String: Data] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: Data] = [:]
        for name in prefillModel.modelDescription.stateDescriptionsByName.keys.sorted() {
            result[name] = try state.withMultiArray(for: name) { a in
                guard a.dataType == .float16, a.shape.map(\.intValue) == [1,2,512,64],
                      a.strides.map(\.intValue) == [65536,32768,64,1] else { throw SessionError.incompatibleStateSchema }
                return Data(bytes: a.dataPointer, count: a.count * 2)
            }
        }
        return result
    }
}
// Purpose: serial FP16 per-layer-state execution, in-state prefill, exact-length decode, persistent model references and preallocated providers. No KV is exposed to the host.
// Upstream: optimize_llm_decode.py --variant perlayer and validated rank4 grouped GQA; caller supplies unchanged RAS/embedding/RoPE. Environment iOS18+/macOS15+ Core ML; generated2026-09-30 America/New_York.
// Changes: new standalone session. Source model compilation/cache and sampling are caller-owned; each session starts fresh KV, no host prefix priming or fallback.
// Changes 2026-10-01: optional nil-default activity observer around State creation, input setup/copy and prediction API; no model, State layout, length, sampling or lifecycle change. Exact line map recorded after build in this file.

// Change map 2026-10-01 America/New_York: modified current lines 30-30, 38-39, 56-57, 59-61, 75-80, 110-110, 125-131, 133-133, 142-142; additive measurement observers/cache namespace opt-in/routing and profiling only. Upstream accepted stateful/frozen225 graphs; Release no-ASan physical Air. Post-run comment only; executable source hashes retained in run-status.json.
// Changes2026-10-01 15:15 America/New_York: optional diagnostic model override in decode and opt-in State snapshot for shape counterfactual correctness. Default runtime unchanged; diagnostic runner validates override schema. No layout/attention/RoPE changes; exact line map in Git diff.

// Changes2026-10-01 16:04 America/New_York: opt-in diagnosticMaximumAttentionLength449 adds cached exact valid masks and real int32 position; nil default leaves baseline provider schema and exact-prefix runtime unchanged. No KV host round-trip. Modified initializer/provider allocation/decode position only; Git diff is exact line map.
// Changes2026-10-01 19:05 America/New_York: optional false-default diagnosticHostWriteMask after fixed256/449 ANE gates. One preallocated FP16[1,1,512,1] host mask updates two slots per step; omit graph position, keep real RoPE/valid masks and fresh State. Changed diagnostic properties/initializer/providers/decode only; line map in Git diff. Upstream validated static-select mask package; Air Release/no-ASan, no production promotion.
// Changes2026-10-01 fixed512 phase: permit512 only for the same host-mask route and verify physical mask shape; allocation, two-slot write-mask update, State progression and baseline default unchanged. Upstream accepted449 implementation; Air Release/no-ASan. Initializer guards only, Git diff line map.
// Changes2026-10-01 22:52 America/New_York: shared production fixed512 host-mask selection from model ABI, optional logicalPrefixLength with physical224 prefill, cached exact-valid masks and overwrite-before-expose. Preserves starting512 WIP and legacy explicit baseline. Initializer/prefill shape guards only (Git diff line map); same State/RoPE/sampling math, no KV readback in decode. Upstream accepted fixed512 instruct2 logical session; iOS18+ Release/no-ASan.

// Purpose: reuse fixed-width decode mask/provider without changing attention, KV state, model bytes or sampling.
// Upstream: original session with one mask/provider per prefix; environment: Swift 6 iOS18+/macOS15+.
// Generated: 2026-10-05 America/New_York; changed lines 30-32, 94-112, fixed-mask helpers and decode selection.
