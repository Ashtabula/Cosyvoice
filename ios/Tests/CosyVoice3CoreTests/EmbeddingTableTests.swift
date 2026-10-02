import XCTest
@testable import CosyVoice3Core

final class EmbeddingTableTests: XCTestCase {
    func testEmbeddingTableValidatesByteCount() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0, count: 8).write(to: url)
        XCTAssertThrowsError(try CosyVoice3FP16EmbeddingTable(url: url, rows: 3, width: 2))
        try? FileManager.default.removeItem(at: url)
    }

    func testEmbeddingTableReadsExactRow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data([0,1,2,3,4,5,6,7])
        try bytes.write(to: url)
        let table = try CosyVoice3FP16EmbeddingTable(url: url, rows: 2, width: 2)
        XCTAssertEqual(try table.row(1), Data([4,5,6,7]))
        try? FileManager.default.removeItem(at: url)
    }
}
