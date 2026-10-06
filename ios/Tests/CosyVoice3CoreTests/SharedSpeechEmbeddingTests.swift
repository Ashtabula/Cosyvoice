// SharedSpeechEmbeddingTests.swift
// Requirement: sharing immutable speech bytes must preserve original URL conditioner rows, RoPE and invalid-input behavior.
import XCTest
@testable import CosyVoice3Core

final class SharedSpeechEmbeddingTests: XCTestCase {
    func testSharedRowsAndRoPEMatchStandaloneURL() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url=folder.appendingPathComponent("speech.bin")
        var bytes=Data(repeating:0,count:6761*896*2)
        for token in [0,42,6561,6562,6563,6760] {
            for offset in 0..<1792 { bytes[token*1792+offset]=UInt8(truncatingIfNeeded:token+offset) }
        }
        try bytes.write(to:url)
        let table=try CosyVoice3FP16EmbeddingTable(url:url,rows:6761)
        let rope=CosyVoice3RoPEConfiguration(theta:1_000_000)
        let original=try CosyVoice3TokenConditioner(embeddingURL:url,rope:rope)
        let shared=try CosyVoice3TokenConditioner(embeddingData:table.rawFP16Data,rope:rope)
        for token in [0,42,6561,6562,6563,6760] {
            XCTAssertEqual(try shared.embeddingFP16(token:token),try original.embeddingFP16(token:token))
            XCTAssertEqual(try shared.embeddingFP16(token:token),try table.row(token))
        }
        for position in [0,54,224,313,511] {
            let a=try original.ropeFP16(position:position),b=try shared.ropeFP16(position:position)
            XCTAssertEqual(a.cos,b.cos);XCTAssertEqual(a.sin,b.sin)
        }
        XCTAssertThrowsError(try shared.embeddingFP16(token:-1))
        XCTAssertThrowsError(try shared.embeddingFP16(token:6761))
        XCTAssertThrowsError(try shared.ropeFP16(position:512))
        XCTAssertThrowsError(try CosyVoice3TokenConditioner(embeddingData:Data(),rope:rope))
    }
}
// Purpose: exact standalone vs shared immutable payload/error parity; no numerical model rewrite.
// Upstream: original embedding table and conditioner; Swift6 XCTest; generated2026-10-06 07:33 EDT America/New_York.
// New file, existing tests unmodified.
