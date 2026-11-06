import WebKit
import XCTest
@testable import Browser

@MainActor
final class FaviconTests: XCTestCase {
    private let page = URL(string: "https://example.com/docs/page.html")!
    /// A 1×1 PNG.
    private static let pixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    func testParsesIconLinksFromTheHead() {
        let html = """
            <html><head>
            <link rel="mask-icon" href="/mask.svg" color="#000">
            <link rel="fluid-icon" href="/fluid.png">
            <LINK REL="Shortcut Icon" HREF='favicon.ico'>
            <link href=/icon-32.png rel=icon sizes="16x16 32x32" type="image/png">
            <link rel="apple-touch-icon" href="//cdn.example.net/touch.png?a=1&amp;b=2">
            <link rel="icon" type="image/svg+xml" href="https://static.example.com/icon.svg">
            <link rel="stylesheet" href="/style.css">
            </head><body><link rel="icon" href="/late.png"></body></html>
            """

        let candidates = FaviconCandidate.candidates(inHTML: html, baseURL: page)

        XCTAssertEqual(candidates, [
            FaviconCandidate(url: URL(string: "https://example.com/docs/favicon.ico")!),
            FaviconCandidate(url: URL(string: "https://example.com/icon-32.png")!, sizes: [16, 32]),
            FaviconCandidate(url: URL(string: "https://cdn.example.net/touch.png?a=1&b=2")!, isTouchIcon: true),
        ])
    }

    func testResolvesLinksAgainstTheBaseElement() {
        let html = #"<head><base href="https://assets.example.org/v2/"><link rel="icon" href="icons/a.png"></head>"#

        XCTAssertEqual(FaviconCandidate.candidates(inHTML: html, baseURL: page).map(\.url),
                       [URL(string: "https://assets.example.org/v2/icons/a.png")!])
    }

    func testIgnoresUnsupportedSchemes() {
        XCTAssertNil(FaviconCandidate(rel: "icon", href: "javascript:alert(1)", baseURL: page))
        XCTAssertNil(FaviconCandidate(rel: "icon", href: " ", baseURL: page))
        XCTAssertNotNil(FaviconCandidate(rel: "icon", href: "data:image/png;base64,AAAA", baseURL: page))
    }

    func testSkipsSVGIcons() {
        XCTAssertNil(FaviconCandidate(rel: "icon", href: "/icon.svg", baseURL: page))
        XCTAssertNil(FaviconCandidate(rel: "icon", href: "/icon", type: "image/svg+xml", baseURL: page))
        XCTAssertNil(FaviconCandidate(rel: "icon", href: "data:image/svg+xml;base64,AAAA", baseURL: page))
        XCTAssertEqual(FaviconCandidate(rel: "icon", href: "/icon.png", sizes: "any", baseURL: page)?.isScalable, true)
    }

    func testReadingStopsPastTheLimit() async throws {
        func read(_ count: Int, limit: Int) async throws -> FaviconData.Read {
            try await FaviconData.read(AsyncStream { continuation in
                for byte in 0..<count { continuation.yield(UInt8(byte % 256)) }
                continuation.finish()
            }, limit: limit)
        }

        let whole = try await read(4, limit: 4)
        XCTAssertEqual(whole, FaviconData.Read(bytes: Data([0, 1, 2, 3]), isTruncated: false))
        let truncated = try await read(10, limit: 4)
        XCTAssertEqual(truncated, FaviconData.Read(bytes: Data([0, 1, 2, 3]), isTruncated: true))
    }

    func testAcceptsOnlyRasterIconTypes() throws {
        XCTAssertTrue(FaviconData.isIconMIMEType("image/x-icon"))
        XCTAssertTrue(FaviconData.isIconMIMEType("image/PNG"))
        XCTAssertTrue(FaviconData.isIconMIMEType("application/octet-stream"))
        XCTAssertFalse(FaviconData.isIconMIMEType("image/svg+xml"))
        XCTAssertFalse(FaviconData.isIconMIMEType("application/pdf"))
        XCTAssertFalse(FaviconData.isIconMIMEType("text/html"))
        XCTAssertTrue(FaviconData.isPageMIMEType("text/html"))
        XCTAssertFalse(FaviconData.isPageMIMEType("application/json"))

        let png = try XCTUnwrap(Data(base64Encoded: Self.pixelPNG))
        XCTAssertEqual(FaviconData.imageType(of: png), .png)
        XCTAssertEqual(FaviconData.imageType(of: Data([0, 0, 1, 0, 1, 0])), .ico)
        XCTAssertEqual(FaviconData.imageType(of: Data("GIF89a".utf8)), .gif)
        XCTAssertEqual(FaviconData.imageType(of: Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), .webP)
        XCTAssertNil(FaviconData.imageType(of: Data("%PDF-1.7".utf8)))
        XCTAssertNil(FaviconData.imageType(of: Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)))

