import AppKit
import SwiftUI

struct BookmarksBar: View {
    let bookmarks: BookmarkStore
    let browser: BrowserModel

    @State private var draggedNodeID: UUID?
    @State private var dropFolderID: UUID?
    @State private var prompt: BookmarkPrompt?
    @Environment(\.openWindow) private var openWindow
    @AppStorage(BookmarksBarVisibility.storageKey) private var visibility = BookmarksBarVisibility.always

    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 2) {
            if bookmarks.root.isEmpty {
                Label("Bookmark pages with ⌘D or the star in the address bar", systemImage: "star")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(bookmarks.root) { node in
                            item(for: node)
                        }
                    }
                }
                .scrollIndicators(.never)

                Menu {
                    BookmarkMenuItems(nodes: bookmarks.root, open: open, openAll: openAll, offersOpenAll: false)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(ChromeIconButtonStyle(size: 24))
                .fixedSize()
                .help("All Bookmarks")
            }
        }
        .padding(.horizontal, BrowserChrome.edgeInset)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .contextMenu { barMenu }
        .animation(.snappy(duration: 0.2), value: bookmarks.root.map(\.id))
        .bookmarkPrompts($prompt, bookmarks: bookmarks)
    }

    @ViewBuilder
    private var barMenu: some View {
        Button("Add Bookmark for This Page") { browser.isEditingBookmark = true }
            .disabled(browser.activeTab.map { $0.isNewTab || $0.url == nil } ?? true)
        Button("New Folder…") { prompt = .newFolder(parentID: nil) }
        Divider()
        Picker("Show Bookmarks Bar", selection: $visibility) {
            ForEach(BookmarksBarVisibility.allCases) { visibility in
                Text(visibility.shortTitle).tag(visibility)
            }
        }
        .pickerStyle(.menu)
        Button("Manage Bookmarks…") { openManager() }
    }

    @ViewBuilder
    private func item(for node: BookmarkNode) -> some View {
        switch node {
        case .bookmark(let bookmark):
            Button { open(bookmark.url) } label: {
                HStack(spacing: 6) {
                    SiteIcon(url: bookmark.url, size: 14)
                    Text(bookmark.displayTitle)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                        .fixedSize()
                }
            }
            .buttonStyle(BookmarkButtonStyle())
            .help(bookmark.url.absoluteString)
            .contextMenu {
                BookmarkMenu(bookmark: bookmark, bookmarks: bookmarks, browser: browser) { prompt = $0 }
            }
            .onDrag {
                draggedNodeID = bookmark.id
                return NSItemProvider(object: bookmark.url.absoluteString as NSString)
            }
            .onDrop(of: [.text], delegate: BookmarkDropDelegate(target: node, bookmarks: bookmarks,
                                                                draggedID: $draggedNodeID,
                                                                dropFolderID: $dropFolderID))
        case .folder(let folder):
            Menu {
                BookmarkMenuItems(nodes: folder.children, open: open, openAll: openAll)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Text(folder.displayTitle)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                        .fixedSize()
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(BookmarkButtonStyle(isHighlighted: dropFolderID == folder.id))
            .fixedSize()
            .help(folder.displayTitle)
            .contextMenu {
                BookmarkFolderMenu(folder: folder, bookmarks: bookmarks, openAll: openAll) { prompt = $0 }
            }
            .onDrag {
                draggedNodeID = folder.id
                return NSItemProvider(object: folder.displayTitle as NSString)
            }
            .onDrop(of: [.text], delegate: BookmarkDropDelegate(target: node, bookmarks: bookmarks,
                                                                draggedID: $draggedNodeID,
                                                                dropFolderID: $dropFolderID))
        }
    }

    private func open(_ url: URL) {
        browser.open(url, inNewTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    private func openAll(_ bookmarks: [Bookmark]) {
        browser.openInNewTabs(bookmarks.map(\.url))
    }

    private func openManager() {
        guard let profileID = browser.profileID ?? browser.openerProfileID else { return }
        openWindow(id: BrowserApp.bookmarksWindowID, value: profileID)
    }
}

/// A folder's contents as menu items, with folders inside it as submenus, for the bookmarks bar and the Bookmarks
/// menu. AppKit menus can't be rearranged by dragging, so their bookmarks move in Manage Bookmarks instead.
struct BookmarkMenuItems: View {
    let nodes: [BookmarkNode]
    let open: (URL) -> Void
    let openAll: ([Bookmark]) -> Void
    /// The bookmarks bar's own menus leave out Open All in Tabs, which would open every bookmark.
    var offersOpenAll = true

    var body: some View {
        if nodes.isEmpty {
            Text("Empty")
        }
        ForEach(nodes) { node in
            switch node {
            case .bookmark(let bookmark):
                Button(Self.menuTitle(bookmark.displayTitle)) { open(bookmark.url) }
            case .folder(let folder):
                Menu(Self.menuTitle(folder.displayTitle)) {
                    BookmarkMenuItems(nodes: folder.children, open: open, openAll: openAll)
                }
            }
        }
        let bookmarks = BookmarkStore.bookmarks(in: nodes)
        if offersOpenAll, bookmarks.count > 1 {
            Divider()
            Button("Open All in Tabs") { openAll(bookmarks) }
        }
    }

    static func menuTitle(_ title: String) -> String {
        title.count > 60 ? String(title.prefix(59)) + "…" : title
    }
}

/// What a bookmark or folder action asks the user before it changes anything.
enum BookmarkPrompt: Identifiable, Equatable {
    /// A new folder in a folder, or on the bookmarks bar for `nil`. A bookmark moved to a new folder moves into it.
    case newFolder(parentID: UUID?, moving: UUID? = nil)
    case renameFolder(UUID)
    case editBookmark(UUID)
    /// Deleting folders with something in them asks whether their contents go too.
    case delete([UUID])

    var id: String {
        switch self {
        case .newFolder(let parentID, let moving): "new \(parentID?.uuidString ?? "") \(moving?.uuidString ?? "")"
        case .renameFolder(let id): "rename \(id)"
        case .editBookmark(let id): "edit \(id)"
        case .delete(let ids): "delete \(ids.map(\.uuidString).joined())"
        }
    }
}

extension BookmarkStore {
    /// Deletes bookmarks and empty folders right away, and returns the prompt to show for folders that aren't empty.
    func delete(_ ids: [UUID]) -> BookmarkPrompt? {
        let hasContents = ids.contains { !(folder(withID: $0)?.children.isEmpty ?? true) }
        guard !hasContents else { return .delete(ids) }
        ids.forEach(remove)
        return nil
    }
}

extension View {
    /// Shows the alerts bookmark actions ask with: names for new and renamed folders, a bookmark's name and address,
    /// and whether deleted folders' contents go too.
    func bookmarkPrompts(_ prompt: Binding<BookmarkPrompt?>, bookmarks: BookmarkStore) -> some View {
        modifier(BookmarkPrompts(prompt: prompt, bookmarks: bookmarks))
    }
}

private struct BookmarkPrompts: ViewModifier {
    @Binding var prompt: BookmarkPrompt?
    let bookmarks: BookmarkStore
    @State private var name = ""
    @State private var address = ""

    private var isPresented: Binding<Bool> {
        Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
    }

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: isPresented, presenting: prompt) { prompt in
                actions(for: prompt)
            } message: { prompt in
                if let message = message(for: prompt) { Text(message) }
            }
            .onChange(of: prompt) { _, prompt in
                guard let prompt else { return }
                switch prompt {
                case .newFolder: name = "New Folder"
                case .renameFolder(let id): name = bookmarks.folder(withID: id)?.title ?? ""
                case .editBookmark(let id):
                    let bookmark = bookmarks.node(withID: id)?.bookmark
                    name = bookmark?.title ?? ""
                    address = bookmark?.url.absoluteString ?? ""
                case .delete: break
                }
            }
    }

    private var title: String {
        switch prompt {
        case .newFolder: "New Folder"
        case .renameFolder: "Rename Folder"
        case .editBookmark: "Edit Bookmark"
        case .delete(let ids):
            ids.count == 1 ? "Delete “\(bookmarks.node(withID: ids[0])?.displayTitle ?? "Folder")”?"
                : "Delete \(ids.count) Items?"
        case nil: ""
        }
    }

    private func message(for prompt: BookmarkPrompt) -> String? {
        guard case .delete(let ids) = prompt else { return nil }
        let count = ids.compactMap { bookmarks.node(withID: $0)?.folder }.reduce(0) { $0 + $1.allBookmarks.count }
        return count == 1 ? "There’s a bookmark inside. You can keep it in the folder above."
            : "There are \(count) bookmarks inside. You can keep them in the folder above."
    }

    @ViewBuilder
    private func actions(for prompt: BookmarkPrompt) -> some View {
        switch prompt {
        case .newFolder(let parentID, let moving):
            TextField("Name", text: $name)
            Button("Create") {
                let folderID = bookmarks.addFolder(titled: name, in: parentID)
                if let moving { bookmarks.move(moving, to: folderID) }
            }
            Button("Cancel", role: .cancel) {}
        case .renameFolder(let id):
            TextField("Name", text: $name)
            Button("Rename") { bookmarks.rename(id, to: name) }
            Button("Cancel", role: .cancel) {}
        case .editBookmark(let id):
            TextField("Name", text: $name)
            TextField("Address", text: $address)
            Button("Save") {
                if let url = BookmarkStore.address(from: address) {
                    bookmarks.update(id, title: name, url: url)
                } else {
                    bookmarks.rename(id, to: name)
                }
            }
            Button("Cancel", role: .cancel) {}
        case .delete(let ids):
            Button("Delete Everything", role: .destructive) {
                ids.forEach { bookmarks.removeFolder($0, keepingContents: false) }
            }
            Button("Keep Contents") {
                ids.forEach { bookmarks.removeFolder($0, keepingContents: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Actions shared by bookmarks in the bar and favorites on the new tab page.
struct BookmarkMenu: View {
    let bookmark: Bookmark
    let bookmarks: BookmarkStore
    let browser: BrowserModel
    let ask: (BookmarkPrompt) -> Void
    @Environment(\.openWindow) private var openWindow

    private var profileID: UUID? {
        browser.profileID ?? browser.openerProfileID
    }

    var body: some View {
        Button("Open") { browser.open(bookmark.url) }
        Button("Open in New Tab") { browser.open(bookmark.url, inNewTab: true) }
        Button("Open in New Window") {
            guard let profileID else { return }
            openWindow(id: browser.isPrivate ? BrowserApp.privateWindowID : BrowserApp.windowID,
                       value: ProfileWindowRequest(profileID: profileID, urls: [bookmark.url]))
        }
        .disabled(profileID == nil)
        Button("Open in Private Window") {
            guard let profileID else { return }
            openWindow(id: BrowserApp.privateWindowID,
                       value: ProfileWindowRequest(profileID: profileID, urls: [bookmark.url]))
        }
        .disabled(profileID == nil)
        Divider()
        Button("Edit…") { ask(.editBookmark(bookmark.id)) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
        }
        BookmarkMoveMenu(id: bookmark.id, bookmarks: bookmarks, ask: ask)
        Divider()
        Button("Delete", role: .destructive) { bookmarks.remove(bookmark.id) }
    }
}

/// Moves a bookmark or folder onto the bookmarks bar or into another folder.
struct BookmarkMoveMenu: View {
    let id: UUID
    let bookmarks: BookmarkStore
    let ask: (BookmarkPrompt) -> Void

    var body: some View {
        let currentFolderID = bookmarks.location(of: id)?.folderID
        Menu("Move to") {
            Button("Bookmarks Bar") { bookmarks.move(id, to: nil) }
                .disabled(currentFolderID == nil)
            let folders = bookmarks.folders.filter { !bookmarks.isNode($0.id, within: id) }
            if !folders.isEmpty {
                Divider()
                ForEach(folders) { entry in
                    Button(entry.indentedTitle) { bookmarks.move(id, to: entry.id) }
                        .disabled(currentFolderID == entry.id)
                }
            }
            Divider()
            Button("New Folder…") { ask(.newFolder(parentID: currentFolderID, moving: id)) }
        }
    }
}

struct BookmarkFolderMenu: View {
    let folder: BookmarkFolder
    let bookmarks: BookmarkStore
    let openAll: ([Bookmark]) -> Void
    let ask: (BookmarkPrompt) -> Void

    var body: some View {
        Button("Open All in Tabs") { openAll(folder.allBookmarks) }
            .disabled(folder.allBookmarks.isEmpty)
        Divider()
        Button("Rename…") { ask(.renameFolder(folder.id)) }
        Button("New Folder Inside…") { ask(.newFolder(parentID: folder.id)) }
        BookmarkMoveMenu(id: folder.id, bookmarks: bookmarks, ask: ask)
        Divider()
        Button("Delete", role: .destructive) {
            if let prompt = bookmarks.delete([folder.id]) { ask(prompt) }
        }
    }
}

/// Picks the folder for a bookmark, from the bookmarks bar and every folder on it.
struct BookmarkFolderPicker: View {
    let bookmarks: BookmarkStore
    @Binding var folderID: UUID?

    var body: some View {
        Picker("Folder", selection: $folderID) {
            Label("Bookmarks Bar", systemImage: "menubar.rectangle").tag(UUID?.none)
            ForEach(bookmarks.folders) { entry in
                Label(entry.indentedTitle, systemImage: "folder").tag(UUID?.some(entry.id))
            }
        }
    }
}

/// The ⌘D bookmark editor under the address bar's star. Opening it bookmarks the page in the folder used last, so
/// one keystroke is enough; its name and folder can then change, or the bookmark can be removed.
struct BookmarkEditor: View {
    let bookmarks: BookmarkStore
    let title: String
    let url: URL
    let dismiss: () -> Void
    @State private var bookmarkID: UUID?
    @State private var name = ""
    @State private var folderID: UUID?
    @State private var isRemoved = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bookmark Added")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(done)
            BookmarkFolderPicker(bookmarks: bookmarks, folderID: $folderID)
            HStack {
                Button("Remove", role: .destructive) {
                    if let bookmarkID { bookmarks.remove(bookmarkID) }
                    isRemoved = true
                    dismiss()
                }
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            let existing = bookmarks.bookmark(for: url)
            let id = existing?.id ?? bookmarks.add(title: title, url: url, in: bookmarks.lastFolderID)
            bookmarkID = id
            name = existing?.title ?? title
            folderID = bookmarks.location(of: id)?.folderID
            isNameFocused = true
        }
        .onDisappear(perform: save)
    }

    private func done() {
        save()
        dismiss()
    }

    private func save() {
        guard !isRemoved, let bookmarkID, bookmarks.node(withID: bookmarkID) != nil else { return }
        bookmarks.rename(bookmarkID, to: name)
        if bookmarks.location(of: bookmarkID)?.folderID != folderID {
            bookmarks.move(bookmarkID, to: folderID)
        }
        bookmarks.lastFolderID = folderID
    }
}

private struct BookmarkButtonStyle: ButtonStyle {
    var isHighlighted = false
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered ? Color.primary : Color.primary.opacity(0.8))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(configuration.isPressed || isHighlighted ? Color.primary.opacity(0.12) :
                        isHovered ? Color.primary.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

/// Dragging over a bookmark moves the dragged one to its place. Dropping a bookmark on a folder moves it inside;
/// dragging a folder over another moves it to that one's place.
private struct BookmarkDropDelegate: DropDelegate {
    let target: BookmarkNode
    let bookmarks: BookmarkStore
    @Binding var draggedID: UUID?
    @Binding var dropFolderID: UUID?

    private var dropsInside: Bool {
        guard let draggedID, target.folder != nil else { return false }
        return bookmarks.node(withID: draggedID)?.bookmark != nil
    }

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != target.id else { return }
        if dropsInside {
            dropFolderID = target.id
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            bookmarks.move(draggedID, toPositionOf: target.id)
        }
    }

    func dropExited(info: DropInfo) {
        if dropFolderID == target.id { dropFolderID = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if let draggedID, dropsInside {
            withAnimation(.snappy(duration: 0.2)) {
                _ = bookmarks.move(draggedID, to: target.id)
            }
        }
        draggedID = nil
        dropFolderID = nil
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedID != nil
    }
}
