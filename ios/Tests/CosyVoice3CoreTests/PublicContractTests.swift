import XCTest
@testable import CosyVoice3Core

final class PublicContractTests:XCTestCase {
    func testTokenSemantics() { XCTAssertEqual(CosyVoice3TokenSemantics.sos,6561); XCTAssertEqual(CosyVoice3TokenSemantics.eos,6562); XCTAssertTrue(CosyVoice3TokenSemantics.isSpeech(6560)); XCTAssertFalse(CosyVoice3TokenSemantics.isSpeech(6561)); XCTAssertTrue(CosyVoice3TokenSemantics.isStop(6561)); XCTAssertTrue(CosyVoice3TokenSemantics.isStop(6760)); XCTAssertFalse(CosyVoice3TokenSemantics.isStop(6761)) }
    func testParametersPreserveInstruction() { let p=CosyVoice3Parameters(instruction:"happy"); XCTAssertEqual(p.instruction,"happy"); XCTAssertNil(p.reference) }
    func testAudioDefaults() { let a=CosyVoice3Audio(samples:[0]); XCTAssertEqual(a.sampleRate,24000); XCTAssertEqual(a.channels,1) }
}
