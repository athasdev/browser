import Foundation
import Observation

struct Bookmark: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var url: URL

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url.host().map(Bookmark.trimmedHost) ?? url.absoluteString
    }

    static func trimmedHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// A folder of bookmarks and more folders, on the bookmarks bar or in another folder.
struct BookmarkFolder: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var children: [BookmarkNode] = []

    var displayTitle: String {
        title.isEmpty ? "Untitled Folder" : title
    }

    /// The folder's bookmarks and those of the folders inside it, in menu order.
    var allBookmarks: [Bookmark] {
        BookmarkStore.bookmarks(in: children)
    }
}

/// A bookmark or a folder. Bookmarks are saved the same way they were before there were folders, so a list saved
/// then reads as the bookmarks bar holding them.
enum BookmarkNode: Identifiable, Equatable, Codable {
    case bookmark(Bookmark)
    case folder(BookmarkFolder)

    private enum CodingKeys: String, CodingKey {
        case id, title, children
    }

    var id: UUID {
        switch self {
        case .bookmark(let bookmark): bookmark.id
        case .folder(let folder): folder.id
        }
    }

    var displayTitle: String {
        switch self {
        case .bookmark(let bookmark): bookmark.displayTitle
        case .folder(let folder): folder.displayTitle
        }
    }

    var bookmark: Bookmark? {
        if case .bookmark(let bookmark) = self { return bookmark }
        return nil
    }

    var folder: BookmarkFolder? {
        if case .folder(let folder) = self { return folder }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.children) {
            self = .folder(BookmarkFolder(id: try container.decode(UUID.self, forKey: .id),
                                          title: try container.decode(String.self, forKey: .title),
                                          children: try container.decode([BookmarkNode].self, forKey: .children)))
        } else {
            self = .bookmark(try Bookmark(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .bookmark(let bookmark):
            try bookmark.encode(to: encoder)
        case .folder(let folder):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(folder.id, forKey: .id)
            try container.encode(folder.title, forKey: .title)
            try container.encode(folder.children, forKey: .children)
        }
    }
}

/// A folder in a folder picker, indented by how deeply it's nested.
struct BookmarkFolderEntry: Identifiable, Equatable {
    let folder: BookmarkFolder
    let depth: Int

    var id: UUID { folder.id }

    var indentedTitle: String {
        String(repeating: "    ", count: depth) + folder.displayTitle
    }
}

/// The bookmarks bar and its folders. Bookmarks and folders keep their IDs for as long as they exist, wherever
/// they move.
@MainActor
@Observable
final class BookmarkStore {
    /// What the bookmarks bar shows, in order.
    private(set) var root: [BookmarkNode] = []
    /// The folder a bookmark was last added to, offered first for the next one. `nil` for the bookmarks bar.
    var lastFolderID: UUID?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let key: String
    nonisolated static let storageKey = "bookmarks"
    /// Called after each change made on this device, so iCloud sync can send it.
    @ObservationIgnored var onChange: (() -> Void)?

    /// Pass `nil` defaults to keep bookmarks in memory only. A profile's bookmarks are saved under its key prefix.
    init(defaults: UserDefaults? = .standard, keyPrefix: String = "") {
        self.defaults = defaults
        key = keyPrefix + Self.storageKey
        if let data = defaults?.data(forKey: key),
           let root = try? JSONDecoder().decode([BookmarkNode].self, from: data) {
            self.root = root
        }
    }

    /// Every bookmark, those in folders included, in the order the menus show them.
    var bookmarks: [Bookmark] {
        Self.bookmarks(in: root)
    }

    nonisolated static func bookmarks(in nodes: [BookmarkNode]) -> [Bookmark] {
        nodes.flatMap { node -> [Bookmark] in
            switch node {
            case .bookmark(let bookmark): [bookmark]
            case .folder(let folder): bookmarks(in: folder.children)
            }
        }
    }

    /// Every folder, each after the one holding it.
    var folders: [BookmarkFolderEntry] {
        func collect(_ nodes: [BookmarkNode], depth: Int) -> [BookmarkFolderEntry] {
            nodes.flatMap { node -> [BookmarkFolderEntry] in
                guard let folder = node.folder else { return [] }
                return [BookmarkFolderEntry(folder: folder, depth: depth)] + collect(folder.children, depth: depth + 1)
            }
        }
        return collect(root, depth: 0)
    }

    func node(withID id: UUID?) -> BookmarkNode? {
        guard let id, let location = location(of: id) else { return nil }
        return children(of: location.folderID)[location.index]
    }

