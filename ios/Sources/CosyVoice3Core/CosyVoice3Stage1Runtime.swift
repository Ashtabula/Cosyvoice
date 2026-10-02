import Foundation
import CoreML

public enum CosyVoice3RuntimeError: Error, Equatable {
    case invalidLength(Int)
    case noBucket(Int)
    case duplicateModelID(String)
    case stateShapeMismatch
}

public enum CosyVoice3SequenceShapePolicy: Equatable {
    case exact(maximum: Int)
    case staticBuckets([Int])

    public func select(validLength: Int) throws -> CosyVoice3ShapeSelection {
        guard validLength > 0 else {
            throw CosyVoice3RuntimeError.invalidLength(validLength)
        }

        switch self {
        case .exact(let maximum):
            guard validLength <= maximum else {
                throw CosyVoice3RuntimeError.noBucket(validLength)
            }
            return .init(validLength: validLength, physicalLength: validLength)

        case .staticBuckets(let buckets):
            guard let physical = buckets.filter({ $0 >= validLength }).min() else {
                throw CosyVoice3RuntimeError.noBucket(validLength)
            }
            return .init(validLength: validLength, physicalLength: physical)
        }
    }
}

public struct CosyVoice3ShapeSelection: Equatable {
    public let validLength: Int
    public let physicalLength: Int

    public init(validLength: Int, physicalLength: Int) {
        self.validLength = validLength
        self.physicalLength = physicalLength
    }

    public var paddingPositions: Int {
        physicalLength - validLength
    }
}

public struct CosyVoice3Stage1Policy: Equatable {
    public var llmPrefill: CosyVoice3SequenceShapePolicy
    public var llmDecodeCache: CosyVoice3SequenceShapePolicy
    public var flowFrames: CosyVoice3SequenceShapePolicy

    public init(
        llmPrefill: CosyVoice3SequenceShapePolicy = .exact(maximum: 512),
        llmDecodeCache: CosyVoice3SequenceShapePolicy = .staticBuckets(
            Array(stride(from: 128, through: 512, by: 16))
        ),
        flowFrames: CosyVoice3SequenceShapePolicy = .staticBuckets(
            Array(stride(from: 256, through: 1024, by: 32))
        )
    ) {
        self.llmPrefill = llmPrefill
        self.llmDecodeCache = llmDecodeCache
        self.flowFrames = flowFrames
    }
}

public struct CosyVoice3ModelSpec {
    public let id: String
    public let url: URL
    public let computeUnits: MLComputeUnits
    public let functionName: String?
    public let preferFastPrediction: Bool
    public let reshapeFrequencyInfrequent: Bool

    public init(
        id: String,
        url: URL,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
        functionName: String? = nil,
        preferFastPrediction: Bool = true,
        reshapeFrequencyInfrequent: Bool = false
    ) {
        self.id = id
        self.url = url
        self.computeUnits = computeUnits
        self.functionName = functionName
        self.preferFastPrediction = preferFastPrediction
        self.reshapeFrequencyInfrequent = reshapeFrequencyInfrequent
    }

    fileprivate var cacheKey: String {
        id + "|" + (functionName ?? "default") + "|" + String(describing: computeUnits)
    }
}

public final class CosyVoice3CompiledModelCache {
    private let lock = NSLock()
    private var compiled = [URL: URL]()

    public init() {}

    public func compiledURL(for source: URL) throws -> URL {
        if source.pathExtension == "mlmodelc" {
            return source
        }

        lock.lock()
        if let hit = compiled[source] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let url = try MLModel.compileModel(at: source)

        lock.lock()
        compiled[source] = url
        lock.unlock()

        return url
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        compiled.removeAll(keepingCapacity: false)
    }
}

public final class CosyVoice3PersistentModelStore {
    private let lock = NSLock()
    private var models = [String: MLModel]()

    public init() {}

