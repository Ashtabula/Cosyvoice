// ReferenceTokenizerExternalParityTests.swift
// Requirement: verify the generated local swift-transformers tokenizer is token-for-token identical to the pinned upstream CosyVoice3 Phase-0 text fixture.
import Foundation
import Tokenizers
import XCTest
@testable import CosyVoice3Core

final class ReferenceTokenizerExternalParityTests: XCTestCase {
    func testPinnedCosyVoice3TokenizerParityWhenFolderIsProvided() async throws {
        guard let folder = ProcessInfo.processInfo.environment["COSYVOICE3_TOKENIZER_PARITY_FOLDER"],
              !folder.isEmpty else {
            throw XCTSkip("COSYVOICE3_TOKENIZER_PARITY_FOLDER not provided")
        }

        let tokenizer = try await AutoTokenizer.from(
            modelFolder: URL(fileURLWithPath: folder, isDirectory: true)
        )

        XCTAssertEqual(tokenizer.convertTokenToId("<|endofprompt|>"), 151646)

        let prompt = "You are a helpful assistant.<|endofprompt|>那还是三十六年前, 一九八七年. 我呢考上了武汉大学的计算机系."
        let expectedPrompt = [
            2610, 525, 264, 10950, 17847, 13, 151646, 99212, 97706, 20412,
            44991, 94498, 99566, 7948, 24562, 11, 220, 14777, 99609, 99568,
            99612, 7948, 13, 49434, 239, 101036, 77598, 17447, 34187, 99669,
            99897, 26288, 47764, 9370, 37643, 69103, 32648, 38176, 13,
        ]
        XCTAssertEqual(tokenizer.encode(text: prompt), expectedPrompt)

        let target = "今天我们一起回顾过去的经历，也期待未来能够创造更多有意义的事情。"
        let expectedTarget = [
            36171, 35727, 35946, 79478, 14777, 71618, 18397, 99846,
            38182, 85336, 9370, 53393, 81202, 3837, 74763, 22704,
            74193, 38342, 36407, 26232, 99521, 99186, 66078, 33126,
            42140, 18830, 36589, 64559, 9370, 29826, 39374, 1773,
        ]
        XCTAssertEqual(tokenizer.encode(text: target), expectedTarget)
    }
}

// Code purpose: fail before device build if generated tokenizer.json differs from the exact upstream CosyVoice3 text-token trajectory.
// Upstream: CosyVoice3_NPU pinned Phase-0 run-002 tokens.json and receipt.
// Runtime: macOS SwiftPM + swift-transformers 1.3.4.
// Generated: 2026-10-02 America/New_York.
