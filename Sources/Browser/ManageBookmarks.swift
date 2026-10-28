import AppKit
import SwiftUI

/// Where Manage Bookmarks opens a bookmark.
enum BookmarkOpenTarget {
    case newTab
    case newWindow
    case privateWindow
}

/// A profile's bookmarks and folders in an outline, where they can be searched, dragged to reorder or move,
/// renamed, and deleted.
struct ManageBookmarksWindow: View {
    let profiles: ProfileStore
    let profileID: UUID
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var selection: [UUID] = []
    @State private var prompt: BookmarkPrompt?

    private var bookmarks: BookmarkStore {
        profiles.data(for: profileID).bookmarks
    }

    private var title: String {
        guard profiles.profiles.count > 1, let profile = profiles.profile(withID: profileID) else { return "Bookmarks" }
        return "Bookmarks — \(profile.displayName)"
    }

    var body: some View {
        BookmarkOutline(nodes: bookmarks.root, query: query, bookmarks: bookmarks, selection: $selection,
                        open: open, delete: delete, newFolder: { prompt = .newFolder(parentID: $0) })
            .overlay {
                if bookmarks.root.isEmpty {
                    ContentUnavailableView("No Bookmarks", systemImage: "star",
                                           description: Text("Bookmark pages with ⌘D or the star in the address bar."))
                }
            }
            .searchable(text: $query, placement: .toolbar, prompt: "Search Bookmarks")
            .toolbar {
                ToolbarItemGroup {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        prompt = .newFolder(parentID: newFolderParentID)
                    }
                    .help("New Folder")
                    Button("Delete", systemImage: "trash") { delete(selection) }
                        .disabled(selection.isEmpty)
                        .help("Delete")
                }
            }
            .navigationTitle(title)
            .bookmarkPrompts($prompt, bookmarks: bookmarks)
            .frame(minWidth: 520, minHeight: 320)
    }

    /// Inside the selected folder, or next to the selected bookmark.
    private var newFolderParentID: UUID? {
        guard let id = selection.first else { return nil }
        return bookmarks.folder(withID: id) != nil ? id : bookmarks.location(of: id)?.folderID
    }

    private func delete(_ ids: [UUID]) {
        if let deletion = bookmarks.delete(ids) { prompt = deletion }
    }

    /// Opens in a new tab of the profile's frontmost window, or a new window when it has none.
    private func open(_ urls: [URL], in target: BookmarkOpenTarget) {
        guard !urls.isEmpty else { return }
        if target == .newTab, let browser = profiles.frontmostBrowser(in: profileID) {
            browser.openInNewTabs(urls)
            browser.window?.makeKeyAndOrderFront(nil)
            return
        }
        openWindow(id: target == .privateWindow ? BrowserApp.privateWindowID : BrowserApp.windowID,
                   value: ProfileWindowRequest(profileID: profileID, urls: urls))
    }
}

extension NSPasteboard.PasteboardType {
    static let bookmarkNode = NSPasteboard.PasteboardType("dev.athas.browser.bookmark-node")
}

private extension NSUserInterfaceItemIdentifier {
    static let nameColumn = NSUserInterfaceItemIdentifier("name")
    static let addressColumn = NSUserInterfaceItemIdentifier("address")
}

