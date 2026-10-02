import XCTest
@testable import CosyVoice3Core

final class TorchAudioResamplerTests: XCTestCase {
    func testIdentityReturnsOriginalSamples() throws {
        let input: [Float] = [0, 0.25, -0.5, 1]
        XCTAssertEqual(
            try CosyVoice3TorchAudioResampler.resample(input, from: 24_000, to: 24_000),
            input
        )
    }

    func testFixedReferenceLengthsMatchUpstreamContract() throws {
        let input = [Float](repeating: 0, count: 145_344)
        let down = try CosyVoice3TorchAudioResampler.resample(input, from: 24_000, to: 16_000)
        XCTAssertEqual(down.count, 96_896)
        let same = try CosyVoice3TorchAudioResampler.resample(input, from: 24_000, to: 24_000)
        XCTAssertEqual(same.count, 145_344)
    }

    func testImpulseResampleIsFiniteAndNonzero() throws {
        var input = [Float](repeating: 0, count: 2_400)
        input[1_200] = 1
        let output = try CosyVoice3TorchAudioResampler.resample(input, from: 24_000, to: 16_000)
        XCTAssertEqual(output.count, 1_600)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(output.map { abs($0) }.max() ?? 0, 0)
    }
}