    public func model(_ spec: CosyVoice3ModelSpec) throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }

        if let model = models[spec.cacheKey] {
            return model
        }

        let config = MLModelConfiguration()
        config.computeUnits = spec.computeUnits

        if #available(iOS 18.0, macOS 15.0, *) {
            config.functionName = spec.functionName

            var hints = MLOptimizationHints()
            hints.specializationStrategy = spec.preferFastPrediction ? .fastPrediction : .default
            hints.reshapeFrequency = spec.reshapeFrequencyInfrequent ? .infrequent : .frequent
            config.optimizationHints = hints
        }

        let model = try MLModel(contentsOf: spec.url, configuration: config)
        models[spec.cacheKey] = model
        return model
    }

    @discardableResult
    public func warmUp(
        _ spec: CosyVoice3ModelSpec,
        input: MLFeatureProvider? = nil
    ) throws -> MLModel {
        let model = try model(spec)
        if let input {
            _ = try model.prediction(from: input)
        }
        return model
    }

    @discardableResult
    public func warmUp(
        _ spec: CosyVoice3ModelSpec,
        inputs: [MLFeatureProvider]
    ) throws -> MLModel {
        let model = try model(spec)
        for input in inputs {
            _ = try model.prediction(from: input)
        }
        return model
    }

    public func contains(_ spec: CosyVoice3ModelSpec) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return models[spec.cacheKey] != nil
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return models.count
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        models.removeAll(keepingCapacity: false)
    }
}

public final class CosyVoice3TensorPool {
    private struct Key: Hashable {
        let dataType: Int
        let shape: [Int]
    }

    private let lock = NSLock()
    private var storage = [Key: [MLMultiArray]]()
    public var maximumArraysPerShape: Int

    public init(maximumArraysPerShape: Int = 4) {
        self.maximumArraysPerShape = max(1, maximumArraysPerShape)
    }

    public func checkout(
        shape: [Int],
        dataType: MLMultiArrayDataType = .float32
    ) throws -> MLMultiArray {
        let key = Key(
            dataType: Int(dataType.rawValue),
            shape: shape
        )

        lock.lock()
        if var bucket = storage[key], let array = bucket.popLast() {
            storage[key] = bucket
            lock.unlock()
            return array
        }
        lock.unlock()

        return try MLMultiArray(
            shape: shape.map { NSNumber(value: $0) },
            dataType: dataType
        )
    }

    public func recycle(_ array: MLMultiArray) {
        let key = Key(
            dataType: Int(array.dataType.rawValue),
            shape: array.shape.map(\.intValue)
        )

        lock.lock()
        var bucket = storage[key] ?? []
        if bucket.count < maximumArraysPerShape {
            bucket.append(array)
            storage[key] = bucket
        }
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll(keepingCapacity: false)
    }
}

public final class CosyVoice3ReferenceConditioning {
    public let fingerprint: String
    public let tensors: [String: MLMultiArray]
    public let metadata: [String: String]

    public init(
        fingerprint: String,
        tensors: [String: MLMultiArray],
        metadata: [String: String] = [:]
    ) {
        self.fingerprint = fingerprint
        self.tensors = tensors
        self.metadata = metadata
    }
}

public final class CosyVoice3ReferenceConditioningCache {
    private let lock = NSLock()
    private var entries = [String: CosyVoice3ReferenceConditioning]()

    public init() {}

    public func value(for fingerprint: String) -> CosyVoice3ReferenceConditioning? {
        lock.lock()
        defer { lock.unlock() }
        return entries[fingerprint]
    }

    public func insert(_ value: CosyVoice3ReferenceConditioning) {
        lock.lock()
        defer { lock.unlock() }
        entries[value.fingerprint] = value
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
    }
}

public final class CosyVoice3LLMPrefixCacheEntry {
    public let fingerprint: String
    public let validLength: Int
    public let keys: MLMultiArray
    public let values: MLMultiArray

    public init(
        fingerprint: String,
        validLength: Int,
        keys: MLMultiArray,
        values: MLMultiArray
    ) {
        self.fingerprint = fingerprint
        self.validLength = validLength
        self.keys = keys
        self.values = values
    }
}

public final class CosyVoice3LLMPrefixCache {
    private let lock = NSLock()
    private var entries = [String: CosyVoice3LLMPrefixCacheEntry]()

    public init() {}

    public func value(for fingerprint: String) -> CosyVoice3LLMPrefixCacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[fingerprint]
    }

    public func insert(_ value: CosyVoice3LLMPrefixCacheEntry) {
        lock.lock()
        defer { lock.unlock() }
        entries[value.fingerprint] = value
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
    }
}

