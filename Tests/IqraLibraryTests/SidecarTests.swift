import XCTest
import IqraCore
@testable import IqraLibrary

final class SidecarTests: XCTestCase {
    func testRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let sidecar = Sidecar(
            bookID: UUID(),
            metadata: ExtractedMetadata(title: "T", titleSort: "T", language: "en", publisher: nil,
                                        bookDescription: nil, contributors: [], identifiers: []),
            formats: [.init(formatID: UUID(), formatType: .epub, originalFileName: "t.epub",
                            byteSize: 9, contentHash: "h")],
            applySeq: 7)
        try Sidecar.write(sidecar, to: tmp)
        XCTAssertEqual(try Sidecar.read(from: tmp), sidecar)
    }
}
