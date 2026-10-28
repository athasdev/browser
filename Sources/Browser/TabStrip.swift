import AppKit
import SwiftUI

struct TabFrameKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct TabStrip: View {
    let browser: BrowserModel
    let layout: TabLayout
    let isFullScreen: Bool
    @Binding var hoverCardTabID: UUID?
    @AppStorage(TabLayout.storageKey) private var tabLayout = TabLayout.horizontal

    @State private var hoveredTabID: UUID?
    @State private var suppressedHoverCardTabID: UUID?
    @State private var draggedTabID: UUID?

    private let spacing: CGFloat = 4
    private let maxTabWidth: CGFloat = 220
    private let minTabWidth: CGFloat = 56
    private let newTabButtonSize: CGFloat = 28
    private let pinnedTabWidth: CGFloat = 40
    /// Always leave some empty strip to drag the window by.
    private let minDragAreaWidth: CGFloat = 40

    var body: some View {
        Group {
            switch layout {
            case .horizontal: horizontalStrip
            case .vertical: sidebar
            }
        }
        .task(id: hoveredTabID) { await updateHoverCard() }
        .task(id: draggedTabID) { await forgetDraggedTabWhenDropped() }
    }

    /// The tabs with their places in the window, pinned ones first.
    private var pinnedTabs: [(offset: Int, element: BrowserTab)] {
        Array(browser.tabs.enumerated().prefix { $0.element.isPinned })
    }

    private var unpinnedTabs: [(offset: Int, element: BrowserTab)] {
        Array(browser.tabs.enumerated().dropFirst(browser.pinnedCount))
    }

    /// Without pinned tabs there's no pinned area to drag a tab into, so one appears while a tab is dragged.
    private var showsPinDropZone: Bool {
        browser.pinnedCount == 0 && browser.tab(withID: draggedTabID) != nil
    }