@available(iOS 18.0, macOS 15.0, *)
public final class CosyVoice3StatefulDecodeSession {
    public let model: MLModel
    public let state: MLState

    private let predictionLock = NSLock()

    public init(model: MLModel) {
        self.model = model
        self.state = model.makeState()
    }

    public func prime(
        keys: MLMultiArray,
        values: MLMultiArray,
        keysStateName: String = "keys_state",
        valuesStateName: String = "values_state"
    ) throws {
        try state.withMultiArray(for: keysStateName) { target in
            try Self.copyPrefix(source: keys, target: target)
        }

        try state.withMultiArray(for: valuesStateName) { target in
            try Self.copyPrefix(source: values, target: target)
        }
    }

    public func predict(_ input: MLFeatureProvider) throws -> MLFeatureProvider {
        predictionLock.lock()
        defer { predictionLock.unlock() }
        return try model.prediction(from: input, using: state)
    }

    private static func copyPrefix(
        source: MLMultiArray,
        target: MLMultiArray
    ) throws {
        guard
            source.dataType == .float32,
            target.dataType == .float32,
            source.shape.count == 5,
            target.shape.count == 5
        else {
            throw CosyVoice3RuntimeError.stateShapeMismatch
        }

        let sourceShape = source.shape.map(\.intValue)
        let targetShape = target.shape.map(\.intValue)

        guard zip(sourceShape, targetShape).allSatisfy({ $0.0 <= $0.1 }) else {
            throw CosyVoice3RuntimeError.stateShapeMismatch
        }

        let sourceStrides = source.strides.map(\.intValue)
        let targetStrides = target.strides.map(\.intValue)

        let sourcePointer = source.dataPointer.bindMemory(
            to: Float.self,
            capacity: source.count
        )
        let targetPointer = target.dataPointer.bindMemory(
            to: Float.self,
            capacity: target.count
        )

        for layer in 0..<sourceShape[0] {
            for batch in 0..<sourceShape[1] {
                for head in 0..<sourceShape[2] {
                    for position in 0..<sourceShape[3] {
                        for channel in 0..<sourceShape[4] {
                            let sourceOffset =
                                layer * sourceStrides[0]
                                + batch * sourceStrides[1]
                                + head * sourceStrides[2]
                                + position * sourceStrides[3]
                                + channel * sourceStrides[4]

                            let targetOffset =
                                layer * targetStrides[0]
                                + batch * targetStrides[1]
                                + head * targetStrides[2]
                                + position * targetStrides[3]
                                + channel * targetStrides[4]

                            targetPointer[targetOffset] = sourcePointer[sourceOffset]
                        }
                    }
                }
            }
        }
    }
}

public final class CosyVoice3Stage1Runtime {
    public let policy: CosyVoice3Stage1Policy
    public let compiler: CosyVoice3CompiledModelCache
    public let models: CosyVoice3PersistentModelStore
    public let tensors: CosyVoice3TensorPool
    public let references: CosyVoice3ReferenceConditioningCache
    public let prefixes: CosyVoice3LLMPrefixCache

    public init(policy: CosyVoice3Stage1Policy = .init()) {
        self.policy = policy
        self.compiler = .init()
        self.models = .init()
        self.tensors = .init()
        self.references = .init()
        self.prefixes = .init()
    }

    public func loadResidentModels(_ specs: [CosyVoice3ModelSpec]) throws {
        for spec in specs {
            _ = try models.model(spec)
        }
    }

    public func clearTransientState() {
        tensors.removeAll()
    }

    public func clearVoiceCaches() {
        references.removeAll()
        prefixes.removeAll()
    }
}

// Purpose: non-algorithmic iOS runtime: persistent compiled MLModel residency, tight shape selection, reusable buffers, reference/prefix caches, multifunction selection, specialization hints, and iOS18 stateful decode sessions.
// Upstream: CosyVoice3 iOS migration baseline. Runtime: iOS17+ with iOS18/macOS15 gated state/multifunction hints; generated 2026-09-29 America/New_York.
// Changes 2026-09-29: normalized Swift 6 operator spacing; retained tight buckets, function-aware residency, compile-once cache, multi-input warm-up, and serialized MLState decode.