    func folder(withID id: UUID?) -> BookmarkFolder? {
        node(withID: id)?.folder
    }

    /// A folder's contents, or the bookmarks bar's for `nil`.
    func children(of folderID: UUID?) -> [BookmarkNode] {
        guard let folderID else { return root }
        return folder(withID: folderID)?.children ?? []
    }

    /// The folder holding a bookmark or folder, `nil` for the bookmarks bar, and its position there.
    func location(of id: UUID) -> (folderID: UUID?, index: Int)? {
        func find(in nodes: [BookmarkNode], folderID: UUID?) -> (folderID: UUID?, index: Int)? {
            for (index, node) in nodes.enumerated() {
                if node.id == id { return (folderID, index) }
                if let folder = node.folder, let found = find(in: folder.children, folderID: folder.id) {
                    return found
                }
            }
            return nil
        }
        return find(in: root, folderID: nil)
    }

    /// Whether `id` is the folder or inside it, so it can't move into it.
    func isNode(_ id: UUID, within folderID: UUID) -> Bool {
        id == folderID || folder(withID: folderID).map { Self.contains(id, in: $0.children) } ?? false
    }

    private static func contains(_ id: UUID, in nodes: [BookmarkNode]) -> Bool {
        nodes.contains { $0.id == id || ($0.folder.map { contains(id, in: $0.children) } ?? false) }
    }

    func bookmark(for url: URL?) -> Bookmark? {
        guard let url else { return nil }
        return bookmarks.first { $0.url == url }
    }

    func isBookmarked(_ url: URL?) -> Bool {
        bookmark(for: url) != nil
    }

    /// Adds a bookmark at the end of a folder, or of the bookmarks bar, and returns its ID. A page that's already
    /// bookmarked keeps its bookmark, whose ID is returned instead.
    @discardableResult
    func add(title: String, url: URL, in folderID: UUID? = nil) -> UUID {
        if let existing = bookmark(for: url) { return existing.id }
        let bookmark = Bookmark(title: title, url: url)
        let folderID = folder(withID: folderID) == nil ? nil : folderID
        Self.withChildren(of: folderID, in: &root) { $0.append(.bookmark(bookmark)) }
        save()
        return bookmark.id
    }

    /// Adds the bookmarks whose addresses aren't bookmarked yet, in order, and returns how many were added.
    @discardableResult
    func add(contentsOf imported: [Bookmark]) -> Int {
        add(contentsOf: imported.map { ImportedBookmark(title: $0.title, url: $0.url) })
    }

