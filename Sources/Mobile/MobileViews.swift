import SwiftUI
import UIKit
import WebKit

/// A new tab: favorites from the bookmarks bar, and the tabs open on the user's other devices.
struct StartPage: View {
    let browser: MobileBrowser
    let openSettings: () -> Void

    var body: some View {
        let favorites = browser.bookmarks.root.compactMap(\.bookmark)

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Spacer()
                    Button(action: openSettings) {
                        Image(systemName: "gearshape").font(.system(size: 18))
                    }
                    .accessibilityLabel("Settings")
                }
                if !favorites.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Favorites").font(.title3.bold())
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 16)], spacing: 16) {
                            ForEach(favorites) { bookmark in
                                Button { browser.open(bookmark.url) } label: {
                                    VStack(spacing: 6) {
                                        SiteMonogram(url: bookmark.url, size: 56)
                                        Text(bookmark.displayTitle)
                                            .font(.caption)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .foregroundStyle(.primary)
                                    }
                                }
                            }
                        }
                    }
                }
                ForEach(browser.otherDevices) { device in
                    DeviceTabsSection(device: device) { browser.open($0) }
                }
                if favorites.isEmpty && browser.otherDevices.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "globe").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
                        Text("Search or enter a website below.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.immediately)
    }
}

struct DeviceTabsSection: View {
    let device: DeviceTabs
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(device.name, systemImage: device.symbolName).font(.title3.bold())
            VStack(spacing: 0) {
                ForEach(device.tabs, id: \.self) { tab in
                    Button { open(tab.url) } label: {
                        HStack(spacing: 12) {
                            SiteMonogram(url: tab.url, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tab.title.isEmpty ? tab.url.absoluteString : tab.title).lineLimit(1)
                                Text(tab.url.host().map(Bookmark.trimmedHost) ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    Divider()
                }
            }
        }
    }
}

/// A site's touch icon, or its initial on a color made from its name while there's none.
struct SiteMonogram: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        let host = url.host().map(Bookmark.trimmedHost) ?? "?"
        // Swift's hash changes every launch; the sum of the letters doesn't.
        let hue = Double(host.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360
        AsyncImage(url: URL(string: "https://\(url.host() ?? "")/apple-touch-icon.png")) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Text(String(host.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hue: hue, saturation: 0.45, brightness: 0.75))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// All tabs as cards, and the tabs open on other devices.
struct TabOverview: View {
    let browser: MobileBrowser
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(browser.tabs) { tab in
                        TabCard(tab: tab, isSelected: tab.id == browser.activeTabID) {
                            browser.activeTabID = tab.id
                            isPresented = false
                        } close: {
                            browser.close(tab)
                        }
                    }
                }
                .padding(16)
                ForEach(browser.otherDevices) { device in
                    DeviceTabsSection(device: device) { url in
                        browser.openTab(url: url)
                        isPresented = false
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(browser.tabs.count) Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Close All Tabs", role: .destructive) { browser.closeAllTabs() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        browser.openTab()
                        isPresented = false
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Tab")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }
}

private struct TabCard: View {
    let tab: MobileTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let snapshot = tab.snapshot {
                        Image(uiImage: snapshot).resizable().scaledToFill()
                    } else {
                        Color(.secondarySystemBackground)
                            .overlay {
                                if let url = tab.url { SiteMonogram(url: url, size: 44) }
                            }
                    }
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                      lineWidth: isSelected ? 3 : 1)
                }
                .onTapGesture(perform: select)

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .padding(7)
                        .background(.thinMaterial, in: Circle())
                }
                .padding(8)
                .accessibilityLabel("Close \(tab.displayTitle)")
            }
            Text(tab.displayTitle).font(.caption).lineLimit(1)
        }
    }
}

/// The selected profile's bookmarks, folder by folder, and adding the current page.
struct BookmarksSheet: View {
    let browser: MobileBrowser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BookmarkFolderList(browser: browser, folderID: nil, title: "Bookmarks") { url in
                browser.open(url)
                dismiss()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let tab = browser.activeTab, let url = tab.url {
                        let isBookmarked = browser.bookmarks.isBookmarked(url)
                        Button {
                            browser.bookmarks.toggle(title: tab.displayTitle, url: url)
                        } label: {
                            Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        }
                        .accessibilityLabel(isBookmarked ? "Remove Bookmark" : "Add Bookmark")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct BookmarkFolderList: View {
    let browser: MobileBrowser
    let folderID: UUID?
    let title: String
    let open: (URL) -> Void

    var body: some View {
        let nodes = browser.bookmarks.children(of: folderID)

        List {
            if nodes.isEmpty {
                Text(folderID == nil ? "Bookmarks you add here or on your Mac show up here." : "This folder is empty.")
                    .foregroundStyle(.secondary)
            }
            ForEach(nodes) { node in
                switch node {
                case .folder(let folder):
                    NavigationLink {
                        BookmarkFolderList(browser: browser, folderID: folder.id, title: folder.displayTitle,
                                           open: open)
                    } label: {
                        Label(folder.displayTitle, systemImage: "folder")
                    }
                case .bookmark(let bookmark):
                    Button { open(bookmark.url) } label: {
                        HStack(spacing: 12) {
                            SiteMonogram(url: bookmark.url, size: 28)
                            Text(bookmark.displayTitle).lineLimit(1)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .onDelete { offsets in
                for index in offsets { browser.bookmarks.remove(nodes[index].id) }
            }
        }
        .navigationTitle(title)
    }
}

/// Search engine, iCloud sync, which profile syncs, and website data.
struct MobileSettings: View {
    let browser: MobileBrowser
    @AppStorage(SearchEngine.storageKey) private var searchEngine = SearchEngine.google
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingClear = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Search Engine", selection: $searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
                }
                Section {
                    Toggle("Sync Bookmarks and Tabs", isOn: Binding(get: { browser.sync.isEnabled },
                                                                    set: { browser.sync.setEnabled($0) }))
                        .disabled(!browser.sync.isAvailable)
                    if browser.profileChoices.count > 1 {
                        Picker("Profile", selection: Binding(get: { browser.profileID },
                                                             set: { browser.selectProfile($0) })) {
                            ForEach(browser.profileChoices, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    }
                } header: {
                    Text("iCloud")
                } footer: {
                    Text(syncStatus)
                }
                Section {
                    Button("Clear History and Website Data", role: .destructive) { isConfirmingClear = true }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Clear history and website data?", isPresented: $isConfirmingClear,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    Task {
                        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                                      modifiedSince: .distantPast)
                        browser.closeAllTabs()
                    }
                }
            } message: {
                Text("You’ll be signed out of websites. Bookmarks stay.")
            }
        }
    }

    private var syncStatus: String {
        switch browser.sync.status {
        case .unavailable: "This build isn’t signed for iCloud."
        case .off: "Bookmarks and tabs stay on this device."
        case .syncing: "Syncing…"
        case .upToDate(let date): "Up to date, \(date.formatted(.relative(presentation: .named)))."
        case .failed(let message): "Couldn’t sync: \(message)"
        }
    }
}
