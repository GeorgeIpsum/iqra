// Tests/IqraLibraryTests/FormatSnifferTests.swift
import XCTest
import IqraCore
import ZIPFoundation
@testable import IqraLibrary

final class FormatSnifferTests: XCTestCase {
    func tempFile(_ data: Data, ext: String = "bin") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url)
        return url
    }

    func zipFile(entries: [(name: String, data: Data)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".zip")
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        for e in entries {
            try archive.addEntry(with: e.name, type: .file,
                                 uncompressedSize: Int64(e.data.count),
                                 provider: { position, size in
                                     e.data.subdata(in: Int(position)..<Int(position) + size)
                                 })
        }
        return url
    }

    func testSniffPDF() throws {
        let url = try tempFile(Data("%PDF-1.7 rest".utf8))
        XCTAssertEqual(try FormatSniffer.sniff(fileURL: url), .recognized(.pdf))
    }

    func testSniffEPUB() throws {
        let url = try zipFile(entries: [("mimetype", Data("application/epub+zip".utf8))])
        XCTAssertEqual(try FormatSniffer.sniff(fileURL: url), .recognized(.epub))
    }

    func testSniffZipWithoutMimetypeIsCBZ() throws {
        let url = try zipFile(entries: [("page001.png", Data([0x89, 0x50]))])
        XCTAssertEqual(try FormatSniffer.sniff(fileURL: url), .recognized(.cbz))
    }

    func testSniffRAR() throws {
        let url = try tempFile(Data("Rar!\u{05}\u{07}".utf8))
        XCTAssertEqual(try FormatSniffer.sniff(fileURL: url), .recognized(.cbr))
    }

    func testSniffMOBI() throws {
        var data = Data(count: 60)
        data.append(Data("BOOKMOBI".utf8))
        data.append(Data(count: 8))
        let url = try tempFile(data)
        XCTAssertEqual(try FormatSniffer.sniff(fileURL: url), .recognized(.mobi))
    }

    func testUnrecognized() throws {
        let url = try tempFile(Data("hello world".utf8), ext: "epub") // extension must NOT matter
        XCTAssertEqual(try FormatSniffer.sniff(fileURL: url), .unrecognized)
    }
}
