// CosyVoice3RASampler.swift
// Requirement: native implementation of upstream ras_sampling/nucleus_sampling with the audited CosyVoice3 SOS/EOS semantics.
import Foundation

enum CosyVoice3RASamplerError: Error, Equatable { case invalidLogitCount(Int); case noFiniteProbability; case invalidConfiguration }

struct CosyVoice3RASampler: Sendable {
    let topP: Double
    let topK: Int
    let windowSize: Int
    let repetitionThreshold: Double
    init(topP: Double=0.8, topK: Int=25, windowSize: Int=10, repetitionThreshold: Double=0.1) {
        self.topP=topP; self.topK=topK; self.windowSize=windowSize; self.repetitionThreshold=repetitionThreshold
    }
    func sample(logits: [Float], decodedTokens: [Int], suppressSOS: Bool, using rng: inout some RandomNumberGenerator) throws -> Int {
        guard logits.count==CosyVoice3TokenSemantics.logitsCount else { throw CosyVoice3RASamplerError.invalidLogitCount(logits.count) }
        guard topP>0, topP<=1, topK>0, windowSize>0, repetitionThreshold>=0 else { throw CosyVoice3RASamplerError.invalidConfiguration }
        var scores=logits.map(Double.init); if suppressSOS { scores[CosyVoice3TokenSemantics.sos] = -.infinity }
        var token=try nucleusSample(scores: scores, using:&rng)
        let recent=decodedTokens.suffix(windowSize), repetitions=recent.reduce(0) { $0+($1==token ? 1:0) }
        if Double(repetitions)>=Double(windowSize)*repetitionThreshold {
            scores[token] = -.infinity
            token=try categoricalSample(scores:scores,using:&rng)
        }
        return token
    }
    func sample(logits: [Float], decodedTokens: [Int], suppressSOS: Bool) throws -> Int {
        var rng=SystemRandomNumberGenerator(); return try sample(logits:logits,decodedTokens:decodedTokens,suppressSOS:suppressSOS,using:&rng)
    }
    private func nucleusSample(scores: [Double], using rng: inout some RandomNumberGenerator) throws -> Int {
        let probabilities=try softmax(scores), sorted=(0..<probabilities.count).sorted { probabilities[$0]==probabilities[$1] ? $0<$1 : probabilities[$0]>probabilities[$1] }
        var selected:[Int]=[], weights:[Double]=[], cumulative=0.0
        for index in sorted { if cumulative>=topP || selected.count>=topK { break }; selected.append(index); weights.append(probabilities[index]); cumulative += probabilities[index] }
        return try categorical(indices:selected,weights:weights,using:&rng)
    }
    private func categoricalSample(scores: [Double], using rng: inout some RandomNumberGenerator) throws -> Int {
        let probabilities=try softmax(scores); return try categorical(indices:Array(probabilities.indices),weights:probabilities,using:&rng)
    }
    private func softmax(_ scores:[Double]) throws -> [Double] {
        guard let maximum=scores.filter({$0.isFinite}).max() else { throw CosyVoice3RASamplerError.noFiniteProbability }
        var values=scores.map { $0.isFinite ? exp($0-maximum):0 }, sum=values.reduce(0,+); guard sum.isFinite && sum>0 else { throw CosyVoice3RASamplerError.noFiniteProbability }
        for i in values.indices { values[i] /= sum }; return values
    }
    private func categorical(indices:[Int],weights:[Double],using rng: inout some RandomNumberGenerator) throws -> Int {
        let total=weights.reduce(0,+); guard !indices.isEmpty, indices.count==weights.count, total.isFinite, total>0 else { throw CosyVoice3RASamplerError.noFiniteProbability }
        let draw=Double.random(in:0..<total,using:&rng); var cumulative=0.0
        for i in weights.indices { cumulative += weights[i]; if draw<cumulative { return indices[i] } }
        return indices.last!
    }
}

// Purpose: remove the Python host from token selection while preserving upstream RAS structure: top-p0.8/top-k25, 10-token repetition window, tau_r0.1, full-distribution resample on repetition.
// Upstream: cosyvoice/utils/common.py ras_sampling+nucleus_sampling and TransformerLM.sampling_ids at CosyVoice3_NPU@8789402.
// Runtime: pure Swift; production randomness uses SystemRandomNumberGenerator. Exact PyTorch RNG sequence is intentionally a validation-oracle concern, not a runtime dependency.
// Generated: 2026-10-02 America/New_York.
