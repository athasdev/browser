import AppKit
import Foundation
import SQLite3

/// A browser whose bookmarks, history, and exported passwords can be imported.
enum ImportSource: String, CaseIterable, Identifiable, Sendable {
    case safari
    case chrome
    case arc
    case brave
    case edge
    case firefox

    enum Kind: Sendable {
        case safari
        case chromium
        case firefox
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .arc: "Arc"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .firefox: "Firefox"
        }
    }

    var shortTitle: String {
        switch self {
        case .chrome: "Chrome"
        case .edge: "Edge"
        default: title
        }
    }

    var kind: Kind {
        switch self {
        case .safari: .safari
        case .chrome, .arc, .brave, .edge: .chromium
        case .firefox: .firefox
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .arc: "company.thebrowser.Browser"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .firefox: "org.mozilla.firefox"
        }
    }

    /// Where the browser keeps its profiles, in the user's home folder.
    var dataFolderPath: String {
        switch self {
        case .safari: "Library/Safari"
        case .chrome: "Library/Application Support/Google/Chrome"
        case .arc: "Library/Application Support/Arc/User Data"
        case .brave: "Library/Application Support/BraveSoftware/Brave-Browser"
        case .edge: "Library/Application Support/Microsoft Edge"
        case .firefox: "Library/Application Support/Firefox"
        }
    }

    var dataFolder: URL {
        BrowserImporter.homeDirectory.appending(path: dataFolderPath, directoryHint: .isDirectory)
    }

    /// Where the browser exports its passwords to a CSV file.
    var passwordExportHint: String {
        switch self {
        case .safari: "In Safari, choose File ▸ Export ▸ Passwords, or in the Passwords app, File ▸ Export All "
            + "Passwords."
        case .chrome: "In Chrome, open chrome://password-manager/settings and choose Download File under Export "
            + "Passwords."
        case .arc: "In Arc, open arc://password-manager/settings and choose Download File under Export Passwords."
        case .brave: "In Brave, open brave://password-manager/settings and choose Download File under Export "
            + "Passwords."
        case .edge: "In Edge, open edge://wallet/passwords, choose More ▸ Export Passwords."
        case .firefox: "In Firefox, open about:logins, click ⋯ and choose Export Passwords."
        }
    }

    @MainActor
    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    @MainActor
    var isInstalled: Bool {
        applicationURL != nil
    }
}

/// One of a browser's own profiles, such as Chrome's "Default" or "Profile 1".
struct SourceProfile: Hashable, Sendable {
    let name: String
    let folder: URL
}

struct ImportedVisit: Equatable, Sendable {
    let url: URL
    let title: String
    let date: Date
}

struct ImportedData: Equatable, Sendable {
    var bookmarks: [ImportedBookmark] = []
    var visits: [ImportedVisit] = []
}

struct ImportedPassword: Equatable, Sendable {
    let account: SavedPassword
    let password: String
}

/// The sign-ins in a passwords CSV file, without those that can't be saved: for sites without HTTPS, or without
/// a password.
struct PasswordCSV: Equatable, Sendable {
    var passwords: [ImportedPassword] = []
    var skipped = 0
}

enum ImportError: LocalizedError, Equatable {
    /// Safari's folder can only be read with Full Disk Access.
    case needsFullDiskAccess
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .needsFullDiskAccess: "Browser doesn’t have access to Safari’s data."
        case .unreadable(let name): "Browser couldn’t read “\(name)”."
        }
    }
}

