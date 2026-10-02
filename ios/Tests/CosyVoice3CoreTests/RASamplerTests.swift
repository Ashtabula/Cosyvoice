import XCTest
@testable import CosyVoice3Core

private struct ZeroRNG:RandomNumberGenerator { mutating func next()->UInt64 { 0 } }

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
        var logits=[Float](repeating:-100,count:6761); logits[42]=10; logits[43]=9; var rng=ZeroRNG()
        XCTAssertEqual(try CosyVoice3RASampler().sample(logits:logits,decodedTokens:[42],suppressSOS:false,using:&rng),43)
    }
    func testInvalidLogitCountFailsClosed() { XCTAssertThrowsError(try CosyVoice3RASampler().sample(logits:[0],decodedTokens:[],suppressSOS:false)) }
}
