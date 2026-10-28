import Foundation

/// Installs extensions from the Chrome Web Store. WebKit loads the same WebExtensions format Chrome uses, so a store
/// package unwrapped from its CRX signature header is an archive WebKit can load. APIs only Chrome has stay
/// unavailable to the extension.
enum ChromeWebStore {
    static let home = URL(string: "https://chromewebstore.google.com/")!

    /// The Chrome version the store is asked for packages for. Too old a version gets no package for current
    /// extensions.
    static let compatibleChromeVersion = "141.0.0.0"

    enum PackageError: LocalizedError, Equatable {
        case notAPackage
        case unsupportedVersion(UInt32)
        case truncated

        var errorDescription: String? {
            switch self {
            case .notAPackage: "The file isn’t an extension package."
            case .unsupportedVersion(let version): "The extension package uses an unknown format (version \(version))."
            case .truncated: "The extension package is incomplete."
            }
        }
    }

    /// The ID of the extension a store page shows, from either the current store or the old one under
    /// `chrome.google.com/webstore`. IDs are 32 letters from `a` to `p`.
    static func extensionID(from url: URL?) -> String? {
        guard let url, let host = url.host()?.lowercased() else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        let detail: ArraySlice<String>
        switch host {
        case "chromewebstore.google.com":
            guard components.first == "detail" else { return nil }
            detail = components.dropFirst()
        case "chrome.google.com":
            guard components.starts(with: ["webstore", "detail"]) else { return nil }
            detail = components.dropFirst(2)
        default:
            return nil
        }
        return detail.last(where: isExtensionID)
    }

    static func isExtensionID(_ string: String) -> Bool {
        string.count == 32 && string.allSatisfy { ("a"..."p").contains($0) }
    }

    /// Where Chrome downloads an extension's package, redirected to the file itself.
    static func packageURL(for id: String) -> URL {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: compatibleChromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc"),
        ]
        return components.url!
    }

    /// The ZIP archive inside a CRX package, after its signature header. A file that's already a ZIP archive is
    /// returned as it is.
    static func archive(fromPackage data: Data) throws -> Data {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return data }
        guard bytes.starts(with: Array("Cr24".utf8)) else { throw PackageError.notAPackage }
        guard bytes.count >= 12 else { throw PackageError.truncated }
        let version = littleEndian(bytes, at: 4)
        let archiveStart: Int
        switch version {
        case 2:
            // A public key and a signature follow the lengths of both.
            guard bytes.count >= 16 else { throw PackageError.truncated }
            archiveStart = 16 + Int(littleEndian(bytes, at: 8)) + Int(littleEndian(bytes, at: 12))
        case 3:
            archiveStart = 12 + Int(littleEndian(bytes, at: 8))
        default:
            throw PackageError.unsupportedVersion(version)
        }
        guard archiveStart < bytes.count,
              bytes[archiveStart...].starts(with: [0x50, 0x4B, 0x03, 0x04]) else { throw PackageError.truncated }
        return Data(bytes[archiveStart...])
    }

    /// Downloads an extension's package from the store, as a ZIP archive.
    static func downloadArchive(for id: String, session: URLSession = .shared) async throws -> Data {
        var request = URLRequest(url: packageURL(for: id))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw URLError(.badServerResponse)
        }
        // The store answers an unknown or unavailable extension with an empty body.
        guard !data.isEmpty else { throw URLError(.resourceUnavailable) }
        return try archive(fromPackage: data)
    }

    private static func littleEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { value, index in value | UInt32(bytes[offset + index]) << (8 * index) }
    }
}