/// Reads other browsers' bookmarks and history from their own files, which it never changes, and the passwords CSV
/// files browsers export. Other browsers' saved passwords are encrypted for them, so they're never read directly.
enum BrowserImporter {
    /// The user's home folder. In the sandbox the home directory is the app's container, and an open panel pointed
    /// there would show the wrong Library folder.
    static var homeDirectory: URL {
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// A web page's address, leaving out others, like `javascript:` bookmarklets and browsers' own pages.
    static func webURL(_ string: String?) -> URL? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: string),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host()?.isEmpty == false else {
            return nil
        }
        return url
    }

    private static func cleanTitle(_ title: String?) -> String {
        (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Profiles

    /// The browser's profiles in the folder the user gave access to: its data folder, or one profile's folder.
    static func profiles(for source: ImportSource, in folder: URL) -> [SourceProfile] {
        let fileManager = FileManager.default
        let has = { (folder: URL, names: [String]) in
            names.contains { fileManager.fileExists(atPath: folder.appending(path: $0).path) }
        }
        let subfolders = { (folder: URL) in
            ((try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        switch source.kind {
        case .safari:
            // Without Full Disk Access the folder can't even be listed, so reading it tells.
            return [SourceProfile(name: source.title, folder: folder)]
        case .chromium:
            let files = ["Bookmarks", "History"]
            if has(folder, files) { return [SourceProfile(name: folder.lastPathComponent, folder: folder)] }
            let names = chromiumProfileNames(localState: try? Data(contentsOf: folder.appending(path: "Local State")))
            // "Default" is the first profile, before "Profile 1".
            return subfolders(folder)
                .filter { has($0, files) }
                .sorted { ($0.lastPathComponent == "Default" ? 0 : 1) < ($1.lastPathComponent == "Default" ? 0 : 1) }
                .map { SourceProfile(name: names[$0.lastPathComponent] ?? $0.lastPathComponent, folder: $0) }
        case .firefox:
            if has(folder, ["places.sqlite"]) { return [SourceProfile(name: folder.lastPathComponent, folder: folder)] }
            return ([folder] + subfolders(folder).filter { $0.lastPathComponent == "Profiles" })
                .flatMap(subfolders)
                .filter { has($0, ["places.sqlite"]) }
                .map { profile in
                    // Folders are named like "x1y2z3.default-release".
                    let name = profile.lastPathComponent
                    return SourceProfile(name: name.split(separator: ".", maxSplits: 1).last.map(String.init) ?? name,
                                         folder: profile)
                }
        }
    }

    /// The names the user gave Chromium profiles, by folder, from the browser's "Local State" file.
    static func chromiumProfileNames(localState: Data?) -> [String: String] {
        guard let localState,
              let json = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [:] }
        return cache.compactMapValues { ($0 as? [String: Any])?["name"] as? String }
    }

    // MARK: Reading

    /// Reads a profile's bookmarks and its history since `since`.
    static func read(_ source: ImportSource, from profile: URL, bookmarks: Bool, history: Bool,
                     since: Date) throws -> ImportedData {
        var data = ImportedData()
        let exists = { (name: String) in FileManager.default.fileExists(atPath: profile.appending(path: name).path) }
        switch source.kind {
        case .chromium:
            if bookmarks, exists("Bookmarks") {
                data.bookmarks = try chromiumBookmarks(from: Data(contentsOf: profile.appending(path: "Bookmarks")))
            }
            if history, exists("History") {
                data.visits = try chromiumHistory(at: profile.appending(path: "History"), since: since)
            }
        case .firefox:
            let places = profile.appending(path: "places.sqlite")
            if bookmarks { data.bookmarks = try firefoxBookmarks(at: places) }
            if history { data.visits = try firefoxHistory(at: places, since: since) }
        case .safari:
            do {
                if bookmarks {
                    let file = profile.appending(path: "Bookmarks.plist")
                    data.bookmarks = try safariBookmarks(from: Data(contentsOf: file))
                }
                if history { data.visits = try safariHistory(at: profile.appending(path: "History.db"), since: since) }
            } catch let error where isPermissionError(error) {
                throw ImportError.needsFullDiskAccess
            }
        }
        return data
    }

    /// Reads what a browser exported: a folder like Safari's File ▸ Export Browsing Data to File makes, once it's
    /// unzipped, a bookmarks HTML file any browser exports, or Safari's history JSON file.
    static func readExport(at url: URL, since: Date) throws -> ImportedData {
        var data = ImportedData()
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let files = isFolder
            ? (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            : [url]
        for file in files {
            switch file.pathExtension.lowercased() {
            case "html", "htm":
                let text = try String(contentsOf: file, encoding: .utf8)
                data.bookmarks += bookmarksHTML(text)
            case "json":
                data.visits += try safariHistoryJSON(from: Data(contentsOf: file)).filter { $0.date >= since }
            default:
                continue
            }
        }
        return data
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        let permissionCodes = [Int(EPERM), Int(EACCES)]
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, permissionCodes.contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }

    // MARK: Chromium

    /// Chrome, Arc, Brave, and Edge keep bookmarks in a JSON file, in folders: the bookmarks bar's are kept on the
    /// bar, and the other and mobile bookmarks in folders of their own after them.
    static func chromiumBookmarks(from data: Data) throws -> [ImportedBookmark] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { throw ImportError.unreadable("Bookmarks") }
        var bookmarks: [ImportedBookmark] = []
        func collect(_ node: [String: Any], in folders: [String]) {
            switch node["type"] as? String {
            case "url":
                if let url = webURL(node["url"] as? String) {
                    bookmarks.append(ImportedBookmark(title: cleanTitle(node["name"] as? String), url: url,
                                                      folders: folders))
                }
            case "folder":
                let path = folders + [folderTitle(node["name"] as? String)]
                for child in node["children"] as? [[String: Any]] ?? [] {
                    collect(child, in: path)
                }
            default:
                break
            }
        }
        let rootFolders: [(String, String?)] = [("bookmark_bar", nil), ("other", "Other Bookmarks"),
                                                ("synced", "Mobile Bookmarks")]
        for (name, fallbackTitle) in rootFolders {
            guard let root = roots[name] as? [String: Any] else { continue }
            let folders = fallbackTitle.map { [folderTitle(root["name"] as? String, fallback: $0)] } ?? []
            for child in root["children"] as? [[String: Any]] ?? [] {
                collect(child, in: folders)
            }
        }
        return bookmarks
    }

    private static func folderTitle(_ title: String?, fallback: String = "Untitled Folder") -> String {
        let title = cleanTitle(title)
        return title.isEmpty ? fallback : title
    }

    /// Chromium counts time in microseconds since 1601.
    static func chromiumDate(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
    }

    static func chromiumTime(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }

    static func chromiumHistory(at database: URL, since: Date) throws -> [ImportedVisit] {
        try SQLiteSnapshot.rows(in: database, sql: """
            SELECT urls.url, urls.title, visits.visit_time FROM visits JOIN urls ON urls.id = visits.url
            WHERE visits.visit_time >= ? ORDER BY visits.visit_time
            """, arguments: [chromiumTime(since)]) { row in
            webURL(row.text(0)).map { ImportedVisit(url: $0, title: cleanTitle(row.text(1)),
                                                    date: chromiumDate(row.int(2))) }
        }
    }

    // MARK: Firefox

    /// Firefox keeps bookmarks in a tree of folders: the toolbar's go on the bookmarks bar, and the menu's, other,
    /// and mobile bookmarks in folders of their own. Tags are folders too, which are left out.
    static func firefoxBookmarks(at database: URL) throws -> [ImportedBookmark] {
        struct Item {
            let id: Int64
            let isFolder: Bool
            let parent: Int64
            let title: String
            let url: URL?
        }
        let items = try SQLiteSnapshot.rows(in: database, sql: """
            SELECT moz_bookmarks.id, moz_bookmarks.type, moz_bookmarks.parent, moz_bookmarks.title, moz_places.url
            FROM moz_bookmarks LEFT JOIN moz_places ON moz_places.id = moz_bookmarks.fk
            WHERE moz_bookmarks.type IN (1, 2) ORDER BY moz_bookmarks.parent, moz_bookmarks.position
            """) { row in
            Item(id: row.int(0), isFolder: row.int(1) == 2, parent: row.int(2), title: cleanTitle(row.text(3)),
                 url: webURL(row.text(4)))
        }
        let folderIDs = Set(items.filter(\.isFolder).map(\.id))
        let children = Dictionary(grouping: items, by: \.parent)
        var bookmarks: [ImportedBookmark] = []
        func collect(_ parent: Int64, in folders: [String]) {
            for item in children[parent] ?? [] {
                if item.isFolder {
                    collect(item.id, in: folders + [folderTitle(item.title)])
                } else if let url = item.url {
                    bookmarks.append(ImportedBookmark(title: item.title, url: url, folders: folders))
                }
            }
        }
        // The root folder holds Firefox's own folders, named by their role.
        for root in items where root.isFolder && !folderIDs.contains(root.parent) {
            for item in children[root.id] ?? [] {
                guard item.isFolder else {
                    if let url = item.url { bookmarks.append(ImportedBookmark(title: item.title, url: url)) }
                    continue
                }
                switch item.title.lowercased() {
                case "toolbar", "bookmarks toolbar": collect(item.id, in: [])
                case "tags": continue
                case "menu", "bookmarks menu": collect(item.id, in: ["Bookmarks Menu"])
                case "unfiled", "other bookmarks": collect(item.id, in: ["Other Bookmarks"])
                case "mobile", "mobile bookmarks": collect(item.id, in: ["Mobile Bookmarks"])
                default: collect(item.id, in: [folderTitle(item.title)])
                }
            }
        }
        return bookmarks
    }

    /// Firefox counts time in microseconds since 1970.
    static func firefoxHistory(at database: URL, since: Date) throws -> [ImportedVisit] {
        try SQLiteSnapshot.rows(in: database, sql: """
            SELECT moz_places.url, moz_places.title, moz_historyvisits.visit_date FROM moz_historyvisits
            JOIN moz_places ON moz_places.id = moz_historyvisits.place_id
            WHERE moz_historyvisits.visit_date >= ? ORDER BY moz_historyvisits.visit_date
            """, arguments: [Int64(since.timeIntervalSince1970 * 1_000_000)]) { row in
            webURL(row.text(0)).map { ImportedVisit(url: $0, title: cleanTitle(row.text(1)),
                                                    date: Date(timeIntervalSince1970: Double(row.int(2)) / 1_000_000)) }
        }
    }

    // MARK: Safari

    /// Safari keeps bookmarks in a property list of nested lists. The favorites go on the bookmarks bar, the bookmarks
    /// menu's in a folder of its own, and the Reading List is left out.
    static func safariBookmarks(from data: Data) throws -> [ImportedBookmark] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImportError.unreadable("Bookmarks.plist")
        }
        var bookmarks: [ImportedBookmark] = []
        func collect(_ node: [String: Any], in folders: [String]) {
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                if let url = webURL(node["URLString"] as? String) {
                    let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                    bookmarks.append(ImportedBookmark(title: cleanTitle(title), url: url, folders: folders))
                }
            case "WebBookmarkTypeList":
                for child in node["Children"] as? [[String: Any]] ?? [] {
                    collect(child, in: folders + [folderTitle(node["Title"] as? String)])
                }
            default:
                break
            }
        }
        for child in root["Children"] as? [[String: Any]] ?? [] {
            switch child["Title"] as? String {
            case "com.apple.ReadingList":
                continue
            case "BookmarksBar":
                for bookmark in child["Children"] as? [[String: Any]] ?? [] {
                    collect(bookmark, in: [])
                }
            case "BookmarksMenu":
                for bookmark in child["Children"] as? [[String: Any]] ?? [] {
                    collect(bookmark, in: ["Bookmarks Menu"])
                }
            default:
                collect(child, in: [])
            }
        }
        return bookmarks
    }

    /// Safari counts time in seconds since 2001.
    static func safariHistory(at database: URL, since: Date) throws -> [ImportedVisit] {
        try SQLiteSnapshot.rows(in: database, sql: """
            SELECT history_items.url, history_visits.title, history_visits.visit_time FROM history_visits
            JOIN history_items ON history_items.id = history_visits.history_item
            WHERE history_visits.visit_time >= ? ORDER BY history_visits.visit_time
            """, arguments: [Int64(since.timeIntervalSinceReferenceDate)]) { row in
            webURL(row.text(0)).map { ImportedVisit(url: $0, title: cleanTitle(row.text(1)),
                                                    date: Date(timeIntervalSinceReferenceDate: row.double(2))) }
        }
    }

    /// The history Safari exports, with each visit's time in microseconds since 1970.
    static func safariHistoryJSON(from data: Data) throws -> [ImportedVisit] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let history = json["history"] as? [[String: Any]] else { return [] }
        return history.compactMap { item in
            guard let url = webURL(item["url"] as? String),
                  let time = (item["time_usec"] as? NSNumber)?.doubleValue else { return nil }
            return ImportedVisit(url: url, title: cleanTitle(item["title"] as? String),
                                 date: Date(timeIntervalSince1970: time / 1_000_000))
        }
        .sorted { $0.date < $1.date }
    }

    // MARK: Exported files

    /// The bookmarks in the HTML file every browser exports bookmarks to, in their folders. The toolbar's folder, and
    /// Safari's favorites, are the bookmarks bar.
    static func bookmarksHTML(_ html: String) -> [ImportedBookmark] {
        let pattern = #"<h3([^>]*)>(.*?)</h3>|<a\s[^>]*?href\s*=\s*"([^"]*)"[^>]*>(.*?)</a>|<dl[^>]*>|</dl>"#
        guard let tag = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }
        let text = html as NSString
        let plain = { (range: NSRange) in
            decodeEntities(text.substring(with: range).replacingOccurrences(of: "<[^>]+>", with: "",
                                                                             options: .regularExpression))
        }
        var bookmarks: [ImportedBookmark] = []
        // Each list is a folder's contents. `nil` marks the bar, whose bookmarks have no folder.
        var folders: [String?] = []
        var nextFolder: String??
        for match in tag.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let token = text.substring(with: match.range).lowercased()
            if match.range(at: 2).location != NSNotFound {
                let attributes = text.substring(with: match.range(at: 1)).lowercased()
                let title = cleanTitle(plain(match.range(at: 2)))
                let isBar = attributes.contains("personal_toolbar_folder")
                    || (folders.count <= 1 && ["favorites", "favourites", "favorites bar"].contains(title.lowercased()))
                nextFolder = .some(isBar ? nil : folderTitle(title))
            } else if match.range(at: 3).location != NSNotFound {
                guard let url = webURL(decodeEntities(text.substring(with: match.range(at: 3)))) else { continue }
                bookmarks.append(ImportedBookmark(title: cleanTitle(plain(match.range(at: 4))), url: url,
                                                  folders: folders.compactMap { $0 }))
            } else if token.hasPrefix("</") {
                if !folders.isEmpty { folders.removeLast() }
            } else if folders.isEmpty && nextFolder == nil {
                // The file's outermost list holds the top-level bookmarks.
                folders.append(nil)
            } else {
                folders.append(nextFolder ?? nil)
                nextFolder = nil
            }
        }
        return bookmarks
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = ["&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, character) in named {
            result = result.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        if let numeric = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let current = result as NSString
            for match in numeric.matches(in: result, range: NSRange(location: 0, length: current.length)).reversed() {
                let isHex = match.range(at: 1).length > 0
                guard let value = UInt32(current.substring(with: match.range(at: 2)), radix: isHex ? 16 : 10),
                      let scalar = Unicode.Scalar(value) else { continue }
                result = (result as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
            }
        }
        // Last, so "&amp;lt;" stays "&lt;".
        return result.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }

    /// Reads the passwords CSV that Chrome, Arc, Brave, Edge, Firefox, Safari, and the Passwords app export, finding
    /// the columns by their headers.
    static func passwords(fromCSV text: String) -> PasswordCSV {
        var rows = csvRows(text)
        guard !rows.isEmpty else { return PasswordCSV() }
        let header = rows.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let column = { (names: [String]) in header.firstIndex { names.contains($0) } }
        guard let urlColumn = column(["url", "login_uri", "website", "origin", "web site"]),
              let passwordColumn = column(["password", "login_password"]) else {
            return PasswordCSV(skipped: rows.count)
        }
        let usernameColumn = column(["username", "login_username", "user name", "login", "email"])

        var result = PasswordCSV()
        for row in rows {
            let field = { (index: Int?) in index.flatMap { row.indices.contains($0) ? row[$0] : nil } ?? "" }
            var address = field(urlColumn).trimmingCharacters(in: .whitespaces)
            if !address.isEmpty, !address.contains("://") { address = "https://" + address }
            let password = field(passwordColumn)
            guard let origin = PasswordOrigin(url: URL(string: address)), !password.isEmpty else {
                result.skipped += 1
                continue
            }
            let username = field(usernameColumn).trimmingCharacters(in: .whitespacesAndNewlines)
            result.passwords.append(ImportedPassword(account: SavedPassword(origin: origin, username: username),
                                                     password: password))
        }
        return result
    }

    /// Splits CSV text into rows of fields, with quoted fields that can hold commas, quotes, and line breaks.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        let characters = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if isQuoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        isQuoted = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"": isQuoted = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n", "\r", "\r\n":
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                default: field.append(character)
                }
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { $0 != [""] }
    }
}

/// Reads another browser's SQLite database from a copy, since the browser may have it open and locked. The copy
/// takes the write-ahead log along, which holds the latest changes until the browser writes them to the database.
enum SQLiteSnapshot {
    struct Row {
        fileprivate let statement: OpaquePointer

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        func int(_ column: Int32) -> Int64 {
            sqlite3_column_int64(statement, column)
        }

        func double(_ column: Int32) -> Double {
            sqlite3_column_double(statement, column)
        }
    }

    static func rows<Result>(in database: URL, sql: String, arguments: [Int64] = [],
                             read: (Row) -> Result?) throws -> [Result] {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appending(path: "BrowserImport-\(UUID().uuidString)")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        let copy = folder.appending(path: database.lastPathComponent)
        try fileManager.copyItem(at: database, to: copy)
        try? fileManager.copyItem(at: URL(fileURLWithPath: database.path + "-wal"),
                                  to: URL(fileURLWithPath: copy.path + "-wal"))

        var connection: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            throw ImportError.unreadable(database.lastPathComponent)
        }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ImportError.unreadable(database.lastPathComponent)
        }
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), argument)
        }
        var results: [Result] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let result = read(Row(statement: statement)) { results.append(result) }
        }
        return results
    }
}
