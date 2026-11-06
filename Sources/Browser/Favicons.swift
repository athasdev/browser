import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// An icon a page declares with `<link rel="icon">` or `<link rel="apple-touch-icon">`.
struct FaviconCandidate: Equatable, Sendable {
    let url: URL
    /// Widths from the `sizes` attribute, empty when the page doesn't say.
    let sizes: [Int]
    let isScalable: Bool
    let isTouchIcon: Bool

    init(url: URL, sizes: [Int] = [], isScalable: Bool = false, isTouchIcon: Bool = false) {
        self.url = url
        self.sizes = sizes
        self.isScalable = isScalable
        self.isTouchIcon = isTouchIcon
    }

    /// Reads a `<link>` element's attributes. `mask-icon` is left out because it's a monochrome template,
    /// and SVG icons because decoding them would run an SVG parser outside WebKit's sandbox.
    init?(rel: String, href: String, sizes: String = "", type: String = "", baseURL: URL) {
        let rels = Set(rel.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        let isTouchIcon = !rels.isDisjoint(with: ["apple-touch-icon", "apple-touch-icon-precomposed"])
        let href = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rels.contains("icon") || isTouchIcon, !href.isEmpty,
              let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
              ["http", "https", "data"].contains(url.scheme?.lowercased() ?? ""),
              type.lowercased() != "image/svg+xml", url.pathExtension.lowercased() != "svg",
              !url.absoluteString.lowercased().hasPrefix("data:image/svg") else { return nil }
        let sizeTokens = sizes.lowercased().split(whereSeparator: \.isWhitespace)
        self.init(url: url,
                  sizes: sizeTokens.compactMap { $0.split(separator: "x").first.flatMap { Int($0) } },
                  isScalable: sizeTokens.contains("any"),
                  isTouchIcon: isTouchIcon)
    }

    /// Scans the `<head>` of a page's HTML for icons, honoring `<base href>`.
    static func candidates(inHTML html: String, baseURL: URL) -> [FaviconCandidate] {
        let head = html.range(of: "</head>", options: .caseInsensitive).map { html[..<$0.lowerBound] } ?? html[...]
        let tag = /<(link|base)\b([^>]*)>/.ignoresCase()
        let attribute = /([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/
        var base = baseURL
        var candidates: [FaviconCandidate] = []
        for match in head.matches(of: tag) {
            var attributes: [String: String] = [:]
            for pair in match.output.2.matches(of: attribute) {
                let value = pair.output.2 ?? pair.output.3 ?? pair.output.4 ?? ""
                attributes[pair.output.1.lowercased()] = String(value).replacing("&amp;", with: "&")
            }
            if match.output.1.lowercased() == "base" {
                if let href = attributes["href"], let url = URL(string: href, relativeTo: baseURL) {
                    base = url.absoluteURL
                }
            } else if let candidate = FaviconCandidate(rel: attributes["rel"] ?? "", href: attributes["href"] ?? "",
                                                       sizes: attributes["sizes"] ?? "",
                                                       type: attributes["type"] ?? "", baseURL: base) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    /// Icon addresses to try, best first, for a 16–32 pt icon on a 2x display, ending with the site's `/favicon.ico`.
    static func ranked(_ candidates: [FaviconCandidate], pageURL: URL) -> [URL] {
        let sorted = candidates.enumerated().sorted { first, second in
            let (a, b) = (first.element.rank, second.element.rank)
            return (a.tier, a.distance, first.offset) < (b.tier, b.distance, second.offset)
        }
        var urls: [URL] = []
        for url in sorted.map(\.element.url) + [defaultIconURL(for: pageURL)].compactMap({ $0 })
        where !urls.contains(url) {
            urls.append(url)
        }
        return urls
    }

    static func defaultIconURL(for pageURL: URL) -> URL? {
        guard ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else { return nil }
        return URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
    }

    /// Known sizes of at least 32 px come first, closest to 64 px. A scalable icon beats one of unknown or small size,
    /// and touch icons, which are usually opaque squares, come last.
    private var rank: (tier: Int, distance: Int) {
        if isTouchIcon { return (4, abs((sizes.max() ?? 180) - 64)) }
        if let size = sizes.filter({ $0 >= 32 }).min(by: { abs($0 - 64) < abs($1 - 64) }) { return (0, abs(size - 64)) }
        if isScalable { return (1, 0) }
        if sizes.isEmpty { return (2, 0) }
        return (3, -(sizes.max() ?? 0))
    }
}

/// Icon files kept in Caches, one per host, so icons show without the network after a relaunch.
struct FaviconCache: Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let source: URL
        let data: Data
    }

    let directory: URL
    var maxAge: Duration = .seconds(7 * 24 * 60 * 60)

    /// The saved icon for a host. Past `maxAge` it's only returned with `allowingStale`, for showing an icon
    /// right away while a fresh one loads; an old icon beats none.
    func entry(forHost host: String, now: Date = .now, allowingStale: Bool = false) -> Entry? {
        let file = fileURL(forHost: host)
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
              allowingStale || now.timeIntervalSince(modified) < TimeInterval(maxAge.components.seconds),
              let data = try? Data(contentsOf: file) else { return nil }
        return try? PropertyListDecoder().decode(Entry.self, from: data)
    }

    func save(_ entry: Entry, forHost host: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? PropertyListEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(forHost: host), options: .atomic)
    }

    func removeEntries(since date: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantFuture) >= date { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func fileURL(forHost host: String) -> URL {
        directory.appending(path: host.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? host)
    }
}

/// Site icons shared by tabs, the bookmarks bar, and the new tab page.
@MainActor
enum FaviconStore {
    private struct Icon: Sendable {
        let source: URL
        let image: Image
    }

    static var cache = FaviconCache(directory: URL.cachesDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "dev.athas.browser")
        .appending(path: "Favicons"))
    private static var icons: [String: Icon] = [:]
    private static var requests: [String: Task<Icon?, Never>] = [:]
    /// When a host's icon couldn't be found, so a slow network doesn't leave it without one for long.
    private static var missingHosts: [String: ContinuousClock.Instant] = [:]
    private static var failedSources: Set<URL> = []

    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Forgets the icons kept in memory, and removes the ones saved to disk since `date`.
    static func clear(since date: Date) async {
        icons = [:]
        missingHosts = [:]
        failedSources = []
        await removeFiles(in: cache, since: date)
    }

    @concurrent
    nonisolated private static func removeFiles(in cache: FaviconCache, since date: Date) async {
        cache.removeEntries(since: date)
    }

    static func cachedIcon(for url: URL?) -> Image? {
        url?.host().flatMap { icons[$0]?.image }
    }

    /// The icon kept for a site, in memory or on disk, without touching the network, so restored and
    /// suspended tabs show their icons as soon as the app opens. An old icon on disk still counts here;
    /// loading the page replaces it.
    static func storedIcon(for url: URL?) async -> Image? {
        guard let host = url?.host() else { return nil }
        if let icon = icons[host] { return icon.image }
        guard let icon = await diskIcon(forHost: host, in: cache, allowingStale: true) else { return nil }
        // Another load may have kept a fresher icon meanwhile.
        if let current = icons[host] { return current.image }
        icons[host] = icon
        return icon.image
    }

    /// An icon for a site that isn't open, such as a bookmark: the cached one, the site's `/favicon.ico`,
    /// or else the best icon its page declares.
    static func icon(for url: URL) async -> Image? {
        guard let host = url.host() else { return nil }
        if let icon = icons[host] { return icon.image }
        if let missing = missingHosts[host], ContinuousClock.now - missing < .seconds(300) { return nil }

        let icon = await deduplicated(host, host: host) {
            if let icon = await diskIcon(forHost: host, in: cache) { return icon }
            guard let fallback = FaviconCandidate.defaultIconURL(for: url) else { return nil }
            if let icon = await download(fallback, forHost: host, into: cache) { return icon }
            guard let (html, pageURL) = await page(at: url) else { return nil }
            let candidates = FaviconCandidate.candidates(inHTML: html, baseURL: pageURL)
            for source in FaviconCandidate.ranked(candidates, pageURL: pageURL).prefix(4) where source != fallback {
                if let icon = await download(source, forHost: host, into: cache) { return icon }
            }
            return nil
        }
        missingHosts[host] = icon == nil ? .now : nil
        return icon?.image
    }

    /// The best of the icons an open page declares, downloaded only when it isn't the one already cached.
    /// A private window's icons aren't kept, in memory or on disk.
    static func icon(forPage url: URL, candidates: [FaviconCandidate], remember: Bool = true) async -> Image? {
        guard let host = url.host() else { return nil }
        let sources = FaviconCandidate.ranked(candidates, pageURL: url).filter { !failedSources.contains($0) }.prefix(4)
        guard let best = sources.first else { return nil }
        if let icon = icons[host], icon.source == best { return icon.image }
        guard remember else {
            for source in sources {
                if let icon = await download(source, forHost: host, into: nil) { return icon.image }
            }
            return nil
        }

        let icon = await deduplicated(best.absoluteString, host: host) {
            if let icon = await diskIcon(forHost: host, in: cache), icon.source == best { return icon }
            for source in sources {
                if let icon = await download(source, forHost: host, into: cache) { return icon }
                failedSources.insert(source)
            }
            return nil
        }
        if icon != nil { missingHosts[host] = nil }
        return icon?.image
    }

    /// Reads the icon links of the page a web view shows, in a content world the page's scripts can't reach.
    static func candidates(in webView: WKWebView) async -> [FaviconCandidate] {
        let script = """
            Array.from(document.querySelectorAll('link[rel][href]'), link => ({
                rel: link.rel, href: link.href, sizes: link.getAttribute('sizes') || '', type: link.type
            }))
            """
        guard let pageURL = webView.url,
              let links = try? await webView.evaluateJavaScript(script, contentWorld: .defaultClient) as? [[String: String]]
        else { return [] }
        return links.compactMap {
            FaviconCandidate(rel: $0["rel"] ?? "", href: $0["href"] ?? "", sizes: $0["sizes"] ?? "",
                             type: $0["type"] ?? "", baseURL: pageURL)
        }
    }

    /// Shares one load between everything asking for the same icon, and keeps the result for the host.
    private static func deduplicated(_ key: String, host: String,
                                     _ load: @escaping @MainActor () async -> Icon?) async -> Icon? {
        if let request = requests[key] { return await request.value }
        let request = Task(operation: load)
        requests[key] = request
        let icon = await request.value
        requests[key] = nil
        if let icon { icons[host] = icon }
        return icon
    }

    @concurrent
    nonisolated private static func diskIcon(forHost host: String, in cache: FaviconCache,
                                             allowingStale: Bool = false) async -> Icon? {
        guard let entry = cache.entry(forHost: host, allowingStale: allowingStale),
              let image = image(from: entry.data) else { return nil }
        return Icon(source: entry.source, image: image)
    }

    @concurrent
    nonisolated private static func download(_ source: URL, forHost host: String,
                                             into cache: FaviconCache?) async -> Icon? {
        guard let (data, _) = await fetch(source, limit: FaviconData.maxIconBytes,
                                          accepting: FaviconData.isIconMIMEType),
              !data.isTruncated, let image = image(from: data.bytes) else { return nil }
        cache?.save(FaviconCache.Entry(source: source, data: data.bytes), forHost: host)
        return Icon(source: source, image: image)
    }

    /// The start of a page's HTML, which is enough to find the icons in its `<head>`.
    @concurrent
    nonisolated private static func page(at url: URL) async -> (String, URL)? {
        guard let (data, pageURL) = await fetch(url, limit: FaviconData.maxPageBytes,
                                                accepting: FaviconData.isPageMIMEType) else { return nil }
        return (String(decoding: data.bytes, as: UTF8.self), pageURL)
    }

    /// Stops reading once the response is larger than `limit`, so a huge or endless file can't fill memory.
    nonisolated private static func fetch(_ url: URL, limit: Int,
                                          accepting isAccepted: (String?) -> Bool) async -> (FaviconData.Read, URL)? {
        guard let (bytes, response) = try? await session.bytes(from: url) else { return nil }
        defer { bytes.task.cancel() }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              isAccepted(response.mimeType),
              let data = try? await FaviconData.read(bytes, limit: limit), !data.bytes.isEmpty
        else { return nil }
        return (data, response.url ?? url)
    }

    nonisolated private static func image(from data: Data) -> Image? {
        guard let image = FaviconData.image(from: data) else { return nil }
        return Image(nsImage: NSImage(cgImage: image, size: .zero))
    }
}

/// Limits on the icons and pages read to find a site's icon. Icons are decoded in the app's own process,
/// outside WebKit's sandbox, so only small files in a few raster formats are accepted.
enum FaviconData {
    static let maxIconBytes = 512 * 1024
    static let maxPageBytes = 1024 * 1024
    /// Icons show at 14–32 pt, so larger images are scaled down as they're decoded.
    static let maxPixelSize = 128

    struct Read: Equatable {
        let bytes: Data
        /// Whether the response had more bytes than the limit, which were left unread.
        let isTruncated: Bool
    }

    /// Reads up to `limit` bytes, stopping at the first byte past it.
    static func read<Bytes: AsyncSequence>(_ bytes: Bytes, limit: Int) async throws -> Read
    where Bytes.Element == UInt8 {
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { return Read(bytes: data, isTruncated: true) }
            data.append(byte)
        }
        return Read(bytes: data, isTruncated: false)
    }

    /// Servers often send `.ico` files as untyped binary data, so that's accepted too. The file's
    /// first bytes decide whether it's decoded.
    static func isIconMIMEType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else { return true }
        return (mimeType.hasPrefix("image/") && mimeType != "image/svg+xml") || mimeType == "application/octet-stream"
    }

