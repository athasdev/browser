import SwiftUI
import WebKit

private struct AddressBarFrameKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

struct BrowserWindow: View {
    let profiles: ProfileStore
    let session: SessionStore?
    /// Pages the window opens once it appears, such as a bookmark opened in a new window.
    private let initialURLs: [URL]
    @State private var browser: BrowserModel
    @State private var address = ""
    /// What the user typed, without the inline completion.
    @State private var typedAddress = ""
    @State private var completionStart: Int?
    @State private var suggestions: [AddressSuggestion] = []
    @State private var selectedSuggestion: Int?
    @State private var addressBlurRequest = 0
    @State private var hoverCardTabID: UUID?
    @State private var isFullScreen = false
    @State private var addressIsFocused = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(BookmarksBarVisibility.storageKey) private var bookmarksBarVisibility = BookmarksBarVisibility.always
    @AppStorage(TabLayout.storageKey) private var tabLayout = TabLayout.horizontal
    @AppStorage(TabLayout.hiddenStorageKey) private var tabsHidden = false

    private var bookmarks: BookmarkStore {
        browser.bookmarks
    }

    private var contentBlocker: ContentBlocker {
        browser.contentBlocker
    }

    /// The active page, when it's a web page another device's browser can open.
    private var handoffURL: URL? {
        guard let tab = browser.activeTab, !tab.isNewTab, tab.loadError == nil, let url = tab.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// The window's profile, or the one that opened a private window.
    private var profile: BrowserProfile {
        profiles.profile(for: browser) ?? profiles.defaultProfile
    }

    /// The profile's history and website data, which History ▸ Clear History and Website Data clears.
    private var browsingData: BrowsingData {
        profiles.data(for: profile.id).browsingData
    }

    private var accent: Color {
        browser.isPrivate ? Color(red: 0.58, green: 0.50, blue: 0.86) : profile.color.color
    }

    /// Opens in the requested profile, or else the profile of the saved window it's about to restore, or the default
    /// profile. A private window keeps its cookies and site data apart from other windows, and only until it closes;
    /// its request names the profile that opened it.
    init(profiles: ProfileStore, downloads: DownloadManager, session: SessionStore?,
         request: ProfileWindowRequest? = nil, isPrivate: Bool = false) {
        self.profiles = profiles
        self.session = isPrivate ? nil : session
        initialURLs = request?.urls ?? []
        let profileID = request?.profileID ?? (isPrivate ? nil : session?.nextPendingProfileID)
        let profile = profiles.data(for: profileID)
        _browser = State(initialValue: isPrivate ? .makePrivate(downloads: downloads, openedFrom: profile)
                                                 : BrowserModel(profile: profile, downloads: downloads))
    }

    var body: some View {
        // The main column keeps one identity across layouts, so switching layouts doesn't rebuild the page host.
        HStack(spacing: 0) {
            if tabLayout == .vertical && !tabsHidden {
                TabStrip(browser: browser, layout: .vertical, isFullScreen: isFullScreen,
                         hoverCardTabID: $hoverCardTabID)
                    .privateChrome(browser.isPrivate)
                    .frame(width: BrowserChrome.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                if tabLayout == .horizontal && !tabsHidden {
                    TabStrip(browser: browser, layout: .horizontal, isFullScreen: isFullScreen,
                             hoverCardTabID: $hoverCardTabID)
                        .privateChrome(browser.isPrivate)
                        .transition(.opacity)
                }
                mainColumn
            }
        }
        .overlayPreferenceValue(TabFrameKey.self) { tabFrames in
            hoverCard(tabFrames: tabFrames)
                .privateChrome(browser.isPrivate)
        }
        .overlayPreferenceValue(AddressBarFrameKey.self) { anchor in
            suggestionList(below: anchor)
                .privateChrome(browser.isPrivate)
        }
        .animation(.easeOut(duration: 0.18), value: bookmarksBarVisibility)
        .animation(.easeOut(duration: 0.18), value: browser.activeTab?.isNewTab)
        .animation(.snappy(duration: 0.25), value: tabLayout)
        .animation(.snappy(duration: 0.25), value: tabsHidden)
        .onChange(of: tabLayout) { _, _ in hoverCardTabID = nil }
        .onChange(of: tabsHidden) { _, _ in hoverCardTabID = nil }
        .background {
            WindowGlassBackground(isDark: browser.isPrivate)
            if browser.isPrivate {
                BrowserChrome.privateTint.ignoresSafeArea()
            } else if profiles.profiles.count > 1 {
                // Tells profiles' windows apart at a glance.
                profile.color.color.opacity(0.12).ignoresSafeArea()
            }
        }
        .background(WindowChromeConfigurator(titlebarHeight: tabsHidden ? BrowserChrome.navigationBarHeight
                                                                         : BrowserChrome.titlebarHeight(for: tabLayout),
                                             isFullScreen: $isFullScreen,
                                             onWindowChange: { [browser] in browser.window = $0 }) {
            session?.detach(browser)
            browser.extensions?.didCloseWindow(browser)
            browser.onTabsChange?()
        })
        .ignoresSafeArea(.container, edges: .top)
        .tint(accent)
        .focusedSceneValue(\.browserModel, browser)
        // Hands the page off to a nearby iPhone, iPad, or Mac. Private windows don't.
        .userActivity(NSUserActivityTypeBrowsingWeb, element: browser.isPrivate ? nil : handoffURL) { url, activity in
            activity.webpageURL = url
            activity.title = browser.activeTab?.pageTitle
            activity.isEligibleForHandoff = true
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL, ExternalURLRouter.canOpen(url) { browser.open(url, inNewTab: !browser.isBlank) }
        }
        .onChange(of: browser.activeTabID) { _, _ in
            address = browser.activeTab?.url?.absoluteString ?? ""
            closeSuggestions()
            browser.isEditingBookmark = false
        }
        .onChange(of: addressIsFocused) { _, isFocused in
            guard !isFocused else { return }
            // A click on a suggestion takes focus first, so the list stays a moment for the click to land.
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                if !addressIsFocused { closeSuggestions() }
            }
        }
        .sheet(isPresented: $browser.isShowingClearData) {
            ClearDataView(data: browsingData)
        }
        .sheet(isPresented: $browser.isShowingImport) {
            BrowserImportView(profiles: profiles, profileID: profile.id)
        }
        .sheet(isPresented: $browser.isShowingHistory) {
            if let history = browser.history {
                HistoryView(history: history) { url, inNewTab in
                    browser.isShowingHistory = false
                    browser.open(url, inNewTab: inNewTab)
                }
            }
        }
        .onAppear {
            profiles.register(browser)
            browser.extensions?.didOpenWindow(browser)
            if let session {
                for profileID in session.attach(browser) {
                    openWindow(id: BrowserApp.windowID,
                               value: ProfileWindowRequest(profileID: profileID ?? profiles.defaultProfileID))
                }
            }
            ExternalURLRouter.shared.register(browser, openWindow: openWindow)
            if !initialURLs.isEmpty {
                browser.openInNewTabs(initialURLs)
            }
            if browser.activeTab?.isNewTab == true {
                browser.requestAddressFocus()
            }
        }
    }

    @ViewBuilder
    private func suggestionList(below anchor: Anchor<CGRect>?) -> some View {
        if let anchor, !suggestions.isEmpty {
            GeometryReader { geometry in
                let frame = geometry[anchor]
                AddressSuggestionList(suggestions: suggestions, selectedIndex: selectedSuggestion) { suggestion in
                    open(suggestion)
                }
                .frame(width: frame.width)
                .offset(x: frame.minX, y: frame.maxY + 4)
            }
            .transition(.opacity)
        }
    }

    // MARK: Address bar

    private func editAddress(_ text: String) {
        // Typing more of the text completes it again; deleting doesn't, so the deleted completion stays gone.
        let isAppending = text.count > typedAddress.count && text.hasPrefix(typedAddress)
        typedAddress = text
        selectedSuggestion = nil
        suggestions = AddressSuggestions.rank(text, pages: browser.history?.pages ?? [],
                                              bookmarks: bookmarks.bookmarks)
        if isAppending, let completion = AddressSuggestions.inlineCompletion(of: text, with: suggestions.first) {
            completionStart = (text as NSString).length
            address = completion
        } else {
            completionStart = nil
        }
    }

    private func performAddressCommand(_ command: AddressField.Command) -> Bool {
        switch command {
        case .moveDown, .moveUp:
            guard !suggestions.isEmpty else { return false }
            let offset = command == .moveDown ? 1 : -1
            let index = (selectedSuggestion ?? -1) + offset
            completionStart = nil
            if index < 0 {
                selectedSuggestion = nil
                address = typedAddress
            } else {
                selectedSuggestion = min(index, suggestions.count - 1)
                address = suggestions[min(index, suggestions.count - 1)].url.absoluteString
            }
            return true
        case .submit:
            if let selectedSuggestion, suggestions.indices.contains(selectedSuggestion) {
                open(suggestions[selectedSuggestion])
            } else {
                browser.navigate(to: address)
                finishEditingAddress()
            }
            return true
        case .cancel:
            if suggestions.isEmpty {
                address = browser.activeTab?.url?.absoluteString ?? ""
                typedAddress = address
            } else {
                address = typedAddress
                closeSuggestions()
            }
            completionStart = nil
            return true
        }
    }

    private func open(_ suggestion: AddressSuggestion) {
        // The list can report a click more than once before it closes.
        guard !suggestions.isEmpty else { return }
        address = suggestion.url.absoluteString
        browser.open(suggestion.url)
        finishEditingAddress()
    }

    private func finishEditingAddress() {
        closeSuggestions()
        completionStart = nil
        addressBlurRequest += 1
    }

    private func closeSuggestions() {
        suggestions = []
        selectedSuggestion = nil
        typedAddress = ""
    }

    /// Navigation, bookmarks, and the page. In the vertical layout the sidebar supplies the leading inset.
    /// With the tabs hidden, the navigation bar is the top row and makes room for the window controls.
    private var mainColumn: some View {
        let leadingInset = tabLayout == .vertical && !tabsHidden ? 0 : BrowserChrome.edgeInset
        let navigationLeading = tabsHidden && !isFullScreen
            ? BrowserChrome.windowButtonsTrailing(titlebarHeight: BrowserChrome.navigationBarHeight) + 8
            : leadingInset

        return VStack(spacing: 0) {
            navigationBar
                .padding(.leading, navigationLeading)
                .privateChrome(browser.isPrivate)

            if bookmarksBarVisibility.isVisible(onNewTab: browser.activeTab?.isNewTab ?? true) {
                BookmarksBar(bookmarks: bookmarks, browser: browser)
                    .padding(.leading, leadingInset - BrowserChrome.edgeInset)
                    .padding(.bottom, 4)
                    .privateChrome(browser.isPrivate)
                    .transition(.opacity)
            }

            if let tab = browser.activeTab {
                Group {
                    if tab.isNewTab {
                        NewTabView(bookmarks: bookmarks, browser: browser) { browser.requestAddressFocus() }
                            .privateChrome(browser.isPrivate)
                    } else {
                        webView(for: tab)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .padding(.leading, leadingInset)
                .padding([.trailing, .bottom], BrowserChrome.edgeInset)
            }
        }
    }

    private func hoverCard(tabFrames: [UUID: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            if let tab = browser.tab(withID: hoverCardTabID), let anchor = tabFrames[tab.id] {
                let tabFrame = geometry[anchor]
                let position = tabLayout == .vertical
                    // Beside the sidebar row, kept clear of the window's bottom edge.
                    ? CGPoint(x: tabFrame.maxX + 10,
                              y: max(BrowserChrome.edgeInset, min(tabFrame.minY - 4, geometry.size.height - 250)))
                    : CGPoint(x: min(max(tabFrame.minX, BrowserChrome.edgeInset),
                                     geometry.size.width - TabHoverCard.width - BrowserChrome.edgeInset),
                              y: tabFrame.maxY + 6)
                TabHoverCard(tab: tab, isActive: tab.id == browser.activeTabID)
                    .offset(x: position.x, y: position.y)
                    .transition(tabLayout == .vertical ? .opacity.combined(with: .offset(x: -3))
                                                       : .opacity.combined(with: .offset(y: -3)))
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.14), value: hoverCardTabID)
    }

    private func webView(for tab: BrowserTab) -> some View {
        PageHost(content: tab.contentView)
            .overlay {
                if let error = tab.loadError {
                    PageErrorView(error: error, isLoading: tab.isLoading,
                                  otherBrowser: error.kind == .crashed ? OtherBrowsers.installed().first : nil) {
                        tab.retry()
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if tab.isFindBarVisible {
                    FindBar(tab: tab, browser: browser)
                        .padding(10)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: tab.isFindBarVisible)
            .overlay(alignment: .topLeading) {
                if tab.isLoading {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(accent.opacity(0.5))
                            .frame(width: max(18, geometry.size.width * tab.estimatedProgress),
                                   height: 2)
                    }
                    .frame(height: 2)
                    .padding(.horizontal, 12)
                    .padding(.top, 3)
                    .animation(.easeOut(duration: 0.18), value: tab.estimatedProgress)
                }
            }
            .onChange(of: tab.url) { _, url in
                if !addressIsFocused { address = url?.absoluteString ?? "" }
            }
            .onAppear {
                if !addressIsFocused { address = tab.url?.absoluteString ?? "" }
            }
    }

    private var navigationBar: some View {
        let tab = browser.activeTab
        let isLoading = tab?.isLoading == true

        return HStack(spacing: 6) {
            HStack(spacing: 0) {
                Button { browser.goBack() } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!(tab?.canNavigateBack ?? false))
                .help("Back (⌘[)")
                .contextMenu {
                    historyMenu(for: Array((tab?.backList ?? []).reversed()))
                }

                Button { browser.goForward() } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!(tab?.canGoForward ?? false))
                .help("Forward (⌘])")
                .contextMenu {
                    historyMenu(for: tab?.forwardList ?? [])
                }

                Button {
                    if isLoading { browser.stopLoading() } else { browser.reload() }
                } label: {
                    Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                        .contentTransition(.symbolEffect(.replace))
                }
                .disabled(tab?.isNewTab ?? true)
                .help(isLoading ? "Stop Loading" : "Reload (⌘R)")
            }
            .buttonStyle(ChromeIconButtonStyle(size: 30))
            .padding(2)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if browser.isPrivate {
                privateLabel
            } else {
                ProfileMenu(profiles: profiles, current: profile)
            }

            HStack(spacing: 7) {
                Image(systemName: browser.activeTab?.isSecure == true ? "lock.fill" : "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                AddressField(text: $address, isFocused: $addressIsFocused, completionStart: completionStart,
                             focusRequest: browser.addressFocusRequest, blurRequest: addressBlurRequest,
                             edit: editAddress, perform: performAddressCommand)
                zoomButton
                compatibilityButton
                chromeWebStoreButton
                passwordButton
                trackerBlockingButton
                bookmarkButton
            }
            .padding(.leading, 11)
            .padding(.trailing, 4)
            .frame(height: 34)
            .background(Color.primary.opacity(0.065),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(addressIsFocused ? accent.opacity(0.7) : Color.clear, lineWidth: 1)
            }
            .anchorPreference(key: AddressBarFrameKey.self, value: .bounds) { $0 }

            if let extensions = browser.extensions, !extensions.installed.isEmpty {
                ExtensionToolbar(store: extensions, browser: browser)
            }

            if !browser.downloads.items.isEmpty {
                DownloadsButton(downloads: browser.downloads)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.trailing, BrowserChrome.edgeInset)
        .frame(height: BrowserChrome.navigationBarHeight)
        .animation(.snappy(duration: 0.2), value: browser.downloads.items.isEmpty)
    }

    /// Shows that the page's site is told it's in another browser, and changes or resets that.
    @ViewBuilder
    private var compatibilityButton: some View {
        if let tab = browser.activeTab, !tab.isNewTab, case let identity = browser.compatibility.identity(for: tab.url),
           identity != .safari {
            Menu {
                ForEach(BrowserIdentity.allCases) { option in
                    Button {
                        browser.compatibility.setIdentity(option, for: tab.url)
                        browser.reloadTab(tab.id)
                    } label: {
                        if option == identity { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                    }
                }
            } label: {
                Text(identity.shortTitle)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .disabled(browser.isPrivate)
            .help("This site is told it’s in \(identity.shortTitle)")
        }
    }

    /// On a Chrome Web Store page, offers to add the extension it shows.
    @ViewBuilder
    private var chromeWebStoreButton: some View {
        if let extensions = browser.extensions, let storeID = ChromeWebStore.extensionID(from: browser.activeTab?.url) {
            ChromeWebStoreButton(store: extensions, storeID: storeID, window: browser.window)
        }
    }

    @ViewBuilder
    private var zoomButton: some View {
        if let tab = browser.activeTab, !tab.isNewTab, tab.pageZoom != 1 {
            Button { browser.resetZoom() } label: {
                Text(tab.pageZoom, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reset Zoom (⌘0)")
            .accessibilityLabel("Zoom \(Int((tab.pageZoom * 100).rounded())) percent, reset")
        }
    }

    /// Names the profile that opened the window once there's more than one, though the window belongs to none.
    private var privateLabel: some View {
        let opener = browser.openerProfileID != nil && profiles.profiles.count > 1 ? profile.displayName : nil

        return Label(opener.map { "Private · \($0)" } ?? "Private", systemImage: "eyeglasses")
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .help(opener.map { "Private Window, opened from \($0): history, cookies, and website data aren’t kept "
                                + "after it closes" }
                  ?? "Private Window: history, cookies, and website data aren’t kept after it closes")
            .accessibilityLabel(opener.map { "Private Window, opened from \($0)" } ?? "Private Window")
    }

    /// Shows whether trackers are blocked on the page's site, and turns blocking off for the site. A private window
    /// shows the state without changing it, since the change would be kept after it closes.
    @ViewBuilder
    private var trackerBlockingButton: some View {
        if contentBlocker.isEnabled, let tab = browser.activeTab, !tab.isNewTab, let host = tab.host,
           ["http", "https"].contains(tab.url?.scheme?.lowercased() ?? "") {
            let isBlocking = contentBlocker.isBlocking(on: host)
            let site = ContentBlocker.site(host)
            Menu {
                Text(isBlocking ? "Trackers are blocked on \(site)" : "Tracker blocking is off for \(site)")
                Button(isBlocking ? "Turn Off Blocking for This Site" : "Turn On Blocking for This Site") {
                    Task {
                        await contentBlocker.setBlocking(!isBlocking, on: host)
                        tab.reload()
                    }
                }
                .disabled(browser.isPrivate)
            } label: {
                Image(systemName: isBlocking ? "shield.lefthalf.filled" : "shield.slash")
                    .foregroundStyle(isBlocking ? Color.secondary : Color.orange)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(ChromeIconButtonStyle(size: 26))
            .fixedSize()
            .help(isBlocking ? "Trackers Blocked" : "Tracker Blocking Off for This Site")
            .accessibilityLabel(isBlocking ? "Trackers blocked" : "Tracker blocking off")
        }
    }

    /// Offers the passwords saved for exactly the page's origin, once the page shows a password field.
    @ViewBuilder
    private var passwordButton: some View {
        if let tab = browser.activeTab, !tab.isNewTab, tab.hasPasswordFields, let passwords = browser.passwords {
            let accounts = passwords.passwords(for: PasswordOrigin(url: tab.url))
            if !accounts.isEmpty {
                Menu {
                    ForEach(accounts) { account in
                        Button(account.username.isEmpty ? "Fill Password" : "Fill “\(account.username)”") {
                            Task { await PasswordAutofill.fill(account, in: tab, from: passwords) }
                        }
                    }
                    Divider()
                    Button("Show Passwords…") { openSettings() }
                } label: {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(ChromeIconButtonStyle(size: 26))
                .fixedSize()
                .help("Fill Saved Password")
                .accessibilityLabel("Fill saved password")
            }
        }
    }

    @ViewBuilder
    private var bookmarkButton: some View {
        if let tab = browser.activeTab, !tab.isNewTab, let url = tab.url {
            let isBookmarked = bookmarks.isBookmarked(url)
            Button { browser.isEditingBookmark = true } label: {
                Image(systemName: isBookmarked ? "star.fill" : "star")
                    .foregroundStyle(isBookmarked ? Color.yellow : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(ChromeIconButtonStyle(size: 26))
            .help(isBookmarked ? "Edit Bookmark (⌘D)" : "Bookmark This Page (⌘D)")
            .accessibilityLabel(isBookmarked ? "Edit Bookmark" : "Bookmark This Page")
            .popover(isPresented: $browser.isEditingBookmark, arrowEdge: .bottom) {
                BookmarkEditor(bookmarks: bookmarks, title: tab.pageTitle, url: url) {
                    browser.isEditingBookmark = false
                }
            }
        }
    }

    @ViewBuilder
    private func historyMenu(for items: [WKBackForwardListItem]) -> some View {
        ForEach(items.prefix(15), id: \.self) { item in
            Button(item.title.flatMap { $0.isEmpty ? nil : $0 } ?? item.url.absoluteString) {
                browser.go(to: item)
            }
        }
    }
}
