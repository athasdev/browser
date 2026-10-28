import AppKit
import SwiftUI

struct NewTabView: View {
    let bookmarks: BookmarkStore
    let browser: BrowserModel
    let focusAddress: () -> Void
    @State private var contentWidth: CGFloat = 0
    @State private var prompt: BookmarkPrompt?
    @AppStorage(NewTabPage.storageKey) private var page = NewTabPage.startPage

    private let horizontalPadding: CGFloat = 32
    private let tileSpacing: CGFloat = 8

    /// Up to six favorites per row, fewer when the page is narrow, so the grid never forces the window wider.
    private var favoriteColumnCount: Int {
        let fitting = Int((contentWidth - horizontalPadding * 2 + tileSpacing) / (FavoriteTile.width + tileSpacing))
        return max(1, min(bookmarks.bookmarks.count, 6, fitting))
    }

    var body: some View {
        ZStack {
            NewTabBackground()

            if page == .startPage {
                startPage
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { contentWidth = $0 }
    }

    private var startPage: some View {
        ScrollView {
            VStack(spacing: 28) {
                if browser.isPrivate {
                    privateHeading
                } else {
                    TimelineView(.everyMinute) { context in
                        Text(Self.greeting(for: context.date))
                            .font(.system(size: 28, weight: .medium))
                            .tracking(-0.7)
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                }

                searchField

                favorites
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { height, _ in height }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var privateHeading: some View {
        VStack(spacing: 10) {
            Text("Private Browsing")
                .font(.system(size: 28, weight: .medium))
                .tracking(-0.7)
                .foregroundStyle(.primary.opacity(0.85))
            Text("Pages you visit in this window aren’t added to history, and their cookies and website data are "
                 + "removed when you close it. Downloads and bookmarks are kept.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    private var searchField: some View {
        Button(action: focusAddress) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Search")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.system(size: 15))
            .padding(.leading, 20)
            .padding(.trailing, 14)
            .frame(height: 52)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .frame(maxWidth: 560)
        .help("Search or enter an address (⌘L)")
        .accessibilityLabel("Focus address and search")
    }

    @ViewBuilder
    private var favorites: some View {
        Group {
            if bookmarks.bookmarks.isEmpty {
                Text("Bookmarks appear here")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                let columns = Array(repeating: GridItem(.fixed(FavoriteTile.width), spacing: tileSpacing),
                                    count: favoriteColumnCount)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(bookmarks.bookmarks.prefix(24)) { bookmark in
                        FavoriteTile(bookmark: bookmark) {
                            browser.open(bookmark.url,
                                         inNewTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
                        }
                        .contextMenu {
                            BookmarkMenu(bookmark: bookmark, bookmarks: bookmarks, browser: browser) { prompt = $0 }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 560)
        .fixedSize(horizontal: !bookmarks.bookmarks.isEmpty, vertical: false)
        .bookmarkPrompts($prompt, bookmarks: bookmarks)
    }

    static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Good night"
        }
    }
}

private struct FavoriteTile: View {
    let bookmark: Bookmark
    let open: () -> Void
    @State private var isHovered = false

    static let width: CGFloat = 88

    var body: some View {
        Button(action: open) {
            VStack(spacing: 8) {
                SiteIcon(url: bookmark.url, size: 30)
                    .frame(width: 64, height: 64)
                    .background(Color.primary.opacity(isHovered ? 0.1 : 0.06),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(isHovered ? 0.12 : 0), radius: 10, y: 4)
                    .scaleEffect(isHovered ? 1.04 : 1)
                Text(bookmark.displayTitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: Self.width - 4)
            }
            .frame(width: Self.width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(duration: 0.25, bounce: 0.3), value: isHovered)
        .help(bookmark.url.absoluteString)
    }
}

/// A soft, slowly drifting wash of color behind the new tab content.
private struct NewTabBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let drift = Float(sin(time / 9)) * 0.08
            let sway = Float(cos(time / 11)) * 0.08

            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5 + sway, 0], [1, 0],
                [0, 0.5 + drift], [0.5 + drift, 0.5 - sway], [1, 0.5 - drift],
                [0, 1], [0.5 - sway, 1], [1, 1],
            ], colors: colors)
            // Low enough that the window's translucent material shows through.
            .opacity(colorScheme == .dark ? 0.28 : 0.3)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var colors: [Color] {
        if colorScheme == .dark {
            [
                Color(red: 0.18, green: 0.30, blue: 0.36), Color(red: 0.12, green: 0.15, blue: 0.22), Color(red: 0.28, green: 0.22, blue: 0.40),
                Color(red: 0.12, green: 0.18, blue: 0.24), Color(red: 0.10, green: 0.11, blue: 0.14), Color(red: 0.20, green: 0.14, blue: 0.24),
                Color(red: 0.22, green: 0.16, blue: 0.26), Color(red: 0.12, green: 0.14, blue: 0.18), Color(red: 0.14, green: 0.26, blue: 0.30),
            ]
        } else {
            [
                Color(red: 0.78, green: 0.88, blue: 0.92), Color(red: 0.95, green: 0.95, blue: 0.97), Color(red: 0.88, green: 0.84, blue: 0.96),
                Color(red: 0.90, green: 0.94, blue: 0.96), Color(red: 1.00, green: 1.00, blue: 1.00), Color(red: 0.96, green: 0.89, blue: 0.92),
                Color(red: 0.94, green: 0.88, blue: 0.95), Color(red: 0.96, green: 0.96, blue: 0.98), Color(red: 0.82, green: 0.92, blue: 0.90),
            ]
        }
    }
}