    /// SwiftUI doesn't say when a drag ends without a drop, so the dragged tab is forgotten once the mouse is up.
    private func forgetDraggedTabWhenDropped() async {
        guard draggedTabID != nil else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            if NSEvent.pressedMouseButtons & 1 == 0 {
                draggedTabID = nil
                return
            }
        }
    }

    private func pinDropZone(width: CGFloat?, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Label(width == nil ? "Drop Here to Pin" : "Pin", systemImage: "pin")
            .labelStyle(PinDropLabelStyle(showsTitle: width == nil))
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .overlay { shape.strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
            .contentShape(shape)
            .onDrop(of: [.text], delegate: PinDropDelegate(browser: browser, draggedTabID: $draggedTabID))
            .transition(.opacity)
    }

    private var horizontalStrip: some View {
        GeometryReader { geometry in
            let leading = isFullScreen ? BrowserChrome.edgeInset
                : BrowserChrome.windowButtonsTrailing(titlebarHeight: BrowserChrome.tabRowHeight) + 12
            let pinned = pinnedTabs
            let unpinned = unpinnedTabs
            let pinnedAreaWidth = CGFloat(pinned.count) * (pinnedTabWidth + spacing)
                + (showsPinDropZone ? pinnedTabWidth + spacing : 0)
            let count = CGFloat(max(unpinned.count, 1))
            let availableWidth = max(minTabWidth, geometry.size.width - leading - BrowserChrome.edgeInset
                                     - newTabButtonSize - spacing - minDragAreaWidth - pinnedAreaWidth)
            let tabWidth = min(maxTabWidth,
                               max(minTabWidth, ((availableWidth - spacing * (count - 1)) / count).rounded(.down)))
            let tabsWidth = unpinned.isEmpty ? 0 : tabWidth * count + spacing * (count - 1)

            HStack(spacing: spacing) {
                // Pinned tabs stay in view while the others scroll.
                ForEach(pinned, id: \.element.id) { index, tab in
                    tabItem(for: tab, at: index, width: pinnedTabWidth)
                }
                if showsPinDropZone {
                    pinDropZone(width: pinnedTabWidth, height: BrowserChrome.tabHeight)
                }

                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: spacing) {
                            ForEach(unpinned, id: \.element.id) { index, tab in
                                tabItem(for: tab, at: index, width: tabWidth)
                                    .id(tab.id)
                            }
                        }
                        .frame(height: BrowserChrome.tabRowHeight)
                    }
                    .scrollIndicators(.never)
                    .scrollDisabled(tabsWidth <= availableWidth)
                    .onChange(of: browser.activeTabID) { _, activeTabID in
                        guard let activeTabID, browser.tab(withID: activeTabID)?.isPinned == false else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            scrollProxy.scrollTo(activeTabID)
                        }
                    }
                }
                .frame(width: min(tabsWidth, availableWidth))

                Button { browser.addTab() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(ChromeIconButtonStyle(size: newTabButtonSize))
                .help("New Tab (⌘T)")
                .accessibilityLabel("New Tab")

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                    .contextMenu { stripMenu }
            }
            .padding(.leading, leading)
            .padding(.trailing, BrowserChrome.edgeInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .animation(.snappy(duration: 0.22), value: browser.tabs.map(\.id))
            .animation(.snappy(duration: 0.22), value: browser.pinnedCount)
            .animation(.snappy(duration: 0.22), value: tabWidth)
            .animation(.easeOut(duration: 0.15), value: showsPinDropZone)
        }
        .frame(height: BrowserChrome.tabRowHeight)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                    .contextMenu { stripMenu }
                Button { tabLayout = .horizontal } label: {
                    Image(systemName: "rectangle.topthird.inset.filled")
                }
                .buttonStyle(ChromeIconButtonStyle(size: 28))
                .help("Use Horizontal Tabs (⇧⌘S)")
                .accessibilityLabel("Use Horizontal Tabs")
                Button { browser.addTab() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(ChromeIconButtonStyle(size: 28))
                .help("New Tab (⌘T)")
                .accessibilityLabel("New Tab")
            }
            .padding(.leading, isFullScreen ? BrowserChrome.edgeInset
                     : BrowserChrome.windowButtonsTrailing(titlebarHeight: BrowserChrome.navigationBarHeight) + 8)
            .padding(.trailing, BrowserChrome.edgeInset)
            .frame(height: BrowserChrome.navigationBarHeight)

            let pinned = pinnedTabs
            if !pinned.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
                    ForEach(pinned, id: \.element.id) { index, tab in
                        tabItem(for: tab, at: index, width: nil)
                    }
                }
                .padding(.horizontal, BrowserChrome.edgeInset)
                .padding(.vertical, 4)
                Divider()
                    .padding(.horizontal, BrowserChrome.edgeInset + 4)
                    .padding(.vertical, 4)
            } else if showsPinDropZone {
                pinDropZone(width: nil, height: BrowserChrome.sidebarTabHeight + 2)
                    .padding(.horizontal, BrowserChrome.edgeInset)
                    .padding(.vertical, 4)
            }

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(unpinnedTabs, id: \.element.id) { index, tab in
                            tabItem(for: tab, at: index, width: nil)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, BrowserChrome.edgeInset)
                    .padding(.top, 2)
                    .padding(.bottom, BrowserChrome.edgeInset)
                }
                .scrollIndicators(.never)
                .onChange(of: browser.activeTabID) { _, activeTabID in
                    guard let activeTabID, browser.tab(withID: activeTabID)?.isPinned == false else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollProxy.scrollTo(activeTabID)
                    }
                }
            }
            .contextMenu { stripMenu }
        }
        .animation(.snappy(duration: 0.22), value: browser.tabs.map(\.id))
        .animation(.snappy(duration: 0.22), value: browser.pinnedCount)
        .animation(.easeOut(duration: 0.15), value: showsPinDropZone)
    }

    private func tabItem(for tab: BrowserTab, at index: Int, width: CGFloat?) -> some View {
        let isActive = browser.activeTabID == tab.id
        let isHovered = hoveredTabID == tab.id
        let nextTab = browser.tabs.indices.contains(index + 1) ? browser.tabs[index + 1] : nil
        let showsSeparator = layout == .horizontal && nextTab.map { next in
            !isActive && !isHovered && browser.activeTabID != next.id && hoveredTabID != next.id
        } ?? false

        return TabItem(tab: tab,
                       isActive: isActive,
                       isHovered: isHovered,
                       width: width,
                       height: layout == .vertical ? (tab.isPinned ? 34 : BrowserChrome.sidebarTabHeight)
                                                   : BrowserChrome.tabHeight,
                       select: {
                           suppressedHoverCardTabID = tab.id
                           hoverCardTabID = nil
                           browser.activeTabID = tab.id
                       },
                       close: {
                           hoverCardTabID = nil
                           browser.closeTab(tab.id)
                       })
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 14)
                    .offset(x: (spacing + 1) / 2)
                    .opacity(showsSeparator ? 1 : 0)
            }
            .anchorPreference(key: TabFrameKey.self, value: .bounds) { [tab.id: $0] }
            .onHover { isHovering in
                if isHovering {
                    hoveredTabID = tab.id
                } else if hoveredTabID == tab.id {
                    hoveredTabID = nil
                }
            }
            .onDrag {
                draggedTabID = tab.id
                hoverCardTabID = nil
                suppressedHoverCardTabID = tab.id
                return NSItemProvider(object: tab.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: TabDropDelegate(targetTabID: tab.id,
                                                           browser: browser,
                                                           draggedTabID: $draggedTabID))
            .contextMenu { tabMenu(for: tab, at: index) }
    }

    /// Shows the card after a short delay, then follows the pointer between tabs without waiting again.
    private func updateHoverCard() async {
        guard let hoveredTabID else {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            hoverCardTabID = nil
            suppressedHoverCardTabID = nil
            return
        }
        guard hoveredTabID != suppressedHoverCardTabID else { return }
        if hoverCardTabID != nil {
            hoverCardTabID = hoveredTabID
            return
        }
        try? await Task.sleep(for: .milliseconds(550))
        guard !Task.isCancelled else { return }
        hoverCardTabID = hoveredTabID
    }

    @ViewBuilder
    private func tabMenu(for tab: BrowserTab, at index: Int) -> some View {
        Button("New Tab") { browser.addTab() }
        Divider()
        Button("Reload") { browser.reloadTab(tab.id) }
            .disabled(tab.isNewTab)
        Button("Duplicate") { browser.duplicateTab(tab.id) }
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { browser.setPinned(!tab.isPinned, for: tab.id) }
        Button("Copy Link") {
            guard let url = tab.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        .disabled(tab.url == nil)
        Divider()
        Button("Close Tab") { browser.closeTab(tab.id) }
        Button("Close Other Tabs") { browser.closeOtherTabs(than: tab.id) }
            .disabled(!browser.canCloseOtherTabs(than: tab.id))
        Button("Close Tabs to the Right") { browser.closeTabs(after: tab.id) }
            .disabled(!browser.tabs.dropFirst(index + 1).contains { !$0.isPinned })
        Divider()
        Button("Reopen Closed Tab") { browser.reopenClosedTab() }
            .disabled(!browser.canReopenClosedTab)
        layoutToggle
    }

    @ViewBuilder
    private var stripMenu: some View {
        Button("New Tab") { browser.addTab() }
        Button("Reopen Closed Tab") { browser.reopenClosedTab() }
            .disabled(!browser.canReopenClosedTab)
        layoutToggle
    }

    @ViewBuilder
    private var layoutToggle: some View {
        Divider()
        Button(layout == .vertical ? "Use Horizontal Tabs" : "Use Vertical Tabs") {
            tabLayout = layout.toggled
        }
    }
}

