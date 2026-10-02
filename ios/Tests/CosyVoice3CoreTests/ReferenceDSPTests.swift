import XCTest
@testable import CosyVoice3Core

final class ReferenceDSPTests: XCTestCase {
    func testFixedReferenceProfileFrameArithmetic() {
        XCTAssertEqual(CosyVoice3CoreMLReferenceEncoder.fixed16kSamples / 160, 605)
        XCTAssertEqual(1 + (CosyVoice3CoreMLReferenceEncoder.fixed16kSamples - 400) / 160, 604)
        XCTAssertEqual(1 + (CosyVoice3CoreMLReferenceEncoder.fixed24kSamples - 480) / 480, 302)
    }

    func testWhisper400PointDFTFallbackPreservesExactLength() throws {
        var samples = [Float](repeating: 0, count: 400)
        samples[0] = 1

        let spectra = try CosyVoice3Spectrum.frames(
            samples: samples,
            nFFT: 400,
            hop: 160,
            window: [Float](repeating: 1, count: 400),
            power: true
        )

        XCTAssertEqual(spectra.count, 1)
        XCTAssertEqual(spectra[0].count, 201)
        for value in spectra[0] {
            XCTAssertEqual(value, 1, accuracy: 2e-5)
        }
    }

    func testWindowsHaveExpectedEndpoints() {
        let hann = CosyVoice3Spectrum.periodicHann(400)
        XCTAssertEqual(hann.count, 400)
        XCTAssertEqual(hann[0], 0, accuracy: 1e-7)
        let povey = CosyVoice3Spectrum.povey(400)
        XCTAssertEqual(povey.count, 400)
        XCTAssertEqual(povey[0], 0, accuracy: 1e-7)
        XCTAssertEqual(povey[399], 0, accuracy: 1e-6)
    }
}
