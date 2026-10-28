import AppKit
import Foundation
import Observation

/// Which browser a page is told it's in. Some sites turn away or limit browsers they don't recognize, though
/// WebKit could show them; telling such a site it's in Chrome or Firefox often lets it work.
enum BrowserIdentity: String, CaseIterable, Identifiable, Codable {
    case safari
    case chrome
    case firefox

    var id: Self { self }

    var title: String {
        switch self {
        case .safari: "Safari (Default)"
        case .chrome: "Chrome"
        case .firefox: "Firefox"
        }
    }

    var shortTitle: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .firefox: "Firefox"
        }
    }

    /// `nil` for WebKit's own user agent, which names Safari.
    var userAgent: String? {
        switch self {
        case .safari:
            nil
        case .chrome:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Chrome/\(ChromeWebStore.compatibleChromeVersion) Safari/537.36"
        case .firefox:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:144.0) Gecko/20100101 Firefox/144.0"
        }
    }
}

/// The browser each site is told it's in, chosen per site in View ▸ Website Compatibility. A site's pages on every
/// subdomain share its choice.
@MainActor
@Observable
final class SiteCompatibility {
    nonisolated static let storageKey = "siteBrowserIdentities"

    /// `nil` keeps the choices in memory only.
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let key: String
    /// Only sites told something other than Safari.
    private(set) var identities: [String: BrowserIdentity]

    /// A profile's choices are saved under its key prefix.
    init(defaults: UserDefaults? = nil, keyPrefix: String = "") {
        self.defaults = defaults
        key = keyPrefix + Self.storageKey
        let saved = defaults?.dictionary(forKey: key) as? [String: String] ?? [:]
        identities = saved.compactMapValues(BrowserIdentity.init)
    }

    static func site(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host() else {
            return nil
        }
        return BrowserTab.site(of: host)
    }

    func identity(for url: URL?) -> BrowserIdentity {
        Self.site(of: url).flatMap { identities[$0] } ?? .safari
    }

    func userAgent(for url: URL?) -> String? {
        identity(for: url).userAgent
    }

    func setIdentity(_ identity: BrowserIdentity, forSite site: String) {
        identities[site] = identity == .safari ? nil : identity
        save()
    }

    func setIdentity(_ identity: BrowserIdentity, for url: URL?) {
        guard let site = Self.site(of: url) else { return }
        setIdentity(identity, forSite: site)
    }

    func removeAll() {
        identities = [:]
        save()
    }

    private func save() {
        defaults?.set(identities.mapValues(\.rawValue), forKey: key)
    }
}

/// The other browsers on the Mac, for pages that need what only another engine has, such as WebUSB, WebHID,
/// Web Serial, or Web Bluetooth.
enum OtherBrowsers {
    struct App: Identifiable, Hashable {
        let url: URL
        let name: String

        var id: URL { url }

        var icon: NSImage {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }
    }

    /// Chromium browsers first, since they support the most web APIs WebKit lacks.
    private static let preferredOrder = [
        "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "net.imput.helium", "org.mozilla.firefox", "com.apple.Safari",
    ]

    static func installed(workspace: NSWorkspace = .shared) -> [App] {
        let ownBundleID = Bundle.main.bundleIdentifier
        let apps = workspace.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            .filter { Bundle(url: $0)?.bundleIdentifier != ownBundleID }
        var seen = Set<String>()
        return apps.compactMap { url -> (App, Int)? in
            let bundleID = Bundle(url: url)?.bundleIdentifier ?? url.path
            guard seen.insert(bundleID).inserted else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            return (App(url: url, name: name), preferredOrder.firstIndex(of: bundleID) ?? preferredOrder.count)
        }
        .sorted { ($0.1, $0.0.name) < ($1.1, $1.0.name) }
        .map(\.0)
    }

    static func open(_ url: URL, in app: App, workspace: NSWorkspace = .shared) {
        workspace.open([url], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
    }
}
