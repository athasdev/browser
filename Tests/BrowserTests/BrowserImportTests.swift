import SQLite3
import XCTest
@testable import Browser

@MainActor
final class BrowserImportTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "BrowserImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Makes an SQLite database like another browser's, with only the tables and columns the importer reads.
    private func makeDatabase(_ name: String, in folder: URL? = nil, _ sql: String) throws -> URL {
        let url = (folder ?? self.folder).appending(path: name)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(connection, sql, nil, nil, &message)
        XCTAssertEqual(status, SQLITE_OK, message.map { String(cString: $0) } ?? "")
        return url
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Chromium

    func testChromiumBookmarksKeepTheirOrderAndFolders() throws {
        let json = """
        {"roots": {
          "bookmark_bar": {"type": "folder", "name": "Bookmarks bar", "children": [
            {"type": "url", "name": " Swift ", "url": "https://swift.org/"},
            {"type": "folder", "name": "Work", "children": [
              {"type": "url", "name": "Tracker", "url": "https://work.example/tracker"},
              {"type": "url", "name": "Bookmarklet", "url": "javascript:alert(1)"}
            ]}
          ]},
          "other": {"type": "folder", "children": [{"type": "url", "name": "Apple", "url": "https://apple.com"}]},
          "synced": {"type": "folder", "children": [{"type": "url", "name": "Settings", "url": "chrome://settings"}]}
        }, "version": 1}
        """

        let bookmarks = try BrowserImporter.chromiumBookmarks(from: Data(json.utf8))

        XCTAssertEqual(bookmarks, [
            ImportedBookmark(title: "Swift", url: URL(string: "https://swift.org/")!),
            ImportedBookmark(title: "Tracker", url: URL(string: "https://work.example/tracker")!, folders: ["Work"]),
            ImportedBookmark(title: "Apple", url: URL(string: "https://apple.com")!, folders: ["Other Bookmarks"]),
        ])
        XCTAssertThrowsError(try BrowserImporter.chromiumBookmarks(from: Data("{}".utf8)))
    }

    func testChromiumHistoryReadsRecentVisitsFromACopy() throws {
        let recent = BrowserImporter.chromiumTime(now.addingTimeInterval(-60))
        let old = BrowserImporter.chromiumTime(now.addingTimeInterval(-200 * 24 * 60 * 60))
        let database = try makeDatabase("History", """
            CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT);
            CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER);
            INSERT INTO urls VALUES (1, 'https://swift.org/', 'Swift'), (2, 'chrome://history', 'History');
            INSERT INTO visits VALUES (1, 1, \(recent)), (2, 1, \(old)), (3, 2, \(recent));
            """)

        let visits = try BrowserImporter.chromiumHistory(at: database, since: now.addingTimeInterval(-HistoryStore.maxAge))

        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?.url, URL(string: "https://swift.org/"))
        XCTAssertEqual(visits.first?.title, "Swift")
        XCTAssertEqual(visits.first?.date.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970 - 60, accuracy: 0.001)
        XCTAssertEqual(BrowserImporter.chromiumDate(0), Date(timeIntervalSince1970: -11_644_473_600))
        // The browser's own database is left as it was.
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
    }

    func testChromiumProfilesAreFoundWithTheirNames() throws {
        let chrome = folder.appending(path: "Chrome")
        for profile in ["Profile 2", "Default", "System Profile"] {
            try FileManager.default.createDirectory(at: chrome.appending(path: profile), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: chrome.appending(path: "Default/Bookmarks"))
        try Data().write(to: chrome.appending(path: "Profile 2/History"))
        try Data(#"{"profile": {"info_cache": {"Default": {"name": "Personal"}, "Profile 2": {"name": "Work"}}}}"#.utf8)
            .write(to: chrome.appending(path: "Local State"))

        let profiles = BrowserImporter.profiles(for: .chrome, in: chrome)

        XCTAssertEqual(profiles.map(\.name), ["Personal", "Work"])
        XCTAssertEqual(profiles.first?.folder.lastPathComponent, "Default")
        // Choosing a profile's own folder imports just that one.
        XCTAssertEqual(BrowserImporter.profiles(for: .edge, in: chrome.appending(path: "Default")).count, 1)
        XCTAssertTrue(BrowserImporter.profiles(for: .brave, in: folder.appending(path: "Missing")).isEmpty)
    }

    // MARK: Firefox

    func testFirefoxBookmarksAndHistoryComeFromPlaces() throws {
        let profile = folder.appending(path: "Firefox/Profiles/a1b2c3.default-release")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let recent = Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000_000)
        _ = try makeDatabase("places.sqlite", in: profile, """
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT);
            CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER,
                                        position INTEGER, title TEXT);
            CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER);
            INSERT INTO moz_places VALUES (1, 'https://mozilla.org/', 'Mozilla'), (2, 'https://swift.org/', NULL),
                                          (3, 'place:sort=8', NULL);
            INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, 'Toolbar'), (2, 1, 2, 1, 1, 'Swift'),
                                             (3, 1, 1, 1, 0, 'Mozilla'), (4, 1, 3, 1, 2, 'Recent');
            INSERT INTO moz_historyvisits VALUES (1, 2, \(recent));
            """)

        let profiles = BrowserImporter.profiles(for: .firefox, in: folder.appending(path: "Firefox"))
        XCTAssertEqual(profiles.map(\.name), ["default-release"])
        let data = try BrowserImporter.read(.firefox, from: profile, bookmarks: true, history: true,
                                            since: now.addingTimeInterval(-HistoryStore.maxAge))

        XCTAssertEqual(data.bookmarks.map(\.title), ["Mozilla", "Swift"])
        XCTAssertEqual(data.visits.map(\.url), [URL(string: "https://swift.org/")!])
        XCTAssertEqual(data.visits.first?.title, "")
    }

    func testFirefoxBookmarksKeepTheirFolders() throws {
        let database = try makeDatabase("places.sqlite", """
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT);
            CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER,
                                        position INTEGER, title TEXT);
            INSERT INTO moz_places VALUES (1, 'https://mozilla.org/', NULL), (2, 'https://swift.org/', NULL),
                                          (3, 'https://menu.example/', NULL);
            INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, ''), (2, 2, NULL, 1, 0, 'menu'),
                                             (3, 2, NULL, 1, 1, 'toolbar'), (4, 2, NULL, 1, 2, 'tags'),
                                             (5, 2, NULL, 3, 1, 'Dev'), (6, 1, 2, 5, 0, 'Swift'),
                                             (7, 1, 1, 3, 0, 'Mozilla'), (8, 1, 3, 2, 0, 'Menu'),
                                             (9, 2, NULL, 4, 0, 'tagged'), (10, 1, 2, 9, 0, 'Tagged Swift');
            """)

        XCTAssertEqual(try BrowserImporter.firefoxBookmarks(at: database), [
            ImportedBookmark(title: "Menu", url: URL(string: "https://menu.example/")!, folders: ["Bookmarks Menu"]),
            ImportedBookmark(title: "Mozilla", url: URL(string: "https://mozilla.org/")!),
            ImportedBookmark(title: "Swift", url: URL(string: "https://swift.org/")!, folders: ["Dev"]),
        ])
    }

    func testBookmarksHTMLKeepsFolders() {
        let html = """
        <DL><p>
          <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
          <DL><p>
            <DT><A HREF="https://swift.org/">Swift</A>
            <DT><H3>Work</H3>
            <DL><p>
              <DT><A HREF="https://work.example/">Work</A>
            </DL><p>
          </DL><p>
          <DT><H3>Other</H3>
          <DL><p><DT><A HREF="https://apple.com/">Apple</A></DL><p>
        </DL><p>
        """

        XCTAssertEqual(BrowserImporter.bookmarksHTML(html), [
            ImportedBookmark(title: "Swift", url: URL(string: "https://swift.org/")!),
            ImportedBookmark(title: "Work", url: URL(string: "https://work.example/")!, folders: ["Work"]),
            ImportedBookmark(title: "Apple", url: URL(string: "https://apple.com/")!, folders: ["Other"]),
        ])
    }

    // MARK: Safari

    func testSafariBookmarksLeaveOutTheReadingList() throws {
        let plist: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://apple.com/",
                     "URIDictionary": ["title": "Apple"]],
                ]],
                ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://later.example/"],
                ]],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)

        XCTAssertEqual(try BrowserImporter.safariBookmarks(from: data),
                       [ImportedBookmark(title: "Apple", url: URL(string: "https://apple.com/")!)])
    }

    func testSafariHistoryCountsFrom2001() throws {
        let database = try makeDatabase("History.db", """
            CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
            INSERT INTO history_items VALUES (1, 'https://apple.com/');
            INSERT INTO history_visits VALUES (1, 1, \(now.timeIntervalSinceReferenceDate - 30.5), 'Apple');
            """)

        let visits = try BrowserImporter.safariHistory(at: database, since: now.addingTimeInterval(-60))

        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?.date.timeIntervalSinceReferenceDate ?? 0,
                       now.timeIntervalSinceReferenceDate - 30.5, accuracy: 0.001)
    }

    func testSafarisExportedDataIsRead() throws {
        let export = folder.appending(path: "Safari Export")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try Data("""
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
          <DT><H3>Favorites</H3>
          <DL><p>
            <DT><A HREF="https://swift.org/?a=1&amp;b=2" ADD_DATE="1">Swift &amp; Friends</A>
            <DT><a href="https://example.com/" icon="data:x"><b>Caf&#233; &#x2014; Menu</b></a>
            <DT><A HREF="javascript:void(0)">Bookmarklet</A>
          </DL><p>
        </DL>
        """.utf8).write(to: export.appending(path: "Bookmarks.html"))
        let time = now.addingTimeInterval(-10).timeIntervalSince1970 * 1_000_000
        try Data("""
        {"metadata": {"browser_name": "Safari", "data_type": "history"},
         "history": [{"url": "https://apple.com/", "title": "Apple", "time_usec": \(Int64(time))},
                     {"url": "https://old.example/", "title": "Old", "time_usec": 1000}]}
        """.utf8).write(to: export.appending(path: "History.json"))
        try Data("Title,URL,Username,Password\n".utf8).write(to: export.appending(path: "Passwords.csv"))

        let data = try BrowserImporter.readExport(at: export, since: now.addingTimeInterval(-HistoryStore.maxAge))

        XCTAssertEqual(data.bookmarks, [
            ImportedBookmark(title: "Swift & Friends", url: URL(string: "https://swift.org/?a=1&b=2")!),
            ImportedBookmark(title: "Café — Menu", url: URL(string: "https://example.com/")!),
        ])
        XCTAssertEqual(data.visits.map(\.title), ["Apple"])
        XCTAssertEqual(try BrowserImporter.readExport(at: export.appending(path: "Bookmarks.html"),
                                                      since: .distantPast).bookmarks.count, 2)
    }

    func testPermissionErrorsAreRecognized() {
        XCTAssertTrue(BrowserImporter.isPermissionError(CocoaError(.fileReadNoPermission)))
        XCTAssertTrue(BrowserImporter.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
        ])))
        XCTAssertFalse(BrowserImporter.isPermissionError(CocoaError(.fileReadNoSuchFile)))
    }

    // MARK: Passwords

    func testPasswordCSVsFromEachBrowserAreRead() {
        let chrome = BrowserImporter.passwords(fromCSV: #"""
            name,url,username,password,note\#r
            example.com,https://example.com/login,alice,"pa,ss ""word""",\#r
            plain,http://plain.example/,bob,secret,\#r
            empty,https://empty.example/,carol,,\#r

            """#)
        XCTAssertEqual(chrome.passwords, [ImportedPassword(account: SavedPassword(origin: PasswordOrigin(host: "example.com")!,
                                                                                  username: "alice"),
                                                           password: "pa,ss \"word\"")])
        XCTAssertEqual(chrome.skipped, 2)

        let safari = BrowserImporter.passwords(fromCSV: """
            \u{FEFF}Title,URL,Username,Password,Notes,OTPAuth
            Example,https://accounts.example.com:8443/,alice@example.com,"multi
            line",note,
            Bare,example.org,,secret,,
            """)
        XCTAssertEqual(safari.passwords.map(\.account), [
            SavedPassword(origin: PasswordOrigin(host: "accounts.example.com", port: 8443)!, username: "alice@example.com"),
            SavedPassword(origin: PasswordOrigin(host: "example.org")!, username: ""),
        ])
        XCTAssertEqual(safari.passwords.first?.password, "multi\nline")

        let firefox = BrowserImporter.passwords(fromCSV: """
            "url","username","password","httpRealm","formActionOrigin","guid","timeCreated"
            "https://mozilla.org","fox","firefox","","https://mozilla.org","{1}","1"
            """)
        XCTAssertEqual(firefox.passwords.map(\.password), ["firefox"])

        XCTAssertEqual(BrowserImporter.passwords(fromCSV: "a,b\n1,2\n"), PasswordCSV(skipped: 1))
        XCTAssertEqual(BrowserImporter.passwords(fromCSV: ""), PasswordCSV())
    }

    func testImportedPasswordsKeepPasswordsAlreadySaved() throws {
        let passwords = PasswordManager(storage: InMemoryPasswordStorage())
        let example = SavedPassword(origin: PasswordOrigin(host: "example.com")!, username: "alice")
        try passwords.save(XCTUnwrap(PasswordCapture(body: ["type": "submit", "username": "alice", "password": "mine"],
                                                     isMainFrame: true, origin: example.origin)))
        let other = SavedPassword(origin: PasswordOrigin(host: "other.example")!, username: "bob")

        let result = passwords.importPasswords([(example, "imported"), (other, "new"), (other, "duplicate")])

        XCTAssertEqual(result, PasswordManager.ImportResult(added: 1, alreadySaved: 2, failed: 0))
        XCTAssertEqual(passwords.password(for: example), "mine")
        XCTAssertEqual(passwords.password(for: other), "new")
    }

    // MARK: Adding

    func testImportedBookmarksAndHistorySkipWhatsAlreadyThere() async {
        let bookmarks = BookmarkStore(defaults: nil)
        bookmarks.add(title: "Swift", url: URL(string: "https://swift.org")!)
        let added = bookmarks.add(contentsOf: [
            Bookmark(title: "Swift again", url: URL(string: "https://swift.org")!),
            Bookmark(title: "Apple", url: URL(string: "https://apple.com")!),
            Bookmark(title: "Apple again", url: URL(string: "https://apple.com")!),
        ])
        XCTAssertEqual(added, 1)
        XCTAssertEqual(bookmarks.bookmarks.map(\.title), ["Swift", "Apple"])

        let history = HistoryStore(file: nil)
        let visitDate = now.addingTimeInterval(-60)
        history.recordVisit(to: URL(string: "https://swift.org")!, title: "Swift", at: visitDate)
        let imported = [
            HistoryVisit(url: URL(string: "https://swift.org")!, title: "Swift", date: visitDate.addingTimeInterval(0.2)),
            HistoryVisit(url: URL(string: "https://apple.com")!, title: "Apple", date: now.addingTimeInterval(-120)),
            HistoryVisit(url: URL(string: "https://old.example")!, title: "Old", date: now.addingTimeInterval(-100 * 24 * 60 * 60)),
        ]

        let addedVisits = await history.importVisits(imported, now: now)

        XCTAssertEqual(addedVisits, 1)
        XCTAssertEqual(history.visits.map(\.title), ["Apple", "Swift"])
    }
}
