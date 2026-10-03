import XCTest
@testable import CosyVoice3Core

private struct ZeroRNG:RandomNumberGenerator { mutating func next()->UInt64 { 0 } }
private struct LcgRNG:RandomNumberGenerator {
    var state:UInt64
    mutating func next()->UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private struct ReferenceRAS {
    let topP=0.8
    let topK=25
    let windowSize=10
    let repetitionThreshold=0.1

    func sample(logits:[Float],decodedTokens:[Int],suppressSOS:Bool,using rng:inout some RandomNumberGenerator)throws->Int {
        var scores=logits.map(Double.init)
        if suppressSOS { scores[CosyVoice3TokenSemantics.sos] = -.infinity }
        var token=try nucleus(scores,&rng)
        let repetitions=decodedTokens.suffix(windowSize).reduce(0){$0+($1==token ? 1:0)}
        if Double(repetitions)>=Double(windowSize)*repetitionThreshold {
            scores[token] = -.infinity
            token=try categorical(scores,&rng)
        }
        return token
    }

    private func softmax(_ scores:[Double])throws->[Double] {
        guard let maximum=scores.filter({$0.isFinite}).max() else { throw CosyVoice3RASamplerError.noFiniteProbability }
        var values=scores.map{$0.isFinite ? exp($0-maximum):0}
        let sum=values.reduce(0,+)
        guard sum.isFinite && sum>0 else { throw CosyVoice3RASamplerError.noFiniteProbability }
        for i in values.indices { values[i] /= sum }
        return values
    }

    private func nucleus(_ scores:[Double],_ rng:inout some RandomNumberGenerator)throws->Int {
        let probabilities=try softmax(scores)
        let sorted=(0..<probabilities.count).sorted {
            probabilities[$0]==probabilities[$1] ? $0<$1 : probabilities[$0]>probabilities[$1]
        }
        var selected:[Int]=[],weights:[Double]=[],cumulative=0.0
        for index in sorted {
            if cumulative>=topP || selected.count>=topK { break }
            selected.append(index); weights.append(probabilities[index]); cumulative += probabilities[index]
        }
        return try draw(selected,weights,&rng)
    }

    private func categorical(_ scores:[Double],_ rng:inout some RandomNumberGenerator)throws->Int {
        let probabilities=try softmax(scores)
        return try draw(Array(probabilities.indices),probabilities,&rng)
    }

    private func draw(_ indices:[Int],_ weights:[Double],_ rng:inout some RandomNumberGenerator)throws->Int {
        let total=weights.reduce(0,+)
        guard !indices.isEmpty,indices.count==weights.count,total.isFinite,total>0 else { throw CosyVoice3RASamplerError.noFiniteProbability }
        let value=Double.random(in:0..<total,using:&rng)
        var cumulative=0.0
        for i in weights.indices {
            cumulative += weights[i]
            if value<cumulative { return indices[i] }
        }
        return indices.last!
    }
}

final class RASamplerTests:XCTestCase {
    func testSOSSuppressionUses6561NotActualEOS6562() throws {
        var logits=[Float](repeating:-100,count:6761); logits[6561]=10; logits[6562]=9; var rng=ZeroRNG()
        let token=try CosyVoice3RASampler().sample(logits:logits,decodedTokens:[],suppressSOS:true,using:&rng)
        XCTAssertEqual(token,6562)
    }

    func testSpeechTokenCanBeSelected() throws {
        var logits=[Float](repeating:-100,count:6761); logits[42]=10; var rng=ZeroRNG()
        XCTAssertEqual(try CosyVoice3RASampler().sample(logits:logits,decodedTokens:[],suppressSOS:false,using:&rng),42)
    }

    func testRepeatedTopTokenIsMaskedAndResampled() throws {
        var logits=[Float](repeating:-Float.infinity,count:6761); logits[42]=10; logits[43]=9; var rng=ZeroRNG()
        XCTAssertEqual(try CosyVoice3RASampler().sample(logits:logits,decodedTokens:[42],suppressSOS:false,using:&rng),43)
    }

    func testOptimizedTopKPathMatchesFormerFullSortForDeterministicDraws() throws {
        let optimized=CosyVoice3RASampler(), reference=ReferenceRAS()
        var logits=(0..<6761).map { i in
            Float(sin(Double(i)*0.0137)*2.0 + cos(Double(i)*0.0071)*0.5 - Double(i%17)*0.003)
        }
        logits[6561]=3.75
        logits[6562]=3.70
        for seed in 1...32 {
            var a=LcgRNG(state:UInt64(seed)), b=LcgRNG(state:UInt64(seed))
            let suppress=seed%2==0
            let expected=try reference.sample(logits:logits,decodedTokens:[],suppressSOS:suppress,using:&a)
            let actual=try optimized.sample(logits:logits,decodedTokens:[],suppressSOS:suppress,using:&b)
            XCTAssertEqual(actual,expected,"seed=\(seed) suppressSOS=\(suppress)")
        }
    }

    func testOptimizedRepetitionResampleMatchesFormerFullSortPath() throws {
        let optimized=CosyVoice3RASampler(), reference=ReferenceRAS()
        var logits=[Float](repeating:-9,count:6761)
        logits[42]=10; logits[43]=9; logits[44]=8; logits[45]=7
        for seed in 101...116 {
            var a=LcgRNG(state:UInt64(seed)), b=LcgRNG(state:UInt64(seed))
            let decoded=[42,42,42]
            let expected=try reference.sample(logits:logits,decodedTokens:decoded,suppressSOS:false,using:&a)
            let actual=try optimized.sample(logits:logits,decodedTokens:decoded,suppressSOS:false,using:&b)
            XCTAssertEqual(actual,expected,"seed=\(seed)")
        }
    }

    func testInvalidLogitCountFailsClosed() {
        XCTAssertThrowsError(try CosyVoice3RASampler().sample(logits:[0],decodedTokens:[],suppressSOS:false))
    }
}

// Requirement coverage: optimized production RAS must remain token-for-token equivalent to the former full-vocabulary-sort implementation for identical logits and RNG draws, including SOS suppression and repetition resampling.
// Generated: 2026-10-02 America/New_York.
