// CosyVoice3ReferenceEncoder.swift
import AVFoundation
import CoreML
import Foundation

protocol CosyVoice3ReferenceFeatureExtractor: Sendable { func encode(audioURL: URL) async throws -> CosyVoice3ReferenceConditioning }

@available(iOS 18.0, macOS 15.0, *)
final class CosyVoice3CoreMLReferenceEncoder: CosyVoice3ReferenceFeatureExtractor, @unchecked Sendable {
    enum EncoderError: Error { case unsupportedAudio; case enrollmentAssetsNotConverted }
    private let assetRoot: URL
    init(assetRoot: URL) { self.assetRoot = assetRoot }
    func encode(audioURL: URL) async throws -> CosyVoice3ReferenceConditioning {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { throw EncoderError.unsupportedAudio }
        throw EncoderError.enrollmentAssetsNotConverted
    }
}
// Purpose: native reference-enrollment boundary using the shared Stage1 conditioning/cache value type.
// Upstream: frontend.py extraction functions at CosyVoice3_NPU@8789402.
// Runtime: iOS18+; fails closed until converted enrollment assets pass parity.
// Generated: 2026-10-02 America/New_York.
// Changes: removed duplicate CosyVoice3ReferenceConditioning declaration and reused the existing Stage1 runtime cache type.
