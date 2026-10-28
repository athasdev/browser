import AppKit
import SwiftUI
import SystemConfiguration

@main
struct BrowserApp: App {
    static let windowID = "browser"
    static let privateWindowID = "private"
    static let bookmarksWindowID = "bookmarks"

    @NSApplicationDelegateAdaptor(BrowserAppDelegate.self) private var appDelegate
    @State private var downloads = DownloadManager()
    @State private var session: SessionStore
    @State private var profiles: ProfileStore

    /// Unit tests run inside the app, which then shouldn't reopen or overwrite the user's windows, profiles, and
    /// history.
    init() {
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let session = SessionStore(file: isRunningTests ? nil : .applicationSupport(named: "Session.plist"),
                                   restoresWindows: SessionPreferences.restoresWindows)
        _session = State(initialValue: session)
        let sync = isRunningTests ? nil : CloudSync(directory: StoreFile.applicationSupportDirectory,
                                                    deviceName: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac",
                                                    platform: "Mac")
        _profiles = State(initialValue: ProfileStore(session: session,
                                                     services: isRunningTests ? .inMemory : .live, sync: sync))
    }

    var body: some Scene {
        WindowGroup(id: Self.windowID, for: ProfileWindowRequest.self) { $request in
            BrowserWindow(profiles: profiles, downloads: downloads, session: session, request: request)
                .frame(minWidth: 680, minHeight: 440)
        }
        .windowStyle(.hiddenTitleBar)
        // The session store reopens the windows with their tabs, so the system doesn't reopen them too.
        .restorationBehavior(.disabled)
        .commands {
            BrowserCommands(profiles: profiles, session: session, updater: .shared)
        }

        // A private window joins neither history nor the session, and isn't reopened.
        WindowGroup("Private Window", id: Self.privateWindowID, for: ProfileWindowRequest.self) { $request in
            BrowserWindow(profiles: profiles, downloads: downloads, session: nil, request: request, isPrivate: true)
                .frame(minWidth: 680, minHeight: 440)
        }
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)

        // One window per profile, which a second request brings to the front.
        WindowGroup("Bookmarks", id: Self.bookmarksWindowID, for: UUID.self) { $profileID in
            ManageBookmarksWindow(profiles: profiles, profileID: profileID ?? profiles.defaultProfileID)
        }
        .restorationBehavior(.disabled)
        .defaultSize(width: 720, height: 520)

        Settings {
            SettingsView(profiles: profiles, passkeys: .shared, updater: .shared)
        }
    }
}

private struct BrowserModelKey: FocusedValueKey {
    typealias Value = BrowserModel
}

extension FocusedValues {
    var browserModel: BrowserModel? {
        get { self[BrowserModelKey.self] }
        set { self[BrowserModelKey.self] = newValue }
    }
}

private struct BrowserCommands: Commands {
    let profiles: ProfileStore
    let session: SessionStore
    let updater: AppUpdater
    @FocusedValue(\.browserModel) private var browser
    @Environment(\.openWindow) private var openWindow
    @AppStorage(BookmarksBarVisibility.storageKey) private var bookmarksBarVisibility = BookmarksBarVisibility.always
    @AppStorage(TabLayout.storageKey) private var tabLayout = TabLayout.horizontal
    @AppStorage(TabLayout.hiddenStorageKey) private var tabsHidden = false

    /// The focused window's profile, or the one that opened it if it's private, or else the default profile.
    private var profile: ProfileData {
        profiles.data(for: browser?.profileID ?? browser?.openerProfileID)
    }

    private var bookmarks: BookmarkStore {
        browser?.bookmarks ?? profile.bookmarks
    }

    private var history: HistoryStore {
        profile.history
    }

    private func newWindow(in profileID: UUID?) {
        openWindow(id: BrowserApp.windowID,
                   value: ProfileWindowRequest(profileID: profileID ?? profiles.defaultProfileID))
    }

