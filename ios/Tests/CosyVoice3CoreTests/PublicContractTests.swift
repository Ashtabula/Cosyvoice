import XCTest
@testable import CosyVoice3Core

final class PublicContractTests:XCTestCase {
    func testTokenSemantics() { XCTAssertEqual(CosyVoice3TokenSemantics.sos,6561); XCTAssertEqual(CosyVoice3TokenSemantics.eos,6562); XCTAssertTrue(CosyVoice3TokenSemantics.isSpeech(6560)); XCTAssertFalse(CosyVoice3TokenSemantics.isSpeech(6561)); XCTAssertTrue(CosyVoice3TokenSemantics.isStop(6561)); XCTAssertTrue(CosyVoice3TokenSemantics.isStop(6760)); XCTAssertFalse(CosyVoice3TokenSemantics.isStop(6761)) }
    func testParametersPreserveInstruction() { let p=CosyVoice3Parameters(instruction:"happy"); XCTAssertEqual(p.instruction,"happy"); XCTAssertNil(p.reference); XCTAssertEqual(p.flowSteps,.steps6) }
    func testFlowStepPublicContract() {
        XCTAssertEqual(CosyVoice3FlowSteps.productionDefault,.steps6)
        XCTAssertEqual(CosyVoice3FlowSteps.allCases.map(\.rawValue),[6,8,10])
        XCTAssertEqual(CosyVoice3Parameters(flowSteps:.steps8).flowSteps,.steps8)
        XCTAssertEqual(CosyVoice3Parameters(flowSteps:.steps10).flowSteps,.steps10)
    }
    func testCapabilitiesExposeFlowStepContract() {
        let capabilities=CosyVoice3Capabilities()
        XCTAssertEqual(capabilities.defaultFlowSteps,.steps6)
        XCTAssertEqual(capabilities.supportedFlowSteps.map(\.rawValue),[6,8,10])
    }
    func testAudioDefaults() { let a=CosyVoice3Audio(samples:[0]); XCTAssertEqual(a.sampleRate,24000); XCTAssertEqual(a.channels,1) }
}
