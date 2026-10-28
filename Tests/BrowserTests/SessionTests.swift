import XCTest
@testable import Browser

@MainActor
final class SessionTests: XCTestCase {
    private func page(titled title: String) -> URL {
        URL(string: "data:text/html,<title>\(title)</title>")!
    }

    private func makeFile() -> StoreFile {
        StoreFile(url: FileManager.default.temporaryDirectory
            .appending(path: "BrowserTests-\(UUID().uuidString)")
            .appending(path: "Session.plist"))
    }

    private func window(_ titles: [String], selected: Int = 0) -> WindowSession {
        WindowSession(tabs: titles.map { TabSession(url: page(titled: $0), title: $0, interactionState: nil) },
                      selectedIndex: selected)
    }

    func testSnapshotRoundTripsThroughAPropertyList() throws {
        let snapshot = SessionSnapshot(
            windows: [WindowSession(tabs: [
                TabSession(url: URL(string: "https://swift.org")!, title: "Swift", interactionState: Data([1, 2, 3])),
                TabSession(url: nil, title: "", interactionState: nil),
            ], selectedIndex: 1)],
            closedWindows: [window(["Closed"])])

        let data = try PropertyListEncoder.binary.encode(snapshot)

        XCTAssertEqual(try PropertyListDecoder().decode(SessionSnapshot.self, from: data), snapshot)
    }

    func testPinnedTabsAreSavedAndRestoredFirst() throws {
        let saved = WindowSession(tabs: [
            TabSession(url: page(titled: "Normal"), title: "Normal", interactionState: nil),
            TabSession(url: page(titled: "Mail"), title: "Mail", interactionState: nil, isPinned: true),
            TabSession(url: nil, title: "", interactionState: nil, isPinned: true),
        ], selectedIndex: 0)
        let data = try PropertyListEncoder.binary.encode(SessionSnapshot(windows: [saved]))
        let decoded = try PropertyListDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(decoded.windows, [saved])

        let browser = BrowserModel()
        browser.restoreSession(saved)

        XCTAssertEqual(browser.tabs.map(\.title), ["Mail", "New Tab", "Normal"])
        XCTAssertEqual(browser.tabs.map(\.isPinned), [true, true, false])
        XCTAssertEqual(browser.activeTab?.title, "Normal")
        let resaved = browser.windowSession()
        XCTAssertEqual(resaved.tabs.map(\.isPinned), [true, true, false])
        XCTAssertEqual(resaved.selectedIndex, 2)
    }

    func testTabsSavedBeforePinningAreUnpinned() throws {
        struct OldTab: Codable {
            var url: URL?
            var title: String
        }
        let data = try PropertyListEncoder.binary.encode([OldTab(url: page(titled: "Old"), title: "Old")])

        let tabs = try PropertyListDecoder().decode([TabSession].self, from: data)

        XCTAssertEqual(tabs, [TabSession(url: page(titled: "Old"), title: "Old", interactionState: nil)])
        XCTAssertFalse(tabs[0].isPinned)
    }

    func testRestoredTabsAreSuspendedExceptTheSelectedOne() throws {
        let browser = BrowserModel()
        var session = window(["First", "Second", "Third"], selected: 2)
        session.tabs.insert(TabSession(url: nil, title: "", interactionState: nil), at: 1)

        browser.restoreSession(session)

        XCTAssertEqual(browser.tabs.count, 4)
        XCTAssertEqual(browser.activeTabID, browser.tabs[2].id)
        XCTAssertTrue(browser.tabs[0].isSuspended)
        XCTAssertEqual(browser.tabs[0].title, "First")
        XCTAssertTrue(browser.tabs[1].isNewTab)
        XCTAssertFalse(browser.tabs[2].isSuspended)
        XCTAssertTrue(browser.tabs[3].isSuspended)

        let saved = browser.windowSession()
        XCTAssertEqual(saved.selectedIndex, 2)
        XCTAssertEqual(saved.tabs.map(\.url), [page(titled: "First"), nil, page(titled: "Second"),
                                               page(titled: "Third")])
        XCTAssertEqual(saved.tabs.map(\.title), ["First", "", "Second", "Third"])
    }

    func testFirstWindowRestoresTheSessionAndAsksForTheOtherWindows() {
        let file = makeFile()
        file.writeNow(try? PropertyListEncoder.binary.encode(SessionSnapshot(windows: [
            window(["A"]), window(["B"]), window(["C1", "C2"], selected: 1),
        ])))
        let session = SessionStore(file: file)
        let browsers = (0..<4).map { _ in BrowserModel() }

        XCTAssertEqual(session.attach(browsers[0]).count, 2)
        XCTAssertEqual(session.attach(browsers[1]), [])
        XCTAssertEqual(session.attach(browsers[2]), [])
        XCTAssertEqual(session.attach(browsers[3]), [])

        XCTAssertEqual(browsers.map(\.activeTab?.title), ["A", "B", "C2", "New Tab"])
        XCTAssertTrue(session.reopenableWindows.isEmpty)
    }

    func testClosingTheLastWindowKeepsItForReopening() {
        let session = SessionStore(file: nil)
        let closing = BrowserModel()
        closing.restoreSession(window(["One", "Two"], selected: 1))
        _ = session.attach(closing)

        session.detach(closing)
        XCTAssertEqual(session.reopenableWindows.map(\.tabs.count), [2])

        let blank = BrowserModel()
        _ = session.attach(blank)
        XCTAssertEqual(session.reopenLastSession(reusing: blank), [])

        XCTAssertEqual(blank.tabs.map(\.title), ["One", "Two"])
        XCTAssertEqual(blank.activeTabID, blank.tabs[1].id)
        XCTAssertTrue(session.reopenableWindows.isEmpty)
    }

    func testWindowsWaitInTheHistoryMenuWhenNotRestoredOnLaunch() {
        let file = makeFile()
        file.writeNow(try? PropertyListEncoder.binary.encode(SessionSnapshot(windows: [window(["A"]), window(["B"])],
                                                                             closedWindows: [window(["Old"])])))
        let session = SessionStore(file: file, restoresWindows: false)
        let browser = BrowserModel()

        XCTAssertEqual(session.attach(browser), [])
        XCTAssertTrue(browser.isBlank)
        XCTAssertEqual(session.reopenableWindows.map { $0.tabs.map(\.title) }, [["A"], ["B"]])

        session.forgetClosedWindows()
        XCTAssertTrue(session.reopenableWindows.isEmpty)
    }

    func testPrivateWindowsArentSaved() {
        let session = SessionStore(file: nil)
        let normal = BrowserModel()
        normal.restoreSession(window(["Normal"]))
        _ = session.attach(normal)
        // BrowserWindow never attaches a private window.
        let privateWindow = BrowserModel.makePrivate(downloads: DownloadManager())
        privateWindow.restoreSession(window(["Private"]))

        XCTAssertEqual(session.snapshot.windows.map { $0.tabs.map(\.title) }, [["Normal"]])
    }

    func testSessionSavedOnQuitIsRestoredByTheNextLaunch() {
        let file = makeFile()
        let session = SessionStore(file: file)
        let browser = BrowserModel()
        _ = session.attach(browser)
        browser.restoreSession(window(["Saved"]))

        session.saveBeforeQuitting()
        session.detach(browser)

        let relaunched = SessionStore(file: file)
        let restored = BrowserModel()
        XCTAssertEqual(relaunched.attach(restored), [])
        XCTAssertEqual(restored.activeTab?.title, "Saved")
    }
}
