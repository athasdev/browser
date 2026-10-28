import SwiftUI
import UIKit
import WebKit

@main
struct MobileApp: App {
    @State private var browser: MobileBrowser
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let directory = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Browser")
        let sync = CloudSync(directory: directory, deviceName: UIDevice.current.name, platform: platform)
        _browser = State(initialValue: MobileBrowser(sync: sync))
    }

    var body: some Scene {
        WindowGroup {
            BrowserScreen(browser: browser)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await browser.sync.syncNow() } }
                }
                .onOpenURL { url in
                    if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { browser.open(url, inNewTab: true) }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { browser.open(url, inNewTab: true) }
                }
        }
    }
}

/// The page, with Safari's compact bar at the bottom: the address, and back, forward, share, bookmarks, and tabs.
struct BrowserScreen: View {
    @Bindable var browser: MobileBrowser
    @State private var address = ""
    @State private var isShowingTabs = false
    @State private var isShowingBookmarks = false
    @State private var isShowingSettings = false
    @FocusState private var isEditingAddress: Bool

    var body: some View {
        let tab = browser.activeTab

        ZStack {
            if let tab, !tab.isNewTab {
                WebViewHost(tab: tab)
                    .id(tab.id)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                StartPage(browser: browser) { isShowingSettings = true }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar(for: tab)
        }
        .sheet(isPresented: $isShowingBookmarks) {
            BookmarksSheet(browser: browser)
        }
        .sheet(isPresented: $isShowingSettings) {
            MobileSettings(browser: browser)
        }
        .fullScreenCover(isPresented: $isShowingTabs) {
            TabOverview(browser: browser, isPresented: $isShowingTabs)
        }
        .userActivity(NSUserActivityTypeBrowsingWeb, element: handoffURL) { url, activity in
            activity.webpageURL = url
            activity.title = browser.activeTab?.displayTitle
            activity.isEligibleForHandoff = true
        }
        .onChange(of: browser.activeTabID) { _, _ in isEditingAddress = false }
    }

    private var handoffURL: URL? {
        guard let url = browser.activeTab?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }

    private func bottomBar(for tab: MobileTab?) -> some View {
        VStack(spacing: 8) {
            if let tab, tab.isLoading {
                ProgressView(value: tab.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 2)
            }
            addressField(for: tab)
                .padding(.horizontal, 12)
            if !isEditingAddress {
                HStack {
                    toolbarButton("chevron.backward", "Back", isEnabled: tab?.canGoBack == true) { tab?.goBack() }
                    toolbarButton("chevron.forward", "Forward", isEnabled: tab?.canGoForward == true) { tab?.goForward() }
                    if let url = tab?.url {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 36)
                        }
                    } else {
                        toolbarButton("square.and.arrow.up", "Share", isEnabled: false) {}
                    }
                    toolbarButton("book", "Bookmarks") { isShowingBookmarks = true }
                    toolbarButton("square.on.square", "Tabs") {
                        browser.activeTab?.captureSnapshot()
                        isShowingTabs = true
                    }
                    .overlay(alignment: .center) {
                        Text("\(browser.tabs.count)")
                            .font(.system(size: 9, weight: .bold))
                            .offset(x: 1.5, y: 2)
                            .allowsHitTesting(false)
                    }
                }
                .font(.system(size: 18))
                .padding(.horizontal, 8)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private func addressField(for tab: MobileTab?) -> some View {
        HStack(spacing: 6) {
            if !isEditingAddress {
                Image(systemName: tab?.isSecure == true ? "lock.fill" : "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            TextField("Search or enter website", text: $address)
                .focused($isEditingAddress)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .multilineTextAlignment(isEditingAddress ? .leading : .center)
                .onSubmit {
                    browser.navigate(to: address)
                    isEditingAddress = false
                }
            if isEditingAddress {
                Button("Cancel") { isEditingAddress = false }
                    .font(.system(size: 15))
            } else if let tab, !tab.isNewTab {
                Button {
                    if tab.isLoading { tab.stopLoading() } else { tab.reload() }
                } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: isEditingAddress) { _, isEditing in
            address = isEditing ? (tab?.url?.absoluteString ?? "") : displayAddress(for: tab)
        }
        .onChange(of: tab?.url) { _, _ in
            if !isEditingAddress { address = displayAddress(for: tab) }
        }
        .onAppear { address = displayAddress(for: tab) }
    }

    private func displayAddress(for tab: MobileTab?) -> String {
        tab?.url?.host().map(Bookmark.trimmedHost) ?? ""
    }

    private func toolbarButton(_ symbol: String, _ label: String, isEnabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(maxWidth: .infinity, minHeight: 36)
        }
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

/// Shows a tab's web view, making it the first time the tab shows.
struct WebViewHost: UIViewRepresentable {
    let tab: MobileTab

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        update(container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        update(container)
    }

    private func update(_ container: UIView) {
        let webView = tab.makeWebView()
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}