private struct BookmarkOutline: NSViewRepresentable {
    let nodes: [BookmarkNode]
    let query: String
    let bookmarks: BookmarkStore
    @Binding var selection: [UUID]
    let open: ([URL], BookmarkOpenTarget) -> Void
    let delete: ([UUID]) -> Void
    let newFolder: (UUID?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let outline = BookmarkOutlineView()
        let name = NSTableColumn(identifier: .nameColumn)
        name.title = "Name"
        name.width = 300
        let address = NSTableColumn(identifier: .addressColumn)
        address.title = "Address"
        address.width = 320
        outline.addTableColumn(name)
        outline.addTableColumn(address)
        outline.outlineTableColumn = name
        outline.style = .inset
        outline.rowHeight = 24
        outline.allowsMultipleSelection = true
        outline.usesAlternatingRowBackgroundColors = true
        outline.autoresizesOutlineColumn = false
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.openClickedRow(_:))
        outline.registerForDraggedTypes([.bookmarkNode])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu
        outline.deleteSelection = { [weak coordinator] in coordinator?.deleteSelection() }
        coordinator.outlineView = outline

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        coordinator.reload()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reloadIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
                             NSTextFieldDelegate {
        var parent: BookmarkOutline
        weak var outlineView: NSOutlineView?
        /// One object per bookmark or folder, kept across reloads so the outline keeps track of what's expanded.
        private var items: [UUID: Item] = [:]
        private var nodesByID: [UUID: BookmarkNode] = [:]
        private var shownNodes: [BookmarkNode] = []
        private var expandedIDs: Set<UUID> = []
        private var shownTree: [BookmarkNode]?
        private var shownQuery: String?
        private var isReloading = false

        final class Item: NSObject {
            let id: UUID

            init(id: UUID) {
                self.id = id
            }
        }

        init(_ parent: BookmarkOutline) {
            self.parent = parent
        }

        private var searchText: String {
            parent.query.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var isSearching: Bool {
            !searchText.isEmpty
        }

        private func item(_ id: UUID) -> Item {
            if let item = items[id] { return item }
            let item = Item(id: id)
            items[id] = item
            return item
        }

        private func node(_ item: Any?) -> BookmarkNode? {
            (item as? Item).flatMap { nodesByID[$0.id] }
        }

        func reloadIfNeeded() {
            guard shownTree != parent.nodes || shownQuery != parent.query else { return }
            reload()
        }

        /// Shows the bookmarks again, keeping folders open and the selection where they still exist. A search shows
        /// matching bookmarks and folders in a flat list.
        func reload() {
            guard let outlineView else { return }
            shownTree = parent.nodes
            shownQuery = parent.query
            nodesByID = [:]
            var matches: [BookmarkNode] = []
            func index(_ nodes: [BookmarkNode]) {
                for node in nodes {
                    nodesByID[node.id] = node
                    if isSearching, Self.matches(node, searchText) { matches.append(node) }
                    if let folder = node.folder { index(folder.children) }
                }
            }
            index(parent.nodes)
            shownNodes = isSearching ? matches : parent.nodes
            items = items.filter { nodesByID[$0.key] != nil }
            expandedIDs.formIntersection(nodesByID.keys)

            isReloading = true
            outlineView.reloadData()
            if !isSearching {
                func expand(_ nodes: [BookmarkNode]) {
                    for case .folder(let folder) in nodes where expandedIDs.contains(folder.id) {
                        outlineView.expandItem(item(folder.id))
                        expand(folder.children)
                    }
                }
                expand(parent.nodes)
            }
            let rows = parent.selection.compactMap { id in items[id].map { outlineView.row(forItem: $0) } }
                .filter { $0 >= 0 }
            outlineView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
            isReloading = false
            updateSelection()
        }

        private static func matches(_ node: BookmarkNode, _ text: String) -> Bool {
            switch node {
            case .bookmark(let bookmark):
                bookmark.displayTitle.localizedCaseInsensitiveContains(text)
                    || bookmark.url.absoluteString.localizedCaseInsensitiveContains(text)
            case .folder(let folder):
                folder.displayTitle.localizedCaseInsensitiveContains(text)
            }
        }

        private var selectedIDs: [UUID] {
            guard let outlineView else { return [] }
            return outlineView.selectedRowIndexes.compactMap { (outlineView.item(atRow: $0) as? Item)?.id }
        }

        private func updateSelection() {
            let ids = selectedIDs
            if parent.selection != ids { parent.selection = ids }
        }

        // MARK: Data

        private func children(of item: Any?) -> [BookmarkNode] {
            guard item != nil else { return shownNodes }
            return isSearching ? [] : node(item)?.folder?.children ?? []
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            self.item(children(of: item)[index].id)
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !isSearching && node(item)?.folder != nil
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = node(item), let tableColumn else { return nil }
            let isName = tableColumn.identifier == .nameColumn
            let identifier = NSUserInterfaceItemIdentifier(isName ? "nameCell" : "addressCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? BookmarkCell
                ?? BookmarkCell(identifier: identifier, showsIcon: isName)
            cell.textField?.delegate = self
            switch node {
            case .bookmark(let bookmark):
                cell.show(isName ? bookmark.displayTitle : bookmark.url.absoluteString, isEditable: true,
                          isSecondary: !isName)
                cell.icon?.rootView = AnyView(SiteIcon(url: bookmark.url, size: 16))
            case .folder(let folder):
                let count = folder.allBookmarks.count
                cell.show(isName ? folder.displayTitle : count == 1 ? "1 bookmark" : "\(count) bookmarks",
                          isEditable: isName, isSecondary: !isName)
                cell.icon?.rootView = AnyView(Image(systemName: "folder").foregroundStyle(.secondary))
            }
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isReloading else { return }
            updateSelection()
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isReloading, let item = notification.userInfo?["NSObject"] as? Item else { return }
            expandedIDs.insert(item.id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isReloading, let item = notification.userInfo?["NSObject"] as? Item else { return }
            expandedIDs.remove(item.id)
        }

        // MARK: Editing

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let outlineView else { return }
            let row = outlineView.row(for: field)
            let column = outlineView.column(for: field)
            guard row >= 0, column >= 0, let item = outlineView.item(atRow: row) as? Item,
                  let node = nodesByID[item.id] else { return }
            let text = field.stringValue
            if outlineView.tableColumns[column].identifier == .nameColumn {
                if text != node.displayTitle { parent.bookmarks.rename(item.id, to: text) }
            } else if let bookmark = node.bookmark {
                if let url = BookmarkStore.address(from: text), url != bookmark.url {
                    parent.bookmarks.update(item.id, title: bookmark.title, url: url)
                } else {
                    field.stringValue = bookmark.url.absoluteString
                }
            }
        }

        func deleteSelection() {
            let ids = selectedIDs
            guard !ids.isEmpty else { return }
            parent.delete(ids)
        }

        @objc func openClickedRow(_ sender: Any?) {
            guard let outlineView, outlineView.clickedRow >= 0,
                  let item = outlineView.item(atRow: outlineView.clickedRow) as? Item,
                  let node = nodesByID[item.id] else { return }
            if let bookmark = node.bookmark {
                parent.open([bookmark.url], .newTab)
            } else if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
        }

        // MARK: Dragging

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard !isSearching, let node = node(item) else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(node.id.uuidString, forType: .bookmarkNode)
            if let bookmark = node.bookmark {
                pasteboardItem.setString(bookmark.url.absoluteString, forType: .URL)
                pasteboardItem.setString(bookmark.url.absoluteString, forType: .string)
            }
            return pasteboardItem
        }

        /// The dragged bookmarks and folders, without those inside a dragged folder, which move with it.
        private func draggedIDs(_ info: NSDraggingInfo) -> [UUID] {
            let ids = (info.draggingPasteboard.pasteboardItems ?? [])
                .compactMap { $0.string(forType: .bookmarkNode).flatMap(UUID.init(uuidString:)) }
            return ids.filter { id in
                !ids.contains { $0 != id && parent.bookmarks.folder(withID: $0) != nil
                    && parent.bookmarks.isNode(id, within: $0) }
            }
        }

        /// A drop on a bookmark goes before it; a drop on a folder goes inside it, at the end.
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                         proposedChildIndex index: Int) -> NSDragOperation {
            let ids = draggedIDs(info)
            guard !isSearching, !ids.isEmpty else { return [] }
            var folderID = (item as? Item)?.id
            if let targetID = folderID, nodesByID[targetID]?.folder == nil {
                guard let location = parent.bookmarks.location(of: targetID) else { return [] }
                folderID = location.folderID
                outlineView.setDropItem(location.folderID.map { self.item($0) }, dropChildIndex: location.index)
            }
            if let folderID, ids.contains(where: { parent.bookmarks.isNode(folderID, within: $0) }) { return [] }
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?,
                         childIndex index: Int) -> Bool {
            let ids = draggedIDs(info)
            guard !ids.isEmpty else { return false }
            let folderID = (item as? Item)?.id
            var insertionIndex: Int? = index == NSOutlineViewDropOnItemIndex ? nil : index
            for id in ids {
                parent.bookmarks.move(id, to: folderID, at: insertionIndex)
                if insertionIndex != nil, let location = parent.bookmarks.location(of: id),
                   location.folderID == folderID {
                    insertionIndex = location.index + 1
                }
            }
            if let folderID { expandedIDs.insert(folderID) }
            return true
        }

        // MARK: Menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outlineView else { return }
            let row = outlineView.clickedRow
            guard row >= 0, let item = outlineView.item(atRow: row) as? Item, let node = nodesByID[item.id] else {
                menu.addItem(ActionMenuItem("New Folder…") { [weak self] in self?.parent.newFolder(nil) })
                return
            }
            if !outlineView.selectedRowIndexes.contains(row) {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let ids = selectedIDs
            switch node {
            case .bookmark(let bookmark):
                let urls = ids.compactMap { nodesByID[$0]?.bookmark?.url }
                menu.addItem(ActionMenuItem(urls.count > 1 ? "Open in New Tabs" : "Open in New Tab") { [weak self] in
                    self?.parent.open(urls, .newTab)
                })
                menu.addItem(ActionMenuItem("Open in New Window") { [weak self] in
                    self?.parent.open(urls, .newWindow)
                })
                menu.addItem(ActionMenuItem("Open in Private Window") { [weak self] in
                    self?.parent.open(urls, .privateWindow)
                })
                menu.addItem(.separator())
                menu.addItem(ActionMenuItem("Rename") { [weak outlineView] in
                    outlineView?.editColumn(0, row: row, with: nil, select: true)
                })
                menu.addItem(ActionMenuItem("Edit Address") { [weak outlineView] in
                    outlineView?.editColumn(1, row: row, with: nil, select: true)
                })
                menu.addItem(ActionMenuItem("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
                })
            case .folder(let folder):
                menu.addItem(ActionMenuItem("Open All in Tabs") { [weak self] in
                    self?.parent.open(folder.allBookmarks.map(\.url), .newTab)
                })
                menu.addItem(.separator())
                menu.addItem(ActionMenuItem("Rename") { [weak outlineView] in
                    outlineView?.editColumn(0, row: row, with: nil, select: true)
                })
                menu.addItem(ActionMenuItem("New Folder Inside…") { [weak self] in
                    self?.parent.newFolder(folder.id)
                })
            }
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Delete") { [weak self] in self?.parent.delete(ids) })
        }
    }
}

/// Deletes the selection with the Delete key, or Edit ▸ Delete.
private final class BookmarkOutlineView: NSOutlineView {
    var deleteSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Delete and Forward Delete.
        if [51, 117].contains(event.keyCode), !selectedRowIndexes.isEmpty {
            deleteSelection?()
        } else {
            super.keyDown(with: event)
        }
    }

    @objc func delete(_ sender: Any?) {
        deleteSelection?()
    }
}

private final class BookmarkCell: NSTableCellView {
    private(set) var icon: NSHostingView<AnyView>?

    init(identifier: NSUserInterfaceItemIdentifier, showsIcon: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field

        var constraints = [
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ]
        if showsIcon {
            let icon = NSHostingView(rootView: AnyView(EmptyView()))
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            self.icon = icon
            constraints += [
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            ]
        } else {
            constraints.append(field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ text: String, isEditable: Bool, isSecondary: Bool) {
        textField?.stringValue = text
        textField?.isEditable = isEditable
        textField?.textColor = isSecondary ? .secondaryLabelColor : .labelColor
    }
}

/// A menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler()
    }
}
