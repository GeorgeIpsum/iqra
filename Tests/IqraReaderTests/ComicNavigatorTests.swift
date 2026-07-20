// Tests/IqraReaderTests/ComicNavigatorTests.swift
import XCTest
import ZIPFoundation
@testable import IqraReader

final class ComicNavigatorTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    func makeCBZ(pages: Int) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString + ".cbz")
        let a = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        for i in 0..<pages {
            let bytes = Data([0xFF, 0xD8, UInt8(i)])
            try a.addEntry(with: String(format: "%03d.jpg", i), type: .file,
                           uncompressedSize: Int64(bytes.count),
                           provider: { p, s in bytes.subdata(in: Int(p)..<Int(p)+s) })
        }
        return url
    }

    @MainActor
    func testStartExtractsLoadsAndRestores() async throws {
        let cbz = try makeCBZ(pages: 5)
        let cache = dir.appendingPathComponent("cache")
        let nav = ComicNavigator(bookID: UUID(), comicFileURL: cbz, cacheDir: cache,
                                 initialLocator: Locator(spineIndex: 3, cfi: nil, totalProgression: 0.75))
        let rec = ComicRecorder(); nav.delegate = rec
        let loaded = expectation(description: "loaded"); rec.onLoad = { loaded.fulfill() }
        nav.start()
        await fulfillment(of: [loaded], timeout: 10)
        XCTAssertEqual(nav.pages.count, 5)
        XCTAssertEqual(nav.currentIndex, 3)                        // restored
        XCTAssertTrue(FileManager.default.fileExists(atPath: nav.pages[0].url.path))
    }

    @MainActor
    func testPageChangeEmitsRelocate() async throws {
        let cbz = try makeCBZ(pages: 4)
        let nav = ComicNavigator(bookID: UUID(), comicFileURL: cbz,
                                 cacheDir: dir.appendingPathComponent("c"), initialLocator: nil)
        let rec = ComicRecorder(); nav.delegate = rec
        let loaded = expectation(description: "loaded"); rec.onLoad = { loaded.fulfill() }
        nav.start(); await fulfillment(of: [loaded], timeout: 10)

        nav.goTo(locator: Locator(spineIndex: 2, cfi: nil, totalProgression: 0))
        XCTAssertEqual(nav.currentIndex, 2)
        XCTAssertEqual(rec.locators.last?.spineIndex, 2)
        XCTAssertEqual(rec.locators.last?.totalProgression ?? 0, 2.0/3.0, accuracy: 0.001)
    }
}

@MainActor
final class ComicRecorder: NavigatorDelegate {
    var locators: [Locator] = []
    var onLoad: (() -> Void)?
    func navigatorDidLoad(title: String?, toc: [TOCItem]) { onLoad?() }
    func navigator(didRelocate locator: Locator) { locators.append(locator) }
    func navigator(didFail message: String) { XCTFail(message) }
}
