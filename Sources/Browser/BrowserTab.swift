import AppKit
import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    /// The page's web view, or `nil` while the tab is suspended to free its memory.
    private(set) var webView: WKWebView?
    /// Hosts the web view, and the Web Inspector when it's docked, so both move together between windows and tabs.
    let contentView = NSView()
    var isNewTab = true
    /// Pinned tabs stay first in the window, show only their icon, and open links to other sites in new tabs.
    var isPinned = false {
        didSet {
            if isPinned != oldValue { browser?.extensions?.tabDidChange(self, .pinned) }
        }
    }
    /// The tab as extensions see it.
    @ObservationIgnored let extensionTab = WebExtensionTab()
    /// The tab whose page opened this one, so its links and pop-ups open next to each other.
    @ObservationIgnored var openerID: UUID?
    /// Whether another page's script opened this one, and can still reach it through `window.opener`.
    @ObservationIgnored var isPopUp = false
    @ObservationIgnored weak var browser: BrowserModel?
    /// When the tab was last selected, so the least recently used tabs are suspended first.
    @ObservationIgnored var lastActive = ContinuousClock.now
    var favicon: Image?
    var thumbnail: Image?

    private(set) var url: URL?
    private(set) var pageTitle = ""
    private(set) var isLoading = false
    private(set) var estimatedProgress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var hasOnlySecureContent = false
    private(set) var backList: [WKBackForwardListItem] = []
    private(set) var forwardList: [WKBackForwardListItem] = []
    /// Why the page couldn't load, shown in place of it until another page loads.
    private(set) var loadError: PageLoadError?
    /// Whether the failed load left the previous page behind the error, so going back shows that page.
    @ObservationIgnored private var loadErrorCoversPreviousPage = false
    private(set) var pageZoom = 1.0

    /// Whether the page has a password field, so saved passwords for its site can be offered.
    var hasPasswordFields = false

    var isFindBarVisible = false
    var findText = ""
    /// Whether the last search found nothing, shown in the find bar.
    private(set) var findHasNoMatches = false
    @ObservationIgnored private var findTask: Task<Void, Never>?
    /// The page last added to history, so its title follows the page's and a reload isn't another visit.
    @ObservationIgnored private var historyVisit: (id: UUID?, url: URL)?

    @ObservationIgnored private let pageDelegate = PageDelegate()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var faviconTask: Task<Void, Never>?
    /// The history and scroll position a suspended tab brings back when it's restored.
    @ObservationIgnored private var suspendedState: Any?
    private var faviconHost: String?
    /// Panels the page is waiting to show until the tab is selected.
    @ObservationIgnored private var selectionWaiters: [CheckedContinuation<Bool, Never>] = []

    /// Pass the configuration WebKit provides when a page opens a window, so the new page keeps its opener.
    init(configuration: WKWebViewConfiguration = BrowserTab.makeConfiguration()) {
        pageDelegate.tab = self
        extensionTab.tab = self
        install(BrowserWebView(frame: .zero, configuration: configuration))
    }

    /// A suspended tab for a page's saved history, such as a duplicated or reopened tab, which loads when it's selected.
    init(url: URL?, title: String, interactionState: Any?) {
        isNewTab = false
        self.url = url
        pageTitle = title
        suspendedState = interactionState
        favicon = FaviconStore.cachedIcon(for: url)
        faviconHost = url?.host()
        // The page is already in history, so loading it again on restore isn't another visit.
        historyVisit = url.map { (nil, $0) }
        pageDelegate.tab = self
        extensionTab.tab = self
    }

    var isSuspended: Bool {
        webView == nil
    }

    /// The tab's history and scroll position, whether or not it's suspended.
    var interactionState: Any? {
        webView?.interactionState ?? suspendedState
    }

    /// Restoring keeps the suspended page's state until the new web view reports its own, which it only does
    /// once the page starts loading, so the tab's title and address don't flash blank.
    private func install(_ webView: WKWebView, isRestoring: Bool = false) {
        (webView as? BrowserWebView)?.tab = self
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.allowsLinkPreview = true
        webView.frame = contentView.bounds
        webView.autoresizingMask = [.width, .height]
        contentView.addSubview(webView)
        webView.navigationDelegate = pageDelegate
        webView.uiDelegate = pageDelegate
        self.webView = webView

        let options: NSKeyValueObservingOptions = isRestoring ? [] : .initial
        observe(webView, \.url, options) { tab, webView in
            tab.url = tab.loadError?.url ?? webView.url
            tab.browser?.extensions?.tabDidChange(tab, .URL)
            tab.browser?.onTabsChange?()
            // Same-document navigations don't load, but can still change the icon and add to history.
            if !webView.isLoading {
                tab.updateFavicon()
                tab.recordVisit()
            }
        }
        observe(webView, \.title, options) { tab, webView in
            tab.pageTitle = webView.title ?? ""
            tab.updateVisitTitle()
            tab.browser?.extensions?.tabDidChange(tab, .title)
        }
        observe(webView, \.isLoading, options) { tab, webView in
            let didFinish = tab.isLoading && !webView.isLoading
            tab.isLoading = webView.isLoading
            tab.browser?.extensions?.tabDidChange(tab, .loading)
            if didFinish {
                tab.scheduleThumbnail()
                tab.updateFavicon()
            }
        }
        observe(webView, \.estimatedProgress, options) { $0.estimatedProgress = $1.estimatedProgress }
        observe(webView, \.canGoBack, options) { $0.canGoBack = $1.canGoBack }
        observe(webView, \.canGoForward, options) { $0.canGoForward = $1.canGoForward }
        observe(webView, \.hasOnlySecureContent, options) { $0.hasOnlySecureContent = $1.hasOnlySecureContent }
    }

    /// Releases the web view, and with it the page's memory, keeping what the tab strip shows and the state to restore.
    func suspend() {
        guard let webView, !isNewTab else { return }
        stopWaitingForSelection()
        suspendedState = webView.interactionState
        observations.forEach { $0.invalidate() }
        observations = []
        thumbnailTask?.cancel()
        faviconTask?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        isLoading = false
    }

    /// Recreates a suspended tab's web view with its history and scroll position, or loads its address.
    /// A pop-up gets a fresh configuration too, since its tie to the opener can't be restored.
    func restore() {
        guard isSuspended else { return }
        let webView = BrowserWebView(frame: .zero, configuration: browser?.makeConfiguration() ?? Self.makeConfiguration())
        install(webView, isRestoring: true)
        webView.customUserAgent = browser?.compatibility.userAgent(for: url)
        if let suspendedState {
            webView.interactionState = suspendedState
        } else if let url {
            Self.load(url, in: webView)
        }
        suspendedState = nil
    }

    /// Whether suspending would lose nothing the page is doing: loading, showing an error or waiting to show a panel,
    /// using the camera or microphone, or being inspected. Pages with unsaved form input aren't detected, since WebKit
    /// has no cheap way to ask; their history still restores.
    var canSuspend: Bool {
        guard let webView, !isNewTab, !isLoading, loadError == nil, selectionWaiters.isEmpty else { return false }
        #if DEBUG
        if WebInspector.isOpen(for: webView) { return false }
        #endif
        return webView.cameraCaptureState == .none && webView.microphoneCaptureState == .none
    }

    /// Waits until the tab is selected, so a background page's panel can't take over the window.
    /// Returns `false` if the tab is closed or suspended first.
    func waitUntilSelected() async -> Bool {
        guard let browser else { return false }
        if browser.activeTabID == id { return true }
        return await withCheckedContinuation { selectionWaiters.append($0) }
    }

    /// Shows a panel as a sheet on the page's window. A background tab's panel waits until the tab is selected,
    /// so a page can't take over the window, and is dismissed if the tab closes first.
    func present(_ alert: NSAlert, in webView: WKWebView? = nil) async -> NSApplication.ModalResponse? {
        guard let webView = webView ?? self.webView, await waitUntilSelected() else { return nil }
        // The selected tab's page joins the window on SwiftUI's next update.
        for _ in 0..<20 where webView.window == nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard let window = webView.window else { return nil }
        return await alert.beginSheetModal(for: window)
    }

    func didBecomeSelected() {
        resumeSelectionWaiters(true)
    }

    func stopWaitingForSelection() {
        resumeSelectionWaiters(false)
    }

    private func resumeSelectionWaiters(_ isSelected: Bool) {
        let waiters = selectionWaiters
        selectionWaiters = []
        waiters.forEach { $0.resume(returning: isSelected) }
    }

    /// WebKit only answers this asynchronously, so it's checked separately from `canSuspend`.
    func isPlayingMedia() async -> Bool {
        await webView?.requestMediaPlaybackState() == .playing
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
        let safariVersion = safariURL.flatMap { Bundle(url: $0)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            ?? "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0"
        configuration.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isTextInteractionEnabled = true
        WebAuthnShim.install(in: configuration.userContentController, isEntitled: Passkeys.shared.isEntitled)
        #if DEBUG
        WebInspector.enableDeveloperExtras(in: configuration)
        #endif
        return configuration
    }

    /// Mirrors a KVO-observable web view property into observable state.
    private func observe<Value>(_ webView: WKWebView, _ keyPath: KeyPath<WKWebView, Value>,
                                _ options: NSKeyValueObservingOptions,
                                update: @escaping @MainActor (BrowserTab, WKWebView) -> Void) {
        observations.append(webView.observe(keyPath, options: options) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self, webView)
                self.updateHistory()
            }
        })
    }

    /// The back-forward list has no KVO of its own, but every change to it also changes one of the observed properties.
    private func updateHistory() {
        guard let list = webView?.backForwardList else { return }
        if backList != list.backList { backList = list.backList }
        if forwardList != list.forwardList { forwardList = list.forwardList }
    }

    var title: String {
        if !pageTitle.isEmpty { return pageTitle }
        return url?.host() ?? "New Tab"
    }

    var host: String? {
        url?.host()
    }

    /// The part of a host that names its site, so `mail.example.com` and `example.com` are the same site. Without a
    /// list of public suffixes, a short second-level label before a country code, like `co.uk`, counts as a suffix.
    nonisolated static func site(of host: String) -> String {
        let host = host.lowercased()
        let labels = host.split(separator: ".")
        guard labels.count > 2, !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return host }
        let isCountrySuffix = labels[labels.count - 1].count == 2 && labels[labels.count - 2].count <= 3
        return labels.suffix(isCountrySuffix ? 3 : 2).joined(separator: ".")
    }

    /// Whether a link leaves the site the page is on, for pinned tabs, which open such links in a new tab.
    nonisolated static func leavesSite(from current: URL?, to destination: URL?) -> Bool {
        guard let currentHost = current?.host(), let destinationHost = destination?.host(),
              ["http", "https"].contains(destination?.scheme?.lowercased() ?? "") else { return false }
        return site(of: currentHost) != site(of: destinationHost)
    }

    var isSecure: Bool {
        url?.scheme == "https" && hasOnlySecureContent && loadError == nil
    }

    /// Going back from an error that covers the previous page shows that page, which is still the current history item.
    var canNavigateBack: Bool {
        canGoBack || (loadError != nil && loadErrorCoversPreviousPage)
    }

    func load(_ url: URL) {
        isNewTab = false
        restore()
        pageDelegate.isLoadingFromBrowser = true
        if let webView { Self.load(url, in: webView) }
    }

    /// Records a crash of the page's web process, and tells whether it crashed again soon after the last one, in which
    /// case reloading would likely crash it again.
    func recordCrash(at time: ContinuousClock.Instant = .now) -> Bool {
        recentCrashes = recentCrashes.filter { time - $0 < .seconds(30) } + [time]
        return recentCrashes.count > 1
    }

    @ObservationIgnored private var recentCrashes: [ContinuousClock.Instant] = []

    /// A local file, such as an HTML file opened from the Finder, may only read itself.
    private static func load(_ url: URL, in webView: WKWebView) {
        // A site told it's in another browser is told so from the first request.
        webView.customUserAgent = (webView as? BrowserWebView)?.tab?.browser?.compatibility.userAgent(for: url)
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func reload() {
        if loadError != nil {
            retry()
        } else if let webView {
            pageDelegate.isLoadingFromBrowser = true
            webView.reload()
        } else {
            restore()
        }
    }

    func goBack() {
        if loadError != nil, loadErrorCoversPreviousPage {
            clearLoadError()
        } else {
            webView?.goBack()
        }
    }

    /// A page has started to show in the tab: it gets its site's zoom, and joins history.
    func didCommitNavigation() {
        clearLoadError()
        findHasNoMatches = false
        hasPasswordFields = false
        applyZoom()
        recordVisit()
    }

    /// Adds the page shown to history, unless it's the same page as before, ignoring the part after `#`.
    /// Only committed web pages count, so error pages and pop-ups that never loaded are left out.
    private func recordVisit() {
        guard let webView, let url = webView.url, loadError == nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              webView.backForwardList.currentItem?.url == url,
              historyVisit.map({ Self.withoutFragment($0.url) != Self.withoutFragment(url) }) ?? true else { return }
        historyVisit = (browser?.history?.recordVisit(to: url, title: webView.title ?? ""), url)
    }

    private func updateVisitTitle() {
        guard let historyVisit, let id = historyVisit.id, url == historyVisit.url, !pageTitle.isEmpty else { return }
        browser?.history?.updateTitle(of: id, to: pageTitle)
    }

    private static func withoutFragment(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? url
    }

    // MARK: Zoom

    private func applyZoom() {
        let level = browser?.zoomLevels.level(for: host) ?? 1
        pageZoom = level
        if let webView, webView.pageZoom != level { webView.pageZoom = level }
    }

    /// Zooms the page, and remembers the level for its site.
    func setZoom(_ level: Double) {
        guard let webView else { return }
        webView.pageZoom = level
        pageZoom = level
        browser?.zoomLevels.setLevel(level, for: host)
    }

    // MARK: Find

    /// Searches from the start of the current match, so typing more of a word keeps the match it's on.
    func findAsYouType() {
        findTask?.cancel()
        guard let webView, !findText.isEmpty else {
            findHasNoMatches = false
            return
        }
        findTask = Task { [weak self] in
            let script = "(() => { const selection = getSelection(); if (selection.rangeCount) selection.collapseToStart(); })()"
            _ = try? await webView.evaluateJavaScript(script, contentWorld: .defaultClient)
            guard !Task.isCancelled else { return }
            await self?.runFind(backwards: false)
        }
    }

    func find(backwards: Bool = false) {
        findTask?.cancel()
        findTask = Task { [weak self] in await self?.runFind(backwards: backwards) }
    }

    /// WebKit selects and highlights the match it finds, wrapping around the page.
    private func runFind(backwards: Bool) async {
        guard let webView, !findText.isEmpty else { return }
        let text = findText
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        let result = try? await webView.find(text, configuration: configuration)
        guard !Task.isCancelled, findText == text else { return }
        findHasNoMatches = result?.matchFound != true
    }

    func selectedText() async -> String? {
        guard let webView else { return nil }
        return try? await webView.evaluateJavaScript("getSelection().toString()", contentWorld: .defaultClient) as? String
    }

    /// Gives the page keyboard focus.
    func focusPage() {
        guard let webView, let window = webView.window else { return }
        window.makeFirstResponder(webView)
    }

    func showLoadError(_ error: PageLoadError, coversPreviousPage: Bool) {
        loadError = error
        loadErrorCoversPreviousPage = coversPreviousPage
        url = error.url ?? url
    }

    func clearLoadError() {
        guard loadError != nil else { return }
        loadError = nil
        loadErrorCoversPreviousPage = false
        url = webView?.url
    }

    /// Loads the address that failed again, keeping the error up until a page loads.
    func retry() {
        guard let webView else { return }
        pageDelegate.isLoadingFromBrowser = true
        if let url = loadError?.url {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    /// Captures the visible page for hover cards. Only a web view that's on screen has anything to capture.
    func captureThumbnail(afterScreenUpdates: Bool = true) {
        guard !isNewTab, let webView, webView.window != nil,
              webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = 520
        configuration.afterScreenUpdates = afterScreenUpdates
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let image else { return }
            self?.thumbnail = Image(nsImage: image)
        }
    }

    private func scheduleThumbnail() {
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.captureThumbnail()
        }
    }

    /// Reads the icon from the loaded page, showing the host's last known icon until then.
    private func updateFavicon() {
        faviconTask?.cancel()
        guard let url, let host = url.host(), url.scheme == "http" || url.scheme == "https" else {
            favicon = nil
            faviconHost = nil
            return
        }
        if faviconHost != host {
            faviconHost = host
            favicon = FaviconStore.cachedIcon(for: url)
        }
        faviconTask = Task { [weak self] in
            // Pages often set their icon from script just after loading or changing their URL.
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, let webView, !webView.isLoading, webView.url == url else { return }
            let candidates = await FaviconStore.candidates(in: webView)
            guard let icon = await FaviconStore.icon(forPage: url, candidates: candidates,
                                                     remember: !(browser?.isPrivate ?? false)),
                  !Task.isCancelled, self.url == url else { return }
            favicon = icon
        }
    }
}

/// Shows one of several page views, such as the active tab's, inside a view this app owns.
/// Swapping the subview never reloads the page, and AppKit guarantees a view has only one superview.
struct PageHost: NSViewRepresentable {
    let content: NSView

    func makeNSView(context: Context) -> PageHostView {
        PageHostView()
    }

    func updateNSView(_ view: PageHostView, context: Context) {
        view.show(content)
    }
}

final class PageHostView: NSView {
    func show(_ content: NSView) {
        guard content.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
}
