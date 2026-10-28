import XCTest
@testable import Browser

@MainActor
final class PinnedTabTests: XCTestCase {
    /// A window with `count` tabs, the first one selected.
    private func makeBrowser(tabs count: Int) -> BrowserModel {
        let browser = BrowserModel()
        for _ in 1..<count {
            browser.addTab()
        }
        browser.selectTab(at: 0)
        return browser
    }

    func testPinnedTabsGoFirstInTheOrderTheyWerePinned() {
        let browser = makeBrowser(tabs: 4)
        let ids = browser.tabs.map(\.id)

        browser.setPinned(true, for: ids[2])
        browser.setPinned(true, for: ids[3])

        XCTAssertEqual(browser.tabs.map(\.id), [ids[2], ids[3], ids[0], ids[1]])
        XCTAssertEqual(browser.pinnedCount, 2)

        browser.setPinned(false, for: ids[2])

        XCTAssertEqual(browser.tabs.map(\.id), [ids[3], ids[2], ids[0], ids[1]])
        XCTAssertEqual(browser.pinnedCount, 1)
    }

    func testDraggingAcrossThePinnedTabsPinsOrUnpins() {
        let browser = makeBrowser(tabs: 4)
        let ids = browser.tabs.map(\.id)
        browser.setPinned(true, for: ids[0])
        browser.setPinned(true, for: ids[1])

        browser.moveTab(ids[3], to: 1)

        XCTAssertEqual(browser.tabs.map(\.id), [ids[0], ids[3], ids[1], ids[2]])
        XCTAssertEqual(browser.tabs.map(\.isPinned), [true, true, true, false])

        browser.moveTab(ids[0], to: 3)

        XCTAssertEqual(browser.tabs.map(\.id), [ids[3], ids[1], ids[2], ids[0]])
        XCTAssertEqual(browser.tabs.map(\.isPinned), [true, true, false, false])

        // Reordering pinned tabs keeps them pinned.
        browser.moveTab(ids[3], to: 1)
        XCTAssertEqual(browser.tabs.map(\.id), [ids[1], ids[3], ids[2], ids[0]])
        XCTAssertEqual(browser.pinnedCount, 2)
    }

    func testClosingOtherTabsKeepsPinnedTabs() {
        let browser = makeBrowser(tabs: 4)
        let ids = browser.tabs.map(\.id)
        browser.setPinned(true, for: ids[1])

        XCTAssertTrue(browser.canCloseOtherTabs(than: ids[2]))
        browser.closeOtherTabs(than: ids[2])

        XCTAssertEqual(browser.tabs.map(\.id), [ids[1], ids[2]])
        XCTAssertFalse(browser.canCloseOtherTabs(than: ids[2]))
        XCTAssertEqual(browser.activeTabID, ids[2])

        // ⌘W still closes a pinned tab.
        browser.activeTabID = ids[1]
        browser.closeActiveTab()
        XCTAssertEqual(browser.tabs.map(\.id), [ids[2]])
    }

    func testClosingTabsToTheRightKeepsPinnedTabs() {
        let browser = makeBrowser(tabs: 3)
        let ids = browser.tabs.map(\.id)
        browser.setPinned(true, for: ids[0])
        browser.setPinned(true, for: ids[1])

        browser.closeTabs(after: ids[0])

        XCTAssertEqual(browser.tabs.map(\.id), [ids[0], ids[1]])
    }

    func testAPinnedTabsLinksOpenAfterThePinnedTabs() {
        let browser = makeBrowser(tabs: 3)
        let ids = browser.tabs.map(\.id)
        browser.setPinned(true, for: ids[0])
        browser.setPinned(true, for: ids[1])
        let opener = browser.tabs[0]

        let first = browser.openChildTab(of: opener, select: true)
        let second = browser.openChildTab(of: opener, select: false)

        XCTAssertEqual(browser.tabs.map(\.id), [ids[0], ids[1], first.id, second.id, ids[2]])
        XCTAssertFalse(first.isPinned)
        XCTAssertEqual(browser.activeTabID, first.id)
    }

    func testDuplicatesAndReopenedTabsStayPinned() {
        let browser = makeBrowser(tabs: 2)
        let ids = browser.tabs.map(\.id)
        browser.setPinned(true, for: ids[1])

        browser.duplicateTab(ids[1])

        XCTAssertEqual(browser.pinnedCount, 2)
        XCTAssertEqual(browser.tabs[1].id, browser.activeTabID)

        browser.closeTab(ids[1])
        browser.reopenClosedTab()

        XCTAssertEqual(browser.pinnedCount, 2)
        XCTAssertTrue(browser.activeTab?.isPinned == true)
    }

    func testLinksLeaveTheSiteOnlyForAnotherSite() {
        let page = URL(string: "https://mail.example.com/inbox")
        XCTAssertFalse(BrowserTab.leavesSite(from: page, to: URL(string: "https://example.com/settings")))
        XCTAssertFalse(BrowserTab.leavesSite(from: page, to: URL(string: "https://www.example.com/")))
        XCTAssertTrue(BrowserTab.leavesSite(from: page, to: URL(string: "https://example.org/")))
        XCTAssertFalse(BrowserTab.leavesSite(from: page, to: URL(string: "mailto:someone@example.org")))
        XCTAssertFalse(BrowserTab.leavesSite(from: nil, to: URL(string: "https://example.org/")))

        XCTAssertEqual(BrowserTab.site(of: "news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(BrowserTab.site(of: "www.example.com.tr"), "example.com.tr")
        XCTAssertEqual(BrowserTab.site(of: "192.168.1.10"), "192.168.1.10")
    }
}