    private var bookmarkableTab: BrowserTab? {
        guard let tab = browser?.activeTab, !tab.isNewTab, tab.url != nil else { return nil }
        return tab
    }

    /// What the active page's site is told about the browser. Changing it reloads the page to tell it again.
    private var siteIdentity: Binding<BrowserIdentity> {
        Binding {
            browser?.compatibility.identity(for: pageTab?.url) ?? .safari
        } set: { identity in
            guard let browser, let tab = pageTab else { return }
            browser.compatibility.setIdentity(identity, for: tab.url)
            browser.reloadTab(tab.id)
        }
    }

    private var pageTab: BrowserTab? {
        guard let tab = browser?.activeTab, !tab.isNewTab else { return nil }
        return tab
    }

    var body: some Commands {
        if updater.isAvailable {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { newWindow(in: profile.id) }
                .keyboardShortcut("n", modifiers: .command)
            Menu("New Window in Profile") {
                // The first nine profiles have shortcuts, like tabs do.
                ForEach(Array(profiles.profiles.prefix(9).enumerated()), id: \.element.id) { index, profile in
                    Button(profile.displayName) { newWindow(in: profile.id) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                }
                ForEach(profiles.profiles.dropFirst(9)) { profile in
                    Button(profile.displayName) { newWindow(in: profile.id) }
                }
            }
            Button("New Private Window") {
                openWindow(id: BrowserApp.privateWindowID, value: ProfileWindowRequest(profileID: profile.id))
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Tab") { browser?.addTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Reopen Closed Tab") { browser?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Close Tab") { browser?.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(replacing: .importExport) {
            Button("Import From Browser…") { browser?.isShowingImport = true }
                .disabled(browser == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { browser?.printActivePage() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(pageTab?.webView == nil)
        }
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") { browser?.showFindBar() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { browser?.findNext() }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { browser?.findNext(backwards: true) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { browser?.useSelectionForFind() }
                    .keyboardShortcut("e", modifiers: .command)
            }
            .disabled(pageTab == nil)
            // Replacing the group removes these too, so they're sent to the page or text field as AppKit would.
            Menu("Spelling and Grammar") {
                Button("Show Spelling and Grammar") { send(#selector(NSText.showGuessPanel(_:))) }
                    .keyboardShortcut(":", modifiers: .command)
                Button("Check Document Now") { send(#selector(NSText.checkSpelling(_:))) }
                    .keyboardShortcut(";", modifiers: .command)
            }
            Menu("Speech") {
                Button("Start Speaking") { send(#selector(NSTextView.startSpeaking(_:))) }
                Button("Stop Speaking") { send(#selector(NSTextView.stopSpeaking(_:))) }
            }
        }
        CommandMenu("Tabs") {
            Button("Next Tab") { browser?.switchTab(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { browser?.switchTab(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Cycle to Next Tab") { browser?.switchTab(by: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Cycle to Previous Tab") { browser?.switchTab(by: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

            Divider()

            ForEach(1...8, id: \.self) { number in
                Button("Select Tab \(number)") { browser?.selectTab(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
            Button("Select Last Tab") { browser?.selectLastTab() }
                .keyboardShortcut("9", modifiers: .command)

            Divider()

            Button(browser?.activeTab?.isPinned == true ? "Unpin Tab" : "Pin Tab") {
                guard let browser, let tab = browser.activeTab else { return }
                browser.setPinned(!tab.isPinned, for: tab.id)
            }
            .disabled(browser?.activeTab == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Open Location") { browser?.requestAddressFocus() }
                .keyboardShortcut("l", modifiers: .command)
            Button("Reload Page") { browser?.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Actual Size") { browser?.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(pageTab.map { $0.pageZoom == 1 } ?? true)
            Button("Zoom In") { browser?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!(browser?.canZoom ?? false))
            Button("Zoom Out") { browser?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!(browser?.canZoom ?? false))
            Divider()
            Picker("Website Compatibility", selection: siteIdentity) {
                ForEach(BrowserIdentity.allCases) { identity in
                    Text(identity.title).tag(identity)
                }
            }
            .disabled(browser?.isPrivate != false || SiteCompatibility.site(of: pageTab?.url) == nil)
            Menu("Open Page In") {
                ForEach(OtherBrowsers.installed()) { app in
                    Button(app.name) {
                        if let url = pageTab?.url { OtherBrowsers.open(url, in: app) }
                    }
                }
            }
            .disabled(pageTab?.url == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(tabLayout == .vertical ? "Use Horizontal Tabs" : "Use Vertical Tabs") {
                tabLayout = tabLayout.toggled
                tabsHidden = false
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            Button(tabsHidden ? "Show Tabs" : "Hide Tabs") { tabsHidden.toggle() }
                .keyboardShortcut("s", modifiers: .command)
            Divider()
            Picker("Bookmarks Bar", selection: $bookmarksBarVisibility) {
                ForEach(BookmarksBarVisibility.allCases) { visibility in
                    Text(visibility.title).tag(visibility)
                }
            }
            Button(bookmarksBarVisibility == .never ? "Show Bookmarks Bar" : "Hide Bookmarks Bar") {
                bookmarksBarVisibility = bookmarksBarVisibility == .never ? .always : .never
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
        }
        CommandMenu("History") {
            Button("Back") { browser?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            Button("Reopen All Windows from Last Session") {
                // A private window can't take the restored tabs.
                for profileID in session.reopenLastSession(reusing: browser?.isPrivate == true ? nil : browser) {
                    newWindow(in: profileID)
                }
            }
            .disabled(session.reopenableWindows.isEmpty)

            let recentVisits = history.recentVisits(limit: 15)
            if !recentVisits.isEmpty {
                Divider()
                ForEach(recentVisits) { visit in
                    Button(Self.menuTitle(visit.displayTitle)) { browser?.open(visit.url) }
                }
            }

            if let devices = profiles.sync?.otherDevices[profile.id], !devices.isEmpty {
                Divider()
                Menu("Tabs on Other Devices") {
                    ForEach(devices) { device in
                        Section(device.name) {
                            ForEach(device.tabs, id: \.self) { tab in
                                Button(Self.menuTitle(tab.title.isEmpty ? tab.url.absoluteString : tab.title)) {
                                    browser?.open(tab.url, inNewTab: true)
                                }
                            }
                        }
                    }
                }
            }

            Divider()
            Button("Show All History") { browser?.isShowingHistory.toggle() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(browser?.history == nil)
            Button("Clear History and Website Data…") { browser?.isShowingClearData = true }
                .disabled(browser == nil)
        }
        CommandMenu("Bookmarks") {
            Button(bookmarks.isBookmarked(bookmarkableTab?.url) ? "Edit Bookmark…" : "Bookmark This Page…") {
                browser?.isEditingBookmark = true
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(bookmarkableTab == nil)
            Button("Manage Bookmarks") {
                openWindow(id: BrowserApp.bookmarksWindowID, value: profile.id)
            }
            .keyboardShortcut("b", modifiers: [.command, .option])

            if !bookmarks.root.isEmpty {
                Divider()
                BookmarkMenuItems(nodes: bookmarks.root, open: { browser?.open($0) },
                                  openAll: { browser?.openInNewTabs($0.map(\.url)) }, offersOpenAll: false)
            }
        }
        #if DEBUG
        CommandMenu("Develop") {
            Button("Show Web Inspector") { browser?.showWebInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(browser?.activeTab?.isNewTab != false)
        }
        #endif
    }

    /// Sends an editing action to the focused page or text field.
    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }

    private static func menuTitle(_ title: String) -> String {
        title.count > 60 ? String(title.prefix(59)) + "…" : title
    }
}