    static func isPageMIMEType(_ mimeType: String?) -> Bool {
        ["text/html", "application/xhtml+xml"].contains(mimeType?.lowercased())
    }

    /// The format a file's first bytes identify, among PNG, ICO, JPEG, GIF, and WebP.
    static func imageType(of data: Data) -> UTType? {
        let header = [UInt8](data.prefix(12))
        func starts(with prefix: String) -> Bool { header.starts(with: Array(prefix.utf8)) }
        if header.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if header.starts(with: [0x00, 0x00, 0x01, 0x00]) { return .ico }
        if header.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts(with: "GIF87a") || starts(with: "GIF89a") { return .gif }
        if starts(with: "RIFF"), header.count == 12, header[8...].elementsEqual("WEBP".utf8) { return .webP }
        return nil
    }

    /// Decodes an icon whose bytes match one of the accepted formats, picking the size closest to 64 px
    /// from an `.ico` file and scaling it down to `maxPixelSize`.
    static func image(from data: Data) -> CGImage? {
        guard data.count <= maxIconBytes, let type = imageType(of: data),
              let source = CGImageSourceCreateWithData(data as CFData, [
                  kCGImageSourceTypeIdentifierHint: type.identifier,
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              CGImageSourceGetType(source) as String? == type.identifier else { return nil }
        func width(at index: Int) -> Int {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        }
        guard let index = (0..<min(CGImageSourceGetCount(source), 16))
            .min(by: { abs(width(at: $0) - 64) < abs(width(at: $1) - 64) }) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }
}
