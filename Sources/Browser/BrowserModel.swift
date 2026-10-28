import AppKit
import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class BrowserModel {
    /// The profile whose data the window uses, or `nil` for a private window.
    let profileID: UUID?
    /// The profile whose window opened a private window, which lends it its bookmarks and tracker blocking.
    let openerProfileID: UUID?
    let downloads: DownloadManager
    let bookmarks: BookmarkStore
    let contentBlocker: ContentBlocker
    let sitePermissions: SitePermissions
    /// `nil` for a window whose pages aren't remembered.
    let history: HistoryStore?
    let zoomLevels: ZoomStore
    /// The browser each site is told it's in. A private window uses its opener's choices without changing them.
    let compatibility: SiteCompatibility
    /// Shared by the window's tabs. A private window's keeps its cookies and site data in memory, apart from
    /// other windows, until the window closes.
    let websiteDataStore: WKWebsiteDataStore
    /// Offers to save sign-ins and fills them in. `nil` for a window whose pages aren't remembered.
    let passwords: PasswordManager?
    /// The profile's extensions, which a private window doesn't run.
    let extensions: WebExtensionStore?
    /// The window as extensions see it.
    @ObservationIgnored let extensionWindow = WebExtensionWindow()
    /// The window showing these tabs, so links from other apps can open in the frontmost one.
    @ObservationIgnored weak var window: NSWindow?

    private(set) var tabs: [BrowserTab] = [] {
        didSet {
            extensions?.tabsDidChange(in: self, from: oldValue)
            onTabsChange?()
        }
    }
    /// Called when tabs open, close, or show another page, so other devices can list them.
    @ObservationIgnored var onTabsChange: (() -> Void)?
    private var closedTabs: [ClosedTab] = []
    var activeTabID: UUID? {
        didSet {
            guard oldValue != activeTabID else { return }
            if let previousTab = tab(withID: oldValue) {
                // Keep a preview of the page being left for background-tab hover cards.
                previousTab.captureThumbnail(afterScreenUpdates: false)
                previousTab.lastActive = .now
            }
            activeTab?.restore()
            activeTab?.didBecomeSelected()
            extensions?.didActivate(activeTab, previous: tab(withID: oldValue), in: self)
        }
    }
    var addressFocusRequest = 0
    var findFocusRequest = 0
    var isShowingHistory = false
    var isShowingClearData = false
    var isShowingImport = false
    /// Shows the bookmark editor under the address bar's star, for ⌘D.
    var isEditingBookmark = false
    @ObservationIgnored private var suspender: TabSuspender?

    private struct ClosedTab {
        let url: URL?
        let title: String
        /// The tab's back-forward history, restored when it reopens.
        let interactionState: Any?
        let isPinned: Bool
    }

    init(downloads: DownloadManager = DownloadManager(), sitePermissions: SitePermissions = SitePermissions(),
         history: HistoryStore? = nil, zoomLevels: ZoomStore = ZoomStore(defaults: nil),
         websiteDataStore: WKWebsiteDataStore = .default(), passwords: PasswordManager? = nil,
         bookmarks: BookmarkStore = BookmarkStore(defaults: nil), contentBlocker: ContentBlocker = ContentBlocker(),
         extensions: WebExtensionStore? = nil, compatibility: SiteCompatibility = SiteCompatibility(),
         profileID: UUID? = nil, openerProfileID: UUID? = nil) {
        self.profileID = websiteDataStore.isPersistent ? profileID : nil
        self.openerProfileID = openerProfileID
        self.downloads = downloads
        self.bookmarks = bookmarks
        self.contentBlocker = contentBlocker
        self.sitePermissions = sitePermissions
        self.history = history
        self.zoomLevels = zoomLevels
        self.compatibility = compatibility
        self.websiteDataStore = websiteDataStore
        self.passwords = websiteDataStore.isPersistent ? passwords : nil
        self.extensions = websiteDataStore.isPersistent ? extensions : nil
        extensionWindow.browser = self
        addTab()
        suspender = TabSuspender(browser: self)
    }

    /// A window of one of the user's profiles.
    convenience init(profile: ProfileData, downloads: DownloadManager) {
        self.init(downloads: downloads, sitePermissions: profile.sitePermissions, history: profile.history,
                  zoomLevels: profile.zoomLevels, websiteDataStore: profile.websiteDataStore,
                  passwords: profile.passwords, bookmarks: profile.bookmarks, contentBlocker: profile.contentBlocker,
                  extensions: profile.extensions, compatibility: profile.compatibility, profileID: profile.id)
    }

    /// A window that keeps nothing once it closes: no history, zoom levels, site permissions, or passwords, and
    /// cookies and site data its tabs share only with each other. It belongs to no profile, but shows the bookmarks
    /// and blocks trackers like the profile that opened it. Downloads and bookmarks still save.
    static func makePrivate(downloads: DownloadManager, openedFrom profile: ProfileData? = nil) -> BrowserModel {
        BrowserModel(downloads: downloads, sitePermissions: SitePermissions(), history: nil,
                     zoomLevels: ZoomStore(defaults: nil), websiteDataStore: .nonPersistent(),
                     bookmarks: profile?.bookmarks ?? BookmarkStore(defaults: nil),
                     contentBlocker: profile?.contentBlocker ?? ContentBlocker(),
                     compatibility: profile?.compatibility ?? SiteCompatibility(), openerProfileID: profile?.id)
    }

    var isPrivate: Bool {
        !websiteDataStore.isPersistent
    }

    /// A configuration for one of the window's pages. Pop-ups get theirs from WebKit, copied from the opener's,
    /// so they keep its data store, and share its content controller, with its tracker blocking and scripts.
    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = BrowserTab.makeConfiguration()
        configuration.websiteDataStore = websiteDataStore
        contentBlocker.attach(configuration.userContentController)
        if let extensions { configuration.webExtensionController = extensions.controller }
        Passkeys.shared.requestAuthorizationIfNeeded()
        if passwords != nil {
            PasswordAutofill.install(in: configuration.userContentController,
                                     handler: PasswordMessageHandler(browser: self))
        }
        return configuration
    }

    var activeTab: BrowserTab? {
        tab(withID: activeTabID)
    }

    var canReopenClosedTab: Bool {
        !closedTabs.isEmpty
    }

    func tab(withID id: UUID?) -> BrowserTab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
    }

    private func makeTab(configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        adopt(BrowserTab(configuration: configuration ?? makeConfiguration()))
    }

    private func adopt(_ tab: BrowserTab) -> BrowserTab {
        tab.browser = self
        return tab
    }

    func addTab() {
        let tab = makeTab()
        tabs.append(tab)
        activeTabID = tab.id
        requestAddressFocus()
    }

    func duplicateTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let original = tabs[index]
        // The copy starts suspended, so selecting it restores the original's history and scroll position.
        let tab = original.url == nil ? makeTab()
            : adopt(BrowserTab(url: original.url, title: original.pageTitle, interactionState: original.interactionState))
        tab.isPinned = original.isPinned
        tabs.insert(tab, at: index + 1)
        activeTabID = tab.id
    }

    /// Moves a tab to where another one is. A tab moved among the pinned tabs is pinned, and one moved among the
    /// others is unpinned, so the pinned tabs stay first.
    func moveTab(_ id: UUID, to destinationIndex: Int) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == id }),
              tabs.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else { return }
        let isPinned = tabs[destinationIndex].isPinned
        tabs.move(fromOffsets: IndexSet(integer: sourceIndex),
                  toOffset: destinationIndex > sourceIndex ? destinationIndex + 1 : destinationIndex)
        tabs[destinationIndex].isPinned = isPinned
    }

    /// How many tabs at the start of the window are pinned.
    var pinnedCount: Int {
        tabs.prefix(while: \.isPinned).count
    }

    /// Pins a tab after the other pinned tabs, or unpins it to the start of the rest.
    func setPinned(_ isPinned: Bool, for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].isPinned != isPinned else { return }
        let tab = tabs.remove(at: index)
        tab.isPinned = isPinned
        tabs.insert(tab, at: pinnedCount)
    }

    /// Whether Close Other Tabs would close anything. Pinned tabs stay open.
    func canCloseOtherTabs(than id: UUID) -> Bool {
        tabs.contains { $0.id != id && !$0.isPinned }
    }

    /// Closes the other tabs, except pinned ones.
    func closeOtherTabs(than id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let closingIDs = Set(tabs.filter { $0.id != id && !$0.isPinned }.map(\.id))
        for tab in tabs where closingIDs.contains(tab.id) {
            rememberClosedTab(tab)
        }
        tabs.removeAll { closingIDs.contains($0.id) }
        activeTabID = id
    }

    /// Closes the tabs after one, except pinned ones.
    func closeTabs(after id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closingTabs = tabs[(index + 1)...].filter { !$0.isPinned }
        closingTabs.forEach(rememberClosedTab)
        let closingIDs = Set(closingTabs.map(\.id))
        tabs.removeAll { closingIDs.contains($0.id) }
        if let activeTabID, closingIDs.contains(activeTabID) {
            self.activeTabID = id
        }
    }

    func closeActiveTab() {
        guard let activeTabID else { return }
        closeTab(activeTabID)
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        rememberClosedTab(tabs[index])
        tabs.remove(at: index)
        if tabs.isEmpty {
            addTab()
        } else if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Remembers a closing tab so it can reopen, and dismisses the panels its page is waiting to show.
    private func rememberClosedTab(_ tab: BrowserTab) {
        tab.stopWaitingForSelection()
        let isBlank = tab.isNewTab || tab.url == nil
        closedTabs.append(ClosedTab(url: isBlank ? nil : tab.url, title: tab.pageTitle,
                                    interactionState: isBlank ? nil : tab.interactionState, isPinned: tab.isPinned))
        if closedTabs.count > 10 { closedTabs.removeFirst() }
    }

    func reopenClosedTab() {
        guard let closedTab = closedTabs.popLast() else { return }
        guard closedTab.url != nil else {
            addTab()
            return
        }
        // Selecting the suspended tab restores its history, or loads its address.
        let tab = adopt(BrowserTab(url: closedTab.url, title: closedTab.title,
                                   interactionState: closedTab.interactionState))
        tabs.append(tab)
        if closedTab.isPinned { setPinned(true, for: tab.id) }
        activeTabID = tab.id
    }

    /// Opens a tab after the opener and any tabs it opened before, like a page's pop-up or a ⌘-clicked link. A pinned
    /// opener's tabs open first after the pinned tabs. Pass WebKit's configuration for a pop-up, or a request to load.
    @discardableResult
    func openChildTab(of opener: BrowserTab, configuration: WKWebViewConfiguration? = nil,
                      loading request: URLRequest? = nil, select: Bool) -> BrowserTab {
        let tab = makeTab(configuration: configuration)
        tab.isNewTab = false
        tab.openerID = opener.id
        tab.isPopUp = configuration != nil
        // Background tabs lay out at the size they'll be shown at.
        tab.contentView.frame = opener.contentView.frame
        var index = max((tabs.firstIndex { $0.id == opener.id } ?? tabs.count - 1) + 1, pinnedCount)
        while tabs.indices.contains(index), tabs[index].openerID == opener.id {
            index += 1
        }
        tabs.insert(tab, at: index)
        if let request { tab.webView?.load(request) }
        if select { activeTabID = tab.id }
        return tab
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabID = tabs[index].id
    }

    func selectLastTab() {
        guard !tabs.isEmpty else { return }
        selectTab(at: tabs.count - 1)
    }

    func switchTab(by offset: Int) {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == activeTabID }),
              !tabs.isEmpty else { return }
        selectTab(at: (currentIndex + offset + tabs.count) % tabs.count)
    }

    func open(_ url: URL, inNewTab: Bool = false) {
        if inNewTab || activeTab == nil {
            let tab = makeTab()
            tabs.append(tab)
            activeTabID = tab.id
        }
        activeTab?.load(url)
    }

    /// Opens links from other apps in new tabs, using the window's only tab if it's a new tab.
    func openInNewTabs(_ urls: [URL]) {
        for url in urls {
            open(url, inNewTab: !isBlank)
        }
    }

    func navigate(to input: String) {
        guard let url = BrowserAddress.url(for: input) else { return }
        activeTab?.load(url)
    }

    func reload() {
        guard let activeTabID else { return }
        reloadTab(activeTabID)
    }

    func reloadTab(_ id: UUID) {
        guard let tab = tab(withID: id), !tab.isNewTab else { return }
        tab.reload()
    }

    func stopLoading() {
        activeTab?.webView?.stopLoading()
    }

    func goBack() {
        activeTab?.goBack()
    }

    func goForward() {
        activeTab?.webView?.goForward()
    }

    func go(to item: WKBackForwardListItem) {
        activeTab?.webView?.go(to: item)
    }

    func requestAddressFocus() {
        addressFocusRequest += 1
    }

    /// Whether the window only has a new tab, so a restored session can take its place.
    var isBlank: Bool {
        tabs.count == 1 && tabs[0].isNewTab
    }

    func windowSession() -> WindowSession {
        WindowSession(tabs: tabs.map { tab in
            let isBlank = tab.isNewTab || tab.url == nil
            return TabSession(url: isBlank ? nil : tab.url, title: tab.pageTitle,
                              interactionState: isBlank ? nil : tab.interactionState as? Data, isPinned: tab.isPinned)
        }, selectedIndex: tabs.firstIndex { $0.id == activeTabID } ?? 0, profileID: profileID)
    }

    /// Replaces the window's tabs with a saved window's. They start suspended, so only the selected tab loads.
    /// Pinned tabs come first, even from a file that saved them elsewhere.
    func restoreSession(_ session: WindowSession) {
        guard !session.tabs.isEmpty else { return }
        tabs.forEach { $0.stopWaitingForSelection() }
        let restored = session.tabs.map { saved in
            let tab = saved.url == nil ? makeTab()
                : adopt(BrowserTab(url: saved.url, title: saved.title, interactionState: saved.interactionState))
            tab.isPinned = saved.isPinned
            return tab
        }
        let selectedID = restored[min(max(session.selectedIndex, 0), restored.count - 1)].id
        tabs = restored.filter(\.isPinned) + restored.filter { !$0.isPinned }
        activeTabID = selectedID
    }

    // MARK: Find

    /// Shows the find bar, starting with the text last searched for in any app.
    func showFindBar() {
        guard let tab = activeTab, !tab.isNewTab else { return }
        if tab.findText.isEmpty, let text = NSPasteboard(name: .find).string(forType: .string) {
            tab.findText = text
        }
        tab.isFindBarVisible = true
        findFocusRequest += 1
    }

    func findNext(backwards: Bool = false) {
        guard let tab = activeTab, !tab.isNewTab else { return }
        guard !tab.findText.isEmpty else { return showFindBar() }
        tab.isFindBarVisible = true
        tab.find(backwards: backwards)
    }

    func useSelectionForFind() {
        guard let tab = activeTab, !tab.isNewTab else { return }
        Task {
            guard let text = await tab.selectedText(), !text.isEmpty else { return }
            let pasteboard = NSPasteboard(name: .find)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            tab.findText = text
            tab.isFindBarVisible = true
            tab.find()
        }
    }

    func closeFindBar() {
        guard let tab = activeTab else { return }
        tab.isFindBarVisible = false
        tab.focusPage()
    }

    // MARK: Zoom

    var canZoom: Bool {
        activeTab.map { !$0.isNewTab && !$0.isSuspended } ?? false
    }

    func zoomIn() {
        guard canZoom, let tab = activeTab else { return }
        tab.setZoom(ZoomStore.level(after: tab.pageZoom))
    }

    func zoomOut() {
        guard canZoom, let tab = activeTab else { return }
        tab.setZoom(ZoomStore.level(before: tab.pageZoom))
    }

    func resetZoom() {
        guard canZoom else { return }
        activeTab?.setZoom(1)
    }

    // MARK: Print

    /// Prints the active page, with the print panel as a sheet on its window.
    func printActivePage() {
        guard let tab = activeTab, !tab.isNewTab, let webView = tab.webView, let window = webView.window else { return }
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // WebKit prints blank pages unless the operation's view has a size.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    #if DEBUG
    func showWebInspector() {
        guard let tab = activeTab, !tab.isNewTab, let webView = tab.webView else { return }
        WebInspector.show(for: webView)
    }
    #endif

    /// Background tabs that can be suspended to free memory, least recently used first. A pop-up and its opener
    /// can script each other, so neither is suspended while both are open.
    var suspendableTabs: [BrowserTab] {
        var linkedIDs = Set<UUID>()
        for tab in tabs where tab.isPopUp {
            guard let openerID = tab.openerID, self.tab(withID: openerID) != nil else { continue }
            linkedIDs.formUnion([tab.id, openerID])
        }
        return tabs
            .filter { $0.id != activeTabID && $0.canSuspend && !linkedIDs.contains($0.id) }
            .sorted { $0.lastActive < $1.lastActive }
    }

    /// Suspends the tabs in order, except pages playing media. Each is checked again after asking WebKit about
    /// media, since it might have been selected in the meantime.
    func suspendTabs(_ candidates: [BrowserTab]) async {
        for tab in candidates {
            guard !(await tab.isPlayingMedia()), suspendableTabs.contains(where: { $0 === tab }) else { continue }
            tab.suspend()
        }
    }
}
