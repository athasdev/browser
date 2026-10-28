import XCTest
@testable import Browser

@MainActor
final class BookmarkStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "dev.athas.browser.tests.bookmarks"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testToggleAddsThenRemovesAPage() {
        let store = BookmarkStore(defaults: makeDefaults())
        let url = URL(string: "https://swift.org")!

        store.toggle(title: "Swift", url: url)
        XCTAssertTrue(store.isBookmarked(url))

        store.toggle(title: "Swift", url: url)
        XCTAssertFalse(store.isBookmarked(url))
    }

    func testBookmarksPersistAcrossStores() {
        let defaults = makeDefaults()
        let store = BookmarkStore(defaults: defaults)
        store.add(title: "Swift", url: URL(string: "https://swift.org")!)
        store.add(title: "", url: URL(string: "https://www.apple.com")!)
        store.rename(store.bookmarks[0].id, to: "  Swift.org  ")

        let reloaded = BookmarkStore(defaults: defaults)

        XCTAssertEqual(reloaded.bookmarks.map(\.displayTitle), ["Swift.org", "apple.com"])
    }

    func testMoveReordersBookmarks() {
        let store = BookmarkStore(defaults: makeDefaults())
        for site in ["a.com", "b.com", "c.com"] {
            store.add(title: site, url: URL(string: "https://\(site)")!)
        }

        store.move(store.bookmarks[0].id, toPositionOf: store.bookmarks[2].id)
        XCTAssertEqual(store.bookmarks.map(\.title), ["b.com", "c.com", "a.com"])

        store.move(store.bookmarks[2].id, toPositionOf: store.bookmarks[0].id)
        XCTAssertEqual(store.bookmarks.map(\.title), ["a.com", "b.com", "c.com"])
    }

    func testBookmarksMoveBetweenFoldersKeepingTheirIDs() {
        let store = BookmarkStore(defaults: makeDefaults())
        let swift = store.add(title: "Swift", url: URL(string: "https://swift.org")!)
        let work = store.addFolder(titled: " Work ")
        let tools = store.addFolder(titled: "Tools", in: work)
        let apple = store.add(title: "Apple", url: URL(string: "https://apple.com")!, in: tools)

        XCTAssertEqual(store.folder(withID: work)?.title, "Work")
        XCTAssertEqual(store.root.map(\.id), [swift, work])
        XCTAssertEqual(store.location(of: apple)?.folderID, tools)
        XCTAssertEqual(store.folders.map(\.depth), [0, 1])

        XCTAssertTrue(store.move(swift, to: tools, at: 0))
        XCTAssertEqual(store.children(of: tools).map(\.id), [swift, apple])
        XCTAssertEqual(store.root.map(\.id), [work])

        // Moving down within a folder counts the moved bookmark's old place.
        XCTAssertTrue(store.move(swift, to: tools, at: 2))
        XCTAssertEqual(store.children(of: tools).map(\.id), [apple, swift])

        XCTAssertTrue(store.move(tools, to: nil, at: 0))
        XCTAssertEqual(store.root.map(\.id), [tools, work])
        XCTAssertEqual(store.bookmarks.map(\.title), ["Apple", "Swift"])
    }

    func testFoldersCantMoveIntoThemselves() {
        let store = BookmarkStore(defaults: makeDefaults())
        let outer = store.addFolder(titled: "Outer")
        let inner = store.addFolder(titled: "Inner", in: outer)

        XCTAssertFalse(store.move(outer, to: outer))
        XCTAssertFalse(store.move(outer, to: inner))
        XCTAssertTrue(store.isNode(inner, within: outer))
        XCTAssertFalse(store.isNode(outer, within: inner))
        XCTAssertEqual(store.location(of: inner)?.folderID, outer)
    }

    func testDeletingAFolderCanKeepItsContents() {
        let store = BookmarkStore(defaults: makeDefaults())
        store.add(title: "First", url: URL(string: "https://first.example")!)
        let folder = store.addFolder(titled: "Folder")
        store.add(title: "Inside", url: URL(string: "https://inside.example")!, in: folder)
        store.addFolder(titled: "Nested", in: folder)
        store.add(title: "Last", url: URL(string: "https://last.example")!)

        XCTAssertEqual(store.delete([folder]), .delete([folder]))
        store.removeFolder(folder, keepingContents: true)

        XCTAssertNil(store.node(withID: folder))
        XCTAssertEqual(store.root.map(\.displayTitle), ["First", "Inside", "Nested", "Last"])

        let other = store.addFolder(titled: "Other")
        store.add(title: "Gone", url: URL(string: "https://gone.example")!, in: other)
        store.removeFolder(other, keepingContents: false)

        XCTAssertFalse(store.isBookmarked(URL(string: "https://gone.example")!))
        XCTAssertEqual(store.bookmarks.map(\.title), ["First", "Inside", "Last"])
    }

    func testEmptyFoldersAndBookmarksDeleteWithoutAsking() {
        let store = BookmarkStore(defaults: makeDefaults())
        let folder = store.addFolder(titled: "Empty")
        let bookmark = store.add(title: "Swift", url: URL(string: "https://swift.org")!)

        XCTAssertNil(store.delete([folder, bookmark]))
        XCTAssertTrue(store.root.isEmpty)
    }

    func testFlatBookmarksSavedBeforeFoldersLoadAsTheBar() throws {
        let defaults = makeDefaults()
        let saved = [Bookmark(title: "Swift", url: URL(string: "https://swift.org")!),
                     Bookmark(title: "", url: URL(string: "https://apple.com")!)]
        defaults.set(try JSONEncoder().encode(saved), forKey: "profile.test.bookmarks")

        let store = BookmarkStore(defaults: defaults, keyPrefix: "profile.test.")
        XCTAssertEqual(store.root, saved.map(BookmarkNode.bookmark))

        let folder = store.addFolder(titled: "Later")
        store.move(saved[1].id, to: folder)
        let reloaded = BookmarkStore(defaults: defaults, keyPrefix: "profile.test.")

        XCTAssertEqual(reloaded.root, store.root)
        XCTAssertEqual(reloaded.children(of: folder).map(\.id), [saved[1].id])
    }

    func testEditingABookmarkChangesItsNameAndAddress() {
        let store = BookmarkStore(defaults: makeDefaults())
        let id = store.add(title: "Swift", url: URL(string: "https://swift.org")!)

        store.update(id, title: " Swift Forums ", url: URL(string: "https://forums.swift.org")!)

        XCTAssertEqual(store.node(withID: id)?.bookmark?.title, "Swift Forums")
        XCTAssertTrue(store.isBookmarked(URL(string: "https://forums.swift.org")!))
        XCTAssertEqual(store.add(title: "Again", url: URL(string: "https://forums.swift.org")!), id)
    }

    func testImportedBookmarksGoIntoTheirFolders() {
        let store = BookmarkStore(defaults: makeDefaults())
        let work = store.addFolder(titled: "Work")

        let added = store.add(contentsOf: [
            ImportedBookmark(title: "Bar", url: URL(string: "https://bar.example")!),
            ImportedBookmark(title: "Tracker", url: URL(string: "https://tracker.example")!, folders: ["Work"]),
            ImportedBookmark(title: "Docs", url: URL(string: "https://docs.example")!, folders: ["Work", "Docs"]),
            ImportedBookmark(title: "Again", url: URL(string: "https://bar.example")!, folders: ["Elsewhere"]),
        ])

        XCTAssertEqual(added, 3)
        XCTAssertEqual(store.root.map(\.displayTitle), ["Work", "Bar"])
        XCTAssertEqual(store.children(of: work).map(\.displayTitle), ["Tracker", "Docs"])
        XCTAssertEqual(store.folders.map(\.folder.title), ["Work", "Docs"])
    }

    func testTypedBookmarkAddresses() {
        XCTAssertEqual(BookmarkStore.address(from: " swift.org "), URL(string: "https://swift.org"))
        XCTAssertEqual(BookmarkStore.address(from: "http://localhost:8080/a"), URL(string: "http://localhost:8080/a"))
        XCTAssertNil(BookmarkStore.address(from: "not an address"))
        XCTAssertNil(BookmarkStore.address(from: "swift"))
    }

    func testBookmarksBarVisibility() {
        XCTAssertTrue(BookmarksBarVisibility.always.isVisible(onNewTab: false))
        XCTAssertTrue(BookmarksBarVisibility.newTabOnly.isVisible(onNewTab: true))
        XCTAssertFalse(BookmarksBarVisibility.newTabOnly.isVisible(onNewTab: false))
        XCTAssertFalse(BookmarksBarVisibility.never.isVisible(onNewTab: true))
    }

    func testTabLayoutTogglesAndSizesTheWindowControlsRow() {
        XCTAssertEqual(TabLayout.horizontal.toggled, .vertical)
        XCTAssertEqual(TabLayout.vertical.toggled, .horizontal)
        XCTAssertEqual(BrowserChrome.titlebarHeight(for: .horizontal), BrowserChrome.tabRowHeight)
        XCTAssertEqual(BrowserChrome.titlebarHeight(for: .vertical), BrowserChrome.navigationBarHeight)
    }
}
