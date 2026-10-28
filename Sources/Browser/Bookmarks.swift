import AppKit
import Foundation
import SwiftUI

enum BookmarksBarVisibility: String, CaseIterable, Identifiable {
    case always
    case newTabOnly
    case never

    static let storageKey = "bookmarksBarVisibility"

    var id: Self { self }

    var title: String {
        switch self {
        case .always: "Always Show"
        case .newTabOnly: "Show Only on New Tabs"
        case .never: "Never Show"
        }
    }

    /// For the bookmarks bar's Show Bookmarks Bar menu.
    var shortTitle: String {
        switch self {
        case .always: "Always"
        case .newTabOnly: "Only on New Tabs"
        case .never: "Never"
        }
    }

    func isVisible(onNewTab isNewTab: Bool) -> Bool {
        switch self {
        case .always: true
        case .newTabOnly: isNewTab
        case .never: false
        }
    }
}

/// A site icon, falling back to a colored monogram while it loads or when the site has none.
struct SiteIcon: View {
    let url: URL
    var size: CGFloat = 16
    @State private var icon: Image?

    var body: some View {
        Group {
            if let icon = icon ?? FaviconStore.cachedIcon(for: url) {
                icon
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { icon = await FaviconStore.icon(for: url) }
    }

    private var monogram: some View {
        let host = url.host().map(Bookmark.trimmedHost) ?? "?"
        let hue = Double(host.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360

        return RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color(hue: hue, saturation: 0.35, brightness: 0.62).gradient)
            .overlay {
                Text(host.prefix(1).uppercased())
                    .font(.system(size: size * 0.56, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }
}