private struct TabItem: View {
    let tab: BrowserTab
    let isActive: Bool
    let isHovered: Bool
    /// A fixed width in the tab strip, or `nil` to fill the sidebar.
    let width: CGFloat?
    let height: CGFloat
    let select: () -> Void
    let close: () -> Void

    private var isCompact: Bool { (width ?? .infinity) < 100 }
    /// Narrow tabs keep their icon visible and only swap in the close button while hovered.
    private var showsCloseButton: Bool { isHovered || (isActive && !isCompact) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        content
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background {
            shape.fill(isActive ? Color.primary.opacity(0.11) :
                       isHovered ? Color.primary.opacity(0.055) : Color.clear)
                .shadow(color: .black.opacity(isActive ? 0.08 : 0), radius: 1, y: 0.5)
        }
        .overlay {
            shape.strokeBorder(Color.primary.opacity(isActive ? 0.07 : 0), lineWidth: 1)
        }
        .contentShape(shape)
        .onTapGesture(perform: select)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .contain)
    }

    /// A pinned tab shows only its icon, which it keeps while suspended, and closes with ⌘W.
    @ViewBuilder
    private var content: some View {
        if tab.isPinned {
            TabIcon(tab: tab, isActive: isActive)
                .accessibilityElement()
                .accessibilityLabel("Pinned Tab: \(tab.title)")
                .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(.default, select)
                .help(tab.title)
        } else {
            HStack(spacing: 7) {
                if !(isCompact && showsCloseButton) {
                    TabIcon(tab: tab, isActive: isActive)
                        .opacity(tab.isSuspended ? 0.5 : 1)
                }
                if !isCompact {
                    title
                }
                if showsCloseButton || !isCompact {
                    closeButton
                        .opacity(showsCloseButton ? 1 : 0)
                        .allowsHitTesting(showsCloseButton)
                }
            }
            .padding(.leading, isCompact ? 0 : 10)
            .padding(.trailing, isCompact ? 0 : 4)
        }
    }

    private var title: some View {
        // The title lives in an overlay so its natural width never widens the tab.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Text(tab.title)
                    .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
                    .tracking(-0.1)
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            // Fade long titles instead of truncating them with an ellipsis.
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                }
            }
            .clipped()
            .accessibilityElement()
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChromeCloseButtonStyle())
        .help("Close Tab (⌘W)")
        .accessibilityLabel("Close \(tab.title)")
    }
}