    /// Adds imported bookmarks whose addresses aren't bookmarked yet into their folders, making the folders that
    /// don't exist yet and reusing those with the same name, and returns how many were added.
    @discardableResult
    func add(contentsOf imported: [ImportedBookmark]) -> Int {
        var known = Set(bookmarks.map(\.url))
        var added = 0
        for item in imported where known.insert(item.url).inserted {
            let folderID = makeFolders(item.folders)
            Self.withChildren(of: folderID, in: &root) { $0.append(.bookmark(Bookmark(title: item.title, url: item.url))) }
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    /// Finds or makes the folders on a path from the bookmarks bar, and returns the last one's ID.
    private func makeFolders(_ path: [String]) -> UUID? {
        var parentID: UUID?
        for title in path {
            if let existing = children(of: parentID).first(where: { $0.folder?.title == title }) {
                parentID = existing.id
            } else {
                let folder = BookmarkFolder(title: title)
                Self.withChildren(of: parentID, in: &root) { $0.append(.folder(folder)) }
                parentID = folder.id
            }
        }
        return parentID
    }

    /// Adds the page when it isn't bookmarked yet, otherwise removes it.
    func toggle(title: String, url: URL) {
        if let bookmark = bookmark(for: url) {
            remove(bookmark.id)
        } else {
            add(title: title, url: url)
        }
    }

    /// Adds an empty folder to a folder, or the bookmarks bar, at `index` or at the end, and returns its ID.
    @discardableResult
    func addFolder(titled title: String, in parentID: UUID? = nil, at index: Int? = nil) -> UUID {
        let folder = BookmarkFolder(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        let parentID = self.folder(withID: parentID) == nil ? nil : parentID
        Self.withChildren(of: parentID, in: &root) { children in
            children.insert(.folder(folder), at: min(max(index ?? children.count, 0), children.count))
        }
        save()
        return folder.id
    }

    /// Removes a bookmark, or a folder with everything in it.
    func remove(_ id: UUID) {
        guard let location = location(of: id) else { return }
        Self.withChildren(of: location.folderID, in: &root) { $0.remove(at: location.index) }
        save()
    }

    /// Removes a folder. Its contents can take its place in the folder holding it instead of going with it.
    func removeFolder(_ id: UUID, keepingContents: Bool) {
        guard keepingContents, let folder = folder(withID: id), let location = location(of: id) else {
            return remove(id)
        }
        Self.withChildren(of: location.folderID, in: &root) {
            $0.replaceSubrange(location.index...location.index, with: folder.children)
        }
        save()
    }

    /// Renames a bookmark or folder.
    func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        modify(id) { node in
            switch node {
            case .bookmark(var bookmark):
                bookmark.title = title
                node = .bookmark(bookmark)
            case .folder(var folder):
                folder.title = title
                node = .folder(folder)
            }
        }
    }

    /// Changes a bookmark's name and address.
    func update(_ id: UUID, title: String, url: URL) {
        modify(id) { node in
            guard case .bookmark(var bookmark) = node else { return }
            bookmark.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            bookmark.url = url
            node = .bookmark(bookmark)
        }
    }

    /// Moves a bookmark or folder into a folder, or onto the bookmarks bar for `nil`, before the item at `index`
    /// there, or at the end. A folder can't move into itself or a folder inside it.
    @discardableResult
    func move(_ id: UUID, to folderID: UUID?, at index: Int? = nil) -> Bool {
        guard let source = location(of: id) else { return false }
        if let folderID {
            guard folder(withID: folderID) != nil, !isNode(folderID, within: id) else { return false }
        }
        var destination = index ?? children(of: folderID).count
        if source.folderID == folderID {
            if destination > source.index { destination -= 1 }
            guard destination != source.index else { return false }
        }
        var node: BookmarkNode?
        Self.withChildren(of: source.folderID, in: &root) { node = $0.remove(at: source.index) }
        guard let node else { return false }
        Self.withChildren(of: folderID, in: &root) { children in
            children.insert(node, at: min(max(destination, 0), children.count))
        }
        save()
        return true
    }

    /// Moves a bookmark or folder to where another is, like dragging it over that one: after it when coming from
    /// before it in the same folder, otherwise before it.
    func move(_ id: UUID, toPositionOf targetID: UUID) {
        guard id != targetID, let source = location(of: id), let target = location(of: targetID) else { return }
        let isAfter = source.folderID == target.folderID && source.index < target.index
        move(id, to: target.folderID, at: isAfter ? target.index + 1 : target.index)
    }

    /// An address typed for a bookmark: a web address, with `https://` added when it has no scheme.
    nonisolated static func address(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if scheme == "file" || scheme == "about" { return url }
            if url.host() != nil { return url }
        }
        guard let url = URL(string: "https://\(text)"), url.host()?.contains(".") == true || url.host() == "localhost"
        else { return nil }
        return url
    }

    private func modify(_ id: UUID, _ change: (inout BookmarkNode) -> Void) {
        guard let location = location(of: id) else { return }
        Self.withChildren(of: location.folderID, in: &root) { change(&$0[location.index]) }
        save()
    }

    /// Changes the contents of a folder, or of the bookmarks bar for `nil`, wherever the folder is.
    @discardableResult
    private static func withChildren(of folderID: UUID?, in nodes: inout [BookmarkNode],
                                     _ change: (inout [BookmarkNode]) -> Void) -> Bool {
        guard let folderID else {
            change(&nodes)
            return true
        }
        for index in nodes.indices {
            guard case .folder(var folder) = nodes[index] else { continue }
            if folder.id == folderID {
                change(&folder.children)
            } else if !withChildren(of: folderID, in: &folder.children, change) {
                continue
            }
            nodes[index] = .folder(folder)
            return true
        }
        return false
    }

    /// Replaces every bookmark and folder with ones that changed on another device, without reporting the change
    /// back to sync.
    func replaceAll(with root: [BookmarkNode]) {
        guard root != self.root else { return }
        self.root = root
        persist()
    }

    private func save() {
        persist()
        onChange?()
    }

    private func persist() {
        guard let defaults, let data = try? JSONEncoder().encode(root) else { return }
        defaults.set(data, forKey: key)
    }
}

/// A bookmark from another browser, with the folders it was in there.
struct ImportedBookmark: Equatable, Sendable {
    let title: String
    let url: URL
    /// The folders it's in, from the bookmarks bar down. Empty for a bookmark on the bar.
    var folders: [String] = []
}
