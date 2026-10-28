import Observation
import SwiftUI
import UIKit
import WebKit

/// A tab on iPhone or iPad. Its web view is made when the tab first shows, so restored tabs cost nothing until then.
@MainActor
@Observable
final class MobileTab: Identifiable {
    let id = UUID()
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var progress = 0.0
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var hasOnlySecureContent = false
    var snapshot: UIImage?

    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored weak var browser: MobileBrowser?
    @ObservationIgnored private let delegate = MobilePageDelegate()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var configuration: WKWebViewConfiguration?
    @ObservationIgnored private var recentCrashes: [ContinuousClock.Instant] = []

    /// A tab that loads `url` when it first shows, or a page's pop-up with the configuration WebKit gives it.
    init(url: URL? = nil, title: String = "", configuration: WKWebViewConfiguration? = nil) {
        self.url = url
        self.title = title
        self.configuration = configuration
        delegate.tab = self
    }

    var isNewTab: Bool {
        url == nil && webView?.url == nil
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host().map(Bookmark.trimmedHost) ?? "Start Page"
    }

    var isSecure: Bool {
        url?.scheme == "https" && hasOnlySecureContent
    }

    /// Makes the web view the first time the tab shows, loading the address it was restored with.
    @discardableResult
    func makeWebView() -> WKWebView {
        if let webView { return webView }
        let webView = WKWebView(frame: .zero, configuration: configuration ?? MobileBrowser.makeConfiguration())
        configuration = nil
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isInspectable = true
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        self.webView = webView
        observe(webView, \.url) { tab, webView in
            if let url = webView.url { tab.url = url }
            tab.browser?.tabsDidChange()
        }
        observe(webView, \.title) { tab, webView in
            tab.title = webView.title ?? ""
            tab.browser?.tabsDidChange()
        }
        observe(webView, \.estimatedProgress) { $0.progress = $1.estimatedProgress }
        observe(webView, \.isLoading) { $0.isLoading = $1.isLoading }
        observe(webView, \.canGoBack) { $0.canGoBack = $1.canGoBack }
        observe(webView, \.canGoForward) { $0.canGoForward = $1.canGoForward }
        observe(webView, \.hasOnlySecureContent) { $0.hasOnlySecureContent = $1.hasOnlySecureContent }
        if let url, webView.url == nil { webView.load(URLRequest(url: url)) }
        return webView
    }

    func load(_ url: URL) {
        self.url = url
        makeWebView().load(URLRequest(url: url))
    }

    func reload() {
        guard let webView else { return }
        if webView.url == nil, let url { webView.load(URLRequest(url: url)) } else { webView.reload() }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func stopLoading() { webView?.stopLoading() }

    /// Whether the page crashed again within half a minute, when reloading it would likely crash it again.
    func recordCrash(at time: ContinuousClock.Instant = .now) -> Bool {
        recentCrashes = recentCrashes.filter { time - $0 < .seconds(30) } + [time]
        return recentCrashes.count > 1
    }

    /// Keeps a picture of the page for the tab overview.
    func captureSnapshot() {
        guard let webView, webView.window != nil, webView.bounds.width > 0 else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 360
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            if let image { self?.snapshot = image }
        }
    }

    private func observe<Value>(_ webView: WKWebView, _ keyPath: KeyPath<WKWebView, Value>,
                                update: @escaping @MainActor (MobileTab, WKWebView) -> Void) {
        observations.append(webView.observe(keyPath, options: .initial) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self, webView)
            }
        })
    }
}

/// Handles what pages ask of the browser: pop-ups, links to apps, closing, and crashes.
@MainActor
final class MobilePageDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var tab: MobileTab?

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if ["http", "https", "about", "blob", "data", "file"].contains(scheme) { return .allow }
        // Phone numbers, mail, maps, and App Store links open in their apps.
        await UIApplication.shared.open(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let browser = tab?.browser else { return nil }
        return browser.openTab(configuration: configuration).makeWebView()
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab else { return }
        tab.browser?.close(tab)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab, !tab.recordCrash() else { return }
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab?.captureSnapshot()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await present(message: message, host: frame.securityOrigin.host, buttons: ["OK"])
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await present(message: message, host: frame.securityOrigin.host, buttons: ["Cancel", "OK"]) == 1
    }

    /// Shows a page's dialog over the browser, naming the site that shows it.
    private func present(message: String, host: String, buttons: [String]) async -> Int {
        guard let presenter = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return 0 }
        let top = sequence(first: presenter, next: \.presentedViewController).reversed().first ?? presenter
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: host.isEmpty ? nil : "\(host) says:", message: message,
                                          preferredStyle: .alert)
            for (index, title) in buttons.enumerated() {
                alert.addAction(UIAlertAction(title: title, style: index == 0 && buttons.count > 1 ? .cancel : .default) { _ in
                    continuation.resume(returning: index)
                })
            }
            top.present(alert, animated: true)
        }
    }
}

/// The browser on iPhone and iPad: its tabs, the selected profile's bookmarks, and iCloud sync with the Mac.
@MainActor
@Observable
final class MobileBrowser {
    static let profileKey = "selectedProfile"
    static let sessionKey = "mobileSession"