        XCTAssertNotNil(FaviconData.image(from: png))
        XCTAssertNil(FaviconData.image(from: Data("%PDF-1.7".utf8)))
        XCTAssertNil(FaviconData.image(from: png + Data(count: FaviconData.maxIconBytes)))
    }

    func testRanksSizesNearTheDisplaySizeFirst() {
        let icon = { (path: String, sizes: [Int], scalable: Bool, touch: Bool) in
            FaviconCandidate(url: URL(string: "https://example.com/\(path)")!, sizes: sizes,
                             isScalable: scalable, isTouchIcon: touch)
        }
        let candidates = [
            icon("touch.png", [], false, true),
            icon("16.png", [16], false, false),
            icon("unknown.ico", [], false, false),
            icon("icon.svg", [], true, false),
            icon("192.png", [192], false, false),
            icon("48.png", [48], false, false),
            icon("24.png", [24], false, false),
        ]

        XCTAssertEqual(FaviconCandidate.ranked(candidates, pageURL: page).map(\.lastPathComponent),
                       ["48.png", "192.png", "icon.svg", "unknown.ico", "24.png", "16.png", "touch.png",
                        "favicon.ico"])
    }

    func testRankingFallsBackToTheSiteFavicon() {
        let favicon = URL(string: "https://example.com/favicon.ico")!

        XCTAssertEqual(FaviconCandidate.ranked([], pageURL: page), [favicon])
        XCTAssertEqual(FaviconCandidate.ranked([FaviconCandidate(url: favicon)], pageURL: page), [favicon])
        XCTAssertEqual(FaviconCandidate.ranked([], pageURL: URL(string: "file:///tmp/a.html")!), [])
    }

    func testCacheEntriesExpire() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FaviconTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = FaviconCache(directory: directory)
        let entry = FaviconCache.Entry(source: URL(string: "https://example.com/favicon.ico")!, data: Data([1, 2, 3]))

        cache.save(entry, forHost: "example.com")

        XCTAssertEqual(cache.entry(forHost: "example.com"), entry)
        XCTAssertEqual(cache.entry(forHost: "example.com", now: .now.addingTimeInterval(6 * 24 * 60 * 60)), entry)
        XCTAssertNil(cache.entry(forHost: "example.com", now: .now.addingTimeInterval(8 * 24 * 60 * 60)))
        // A restored tab still shows an old icon while the page's own one loads.
        XCTAssertEqual(cache.entry(forHost: "example.com", now: .now.addingTimeInterval(8 * 24 * 60 * 60),
                                   allowingStale: true), entry)
        XCTAssertNil(cache.entry(forHost: "example.org"))
    }

    func testReadsAndLoadsTheIconsOfAnOpenPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FaviconTests-\(UUID().uuidString)")
        let originalCache = FaviconStore.cache
        FaviconStore.cache = FaviconCache(directory: directory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            await MainActor.run { FaviconStore.cache = originalCache }
        }
        let iconURL = "data:image/png;base64,\(Self.pixelPNG)"
        let pageURL = URL(string: "https://favicon-test.invalid/app/")!
        let webView = WKWebView()
        webView.loadHTMLString(#"<head><link rel="mask-icon" href="m.svg"><link rel="icon" href="\#(iconURL)"></head>"#,
                               baseURL: pageURL)
        try await waitUntil { !webView.isLoading && webView.url == pageURL }

        let candidates = await FaviconStore.candidates(in: webView)
        XCTAssertEqual(candidates, [FaviconCandidate(url: URL(string: iconURL)!)])

        let icon = await FaviconStore.icon(forPage: pageURL, candidates: candidates)
        XCTAssertNotNil(icon)
        XCTAssertNotNil(FaviconStore.cachedIcon(for: pageURL))
        XCTAssertEqual(FaviconStore.cache.entry(forHost: "favicon-test.invalid")?.source, URL(string: iconURL))
    }
}