private struct TabIcon: View {
    let tab: BrowserTab
    let isActive: Bool

    var body: some View {
        Group {
            if tab.isLoading && !tab.isNewTab {
                ProgressView()
                    .controlSize(.mini)
            } else if let favicon = tab.favicon {
                favicon
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.light)
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
            }
        }
        .frame(width: 14, height: 14)
    }
}

struct TabHoverCard: View {
    let tab: BrowserTab
    let isActive: Bool

    static let width: CGFloat = 280

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            if !isActive, !tab.isNewTab, let thumbnail = tab.thumbnail {
                thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.width, height: 156, alignment: .top)
                    .clipped()
                Divider()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(tab.title)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.1)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    if tab.isSecure {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    Text(subtitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private var subtitle: String {
        if tab.isNewTab { return "Start page" }
        let host = tab.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            ?? tab.url?.absoluteString ?? ""
        return tab.isLoading ? "\(host) · Loading…" : host
    }
}

private struct TabDropDelegate: DropDelegate {
    let targetTabID: UUID
    let browser: BrowserModel
    @Binding var draggedTabID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggedTabID, draggedTabID != targetTabID,
              let destinationIndex = browser.tabs.firstIndex(where: { $0.id == targetTabID }) else { return }
        withAnimation(.snappy(duration: 0.2)) {
            browser.moveTab(draggedTabID, to: destinationIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTabID = nil
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedTabID != nil
    }
}

/// Pins the dragged tab when it's dropped where the pinned tabs go.
private struct PinDropDelegate: DropDelegate {
    let browser: BrowserModel
    @Binding var draggedTabID: UUID?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedTabID else { return false }
        withAnimation(.snappy(duration: 0.2)) {
            browser.setPinned(true, for: draggedTabID)
        }
        self.draggedTabID = nil
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedTabID != nil
    }
}

private struct PinDropLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            if showsTitle { configuration.title }
        }
    }
}

struct ChromeIconButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.5))
            .frame(width: size, height: size)
            .background(!isEnabled ? Color.clear :
                        configuration.isPressed ? Color.primary.opacity(0.12) :
                        isHovered ? Color.primary.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: size <= 28 ? 8 : 10, style: .continuous))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

struct ChromeCloseButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .background(configuration.isPressed ? Color.primary.opacity(0.14) :
                        isHovered ? Color.primary.opacity(0.09) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { isHovered = $0 }
    }
}
