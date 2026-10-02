// CosyVoice3ReferenceEncoder.swift
import AVFoundation
import CoreML
import Foundation
struct CosyVoice3ReferenceConditioning:@unchecked Sendable { let speechTokens:[Int32];let speakerEmbedding:MLMultiArray;let promptMel:MLMultiArray }
protocol CosyVoice3ReferenceFeatureExtractor:Sendable { func encode(audioURL:URL) async throws -> CosyVoice3ReferenceConditioning }
@available(iOS 18.0,macOS 15.0,*)
final class CosyVoice3CoreMLReferenceEncoder:CosyVoice3ReferenceFeatureExtractor,@unchecked Sendable {
 enum EncoderError:Error { case unsupportedAudio;case enrollmentAssetsNotConverted }
 private let assetRoot:URL
 init(assetRoot:URL){self.assetRoot=assetRoot}
 func encode(audioURL:URL) async throws -> CosyVoice3ReferenceConditioning {
  guard FileManager.default.fileExists(atPath:audioURL.path) else {throw EncoderError.unsupportedAudio}
  throw EncoderError.enrollmentAssetsNotConverted
 }
}
// Purpose: native reference-enrollment boundary: 16k Whisper128->speech tokenizer, 16k Kaldi80 mean-normalized->CAMPPlus, 24k mel->prompt feature.
// Upstream: frontend.py extraction functions at CosyVoice3_NPU@8789402.
// Runtime: iOS18+; fails closed until converted enrollment assets pass parity.
// Generated: 2026-10-02 America/New_York.
