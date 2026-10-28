import CloudKit
import Foundation

/// A bookmark or folder as iCloud keeps it: one record each, pointing at the folder it's in, so edits to different
/// bookmarks on different devices merge.
struct SyncedBookmark: Codable, Equatable, Sendable {
    /// `nil` for the bookmarks bar.
    var parentID: UUID?
    var position: Int
    var title: String
    /// `nil` for a folder.
    var url: URL?

    var isFolder: Bool {
        url == nil
    }
}

/// An open tab, as other devices list it.
struct SyncedTab: Codable, Hashable, Sendable {
    var title: String
    var url: URL
}

/// The tabs a device has open in one profile.
struct DeviceTabs: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var platform: String
    var tabs: [SyncedTab]
    var modified: Date

    var symbolName: String {
        switch platform {
        case "iPhone": "iphone"
        case "iPad": "ipad"
        default: "laptopcomputer"
        }
    }
}

/// Turns the bookmark tree into iCloud's flat records and back.
enum BookmarkTree {
    static func flatten(_ root: [BookmarkNode]) -> [UUID: SyncedBookmark] {
        var items: [UUID: SyncedBookmark] = [:]
        func visit(_ nodes: [BookmarkNode], parentID: UUID?) {
            for (position, node) in nodes.enumerated() {
                switch node {
                case .bookmark(let bookmark):
                    items[bookmark.id] = SyncedBookmark(parentID: parentID, position: position, title: bookmark.title,
                                                        url: bookmark.url)
                case .folder(let folder):
                    items[folder.id] = SyncedBookmark(parentID: parentID, position: position, title: folder.title)
                    visit(folder.children, parentID: folder.id)
                }
            }
        }
        visit(root, parentID: nil)
        return items
    }

    /// Rebuilds the tree, ordering each folder by position and then ID, so every device builds the same tree.
    /// Items whose folder is gone, or that would put a folder inside itself, go on the bookmarks bar.
    static func build(_ items: [UUID: SyncedBookmark]) -> [BookmarkNode] {
        var childrenByParent: [UUID?: [UUID]] = [:]
        for (id, item) in items {
            childrenByParent[item.parentID, default: []].append(id)
        }
        let order = { (a: UUID, b: UUID) -> Bool in
            let (left, right) = (items[a]!.position, items[b]!.position)
            return left != right ? left < right : a.uuidString < b.uuidString
        }
        var visited = Set<UUID>()

        func node(for id: UUID) -> BookmarkNode? {
            guard visited.insert(id).inserted, let item = items[id] else { return nil }
            if let url = item.url {
                return .bookmark(Bookmark(id: id, title: item.title, url: url))
            }
            return .folder(BookmarkFolder(id: id, title: item.title, children: children(of: id)))
        }

        func children(of parentID: UUID?) -> [BookmarkNode] {
            (childrenByParent[parentID] ?? []).sorted(by: order).compactMap(node)
        }

        var root = children(of: nil)
        let unreachable = items.keys.filter { !visited.contains($0) }.sorted(by: order)
        for id in unreachable {
            if let node = node(for: id) { root.append(node) }
        }
        return root
    }
}

/// How bookmarks, open tabs, and profiles are stored as CloudKit records.
enum SyncRecords {
    static let bookmarkType = "Bookmark"
    static let deviceTabsType = "DeviceTabs"
    static let profileType = "Profile"
    static let profileRecordName = "profile"
    static let devicePrefix = "device-"
    static let zonePrefix = "profile-"

    static func zoneID(for profileID: UUID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zonePrefix + profileID.uuidString, ownerName: CKCurrentUserDefaultName)
    }

    static func profileID(of zoneID: CKRecordZone.ID) -> UUID? {
        guard zoneID.zoneName.hasPrefix(zonePrefix) else { return nil }
        return UUID(uuidString: String(zoneID.zoneName.dropFirst(zonePrefix.count)))
    }

    static func fill(_ record: CKRecord, with bookmark: SyncedBookmark) {
        record["parent"] = bookmark.parentID?.uuidString ?? ""
        record["position"] = bookmark.position as NSNumber
        record["title"] = bookmark.title
        record["url"] = bookmark.url?.absoluteString
    }

    static func bookmark(from record: CKRecord) -> SyncedBookmark? {
        guard record.recordType == bookmarkType else { return nil }
        let parent = (record["parent"] as? String).flatMap(UUID.init(uuidString:))
        let url = (record["url"] as? String).flatMap(URL.init(string:))
        return SyncedBookmark(parentID: parent, position: (record["position"] as? NSNumber)?.intValue ?? 0,
                              title: record["title"] as? String ?? "", url: url)
    }

    static func fill(_ record: CKRecord, with device: DeviceTabs) {
        record["name"] = device.name
        record["platform"] = device.platform
        record["tabs"] = (try? JSONEncoder().encode(device.tabs)).flatMap { String(data: $0, encoding: .utf8) }
        record["modified"] = device.modified as NSDate
    }

    static func deviceTabs(from record: CKRecord) -> DeviceTabs? {
        guard record.recordType == deviceTabsType, record.recordID.recordName.hasPrefix(devicePrefix) else {
            return nil
        }
        let tabs = (record["tabs"] as? String).flatMap { try? JSONDecoder().decode([SyncedTab].self, from: Data($0.utf8)) }
        return DeviceTabs(id: String(record.recordID.recordName.dropFirst(devicePrefix.count)),
                          name: record["name"] as? String ?? "Device", platform: record["platform"] as? String ?? "",
                          tabs: tabs ?? [], modified: record["modified"] as? Date ?? .distantPast)
    }

    /// A record keeps CloudKit's change tag, so saving it again replaces the copy in iCloud instead of conflicting.
    static func encodeSystemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