    private(set) var tabs: [MobileTab] = []
    var activeTabID: UUID? {
        didSet {
            if oldValue != activeTabID { tab(withID: oldValue)?.captureSnapshot() }
            saveSession()
        }
    }
    /// The profile whose bookmarks and tabs sync, chosen among those synced from the Mac.
    private(set) var profileID: UUID
    private(set) var bookmarks: BookmarkStore
    let sync: CloudSync
    @ObservationIgnored private let defaults: UserDefaults

    private struct SavedSession: Codable {
        var urls: [URL?]
        var titles: [String]
        var selectedIndex: Int
    }

    init(sync: CloudSync, defaults: UserDefaults = .standard) {
        self.sync = sync
        self.defaults = defaults
        let profileID = defaults.string(forKey: Self.profileKey).flatMap(UUID.init(uuidString:)) ?? {
            let id = UUID()
            defaults.set(id.uuidString, forKey: Self.profileKey)
            return id
        }()
        self.profileID = profileID
        bookmarks = BookmarkStore(defaults: defaults, keyPrefix: Self.keyPrefix(for: profileID))
        restoreSession()
        registerForSync()
    }

    var activeTab: MobileTab? {
        tab(withID: activeTabID)
    }

    func tab(withID id: UUID?) -> MobileTab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
    }

    /// Profiles to choose from: the ones synced from other devices, and this one.
    var profileChoices: [(id: UUID, name: String)] {
        var choices = sync.remoteProfileNames.map { (id: $0.key, name: $0.value) }
        if !choices.contains(where: { $0.id == profileID }) { choices.append((profileID, "This iPhone")) }
        return choices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var otherDevices: [DeviceTabs] {
        sync.otherDevices[profileID] ?? []
    }

    /// Switches to another profile's bookmarks and tabs list. Open tabs stay open.
    func selectProfile(_ id: UUID) {
        guard id != profileID else { return }
        profileID = id
        defaults.set(id.uuidString, forKey: Self.profileKey)
        bookmarks = BookmarkStore(defaults: defaults, keyPrefix: Self.keyPrefix(for: id))
        registerForSync()
    }

    // MARK: Tabs

    @discardableResult
    func openTab(url: URL? = nil, configuration: WKWebViewConfiguration? = nil, select: Bool = true) -> MobileTab {
        let tab = MobileTab(url: nil, configuration: configuration)
        tab.browser = self
        let index = tabs.firstIndex { $0.id == activeTabID }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: index)
        if let url { tab.load(url) }
        if select { activeTabID = tab.id }
        tabsDidChange()
        return tab
    }

    func close(_ tab: MobileTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            openTab()
        } else if activeTabID == tab.id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        tabsDidChange()
    }

    func closeAllTabs() {
        tabs = []
        openTab()
    }

    /// Opens what was typed: an address, or a search with the chosen engine.
    func navigate(to input: String) {
        guard let url = BrowserAddress.url(for: input) else { return }
        if let tab = activeTab { tab.load(url) } else { openTab(url: url) }
        tabsDidChange()
    }

    func open(_ url: URL, inNewTab: Bool = false) {
        if inNewTab || activeTab == nil { openTab(url: url) } else { activeTab?.load(url) }
    }

    /// Saves the tabs and lists them for other devices.
    func tabsDidChange() {
        saveSession()
        sync.tabsDidChange(in: profileID)
    }

    // MARK: Saving

    private func saveSession() {
        let session = SavedSession(urls: tabs.map(\.url), titles: tabs.map(\.title),
                                   selectedIndex: tabs.firstIndex { $0.id == activeTabID } ?? 0)
        defaults.set(try? JSONEncoder().encode(session), forKey: Self.sessionKey)
    }

    private func restoreSession() {
        let session = defaults.data(forKey: Self.sessionKey)
            .flatMap { try? JSONDecoder().decode(SavedSession.self, from: $0) }
        let restored = (session?.urls ?? []).enumerated().map { index, url in
            MobileTab(url: url, title: session?.titles[safe: index] ?? "")
        }
        for tab in restored { tab.browser = self }
        tabs = restored.isEmpty ? [MobileTab()] : restored
        tabs.forEach { $0.browser = self }
        activeTabID = tabs[min(max(session?.selectedIndex ?? 0, 0), tabs.count - 1)].id
    }

    private func registerForSync() {
        sync.register(profileID: profileID, name: UIDevice.current.name, bookmarks: bookmarks) { [weak self] in
            (self?.tabs ?? []).compactMap { tab in
                guard let url = tab.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                return SyncedTab(title: tab.displayTitle, url: url)
            }
        }
    }

    private static func keyPrefix(for profileID: UUID) -> String {
        "profile.\(profileID.uuidString)."
    }

    /// Identifies as Safari, so sites give the full mobile site rather than an in-app browser's.
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        configuration.applicationNameForUserAgent = "Version/\(version.majorVersion).\(version.minorVersion) "
            + "Mobile/15E148 Safari/604.1"
        configuration.allowsInlineMediaPlayback = true
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
