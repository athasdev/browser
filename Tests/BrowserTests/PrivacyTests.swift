import WebKit
import XCTest
@testable import Browser

@MainActor
final class PrivacyTests: XCTestCase {
    private func makeProfile() -> ProfileData {
        ProfileStore(session: SessionStore(file: nil), services: .inMemory).data(for: nil)
    }

    func testPrivateWindowsRememberNothing() throws {
        let profile = makeProfile()
        let browser = BrowserModel.makePrivate(downloads: DownloadManager(), openedFrom: profile)

        XCTAssertTrue(browser.isPrivate)
        XCTAssertNil(browser.history)
        XCTAssertNil(browser.profileID)
        XCTAssertEqual(browser.openerProfileID, profile.id)
        XCTAssertFalse(browser.websiteDataStore.isPersistent)
        XCTAssertFalse(browser.sitePermissions === profile.sitePermissions)
        XCTAssertFalse(browser.zoomLevels === profile.zoomLevels)
        XCTAssertTrue(browser.bookmarks === profile.bookmarks)
        XCTAssertFalse(BrowserModel().isPrivate)
    }

    func testPrivateTabsShareTheirWindowsDataStoreOnly() throws {
        let first = BrowserModel.makePrivate(downloads: DownloadManager())
        let second = BrowserModel.makePrivate(downloads: DownloadManager())
        first.addTab()

        let stores = first.tabs.compactMap { $0.webView?.configuration.websiteDataStore }
        XCTAssertEqual(stores.count, 2)
        XCTAssertTrue(stores.allSatisfy { $0 === first.websiteDataStore })
        XCTAssertFalse(first.websiteDataStore === second.websiteDataStore)
        XCTAssertFalse(first.websiteDataStore === WKWebsiteDataStore.default())
    }

    func testPrivatePopUpsAndRestoredTabsStayPrivate() throws {
        let browser = BrowserModel.makePrivate(downloads: DownloadManager())
        let opener = try XCTUnwrap(browser.activeTab)
        let configuration = try XCTUnwrap(opener.webView?.configuration)

        let popUp = browser.openChildTab(of: opener, configuration: configuration, select: false)
        XCTAssertTrue(popUp.webView?.configuration.websiteDataStore === browser.websiteDataStore)

        browser.restoreSession(WindowSession(tabs: [
            TabSession(url: URL(string: "data:text/html,<title>A</title>")!, title: "A", interactionState: nil),
            TabSession(url: URL(string: "data:text/html,<title>B</title>")!, title: "B", interactionState: nil),
        ], selectedIndex: 0))
        browser.selectTab(at: 1)

        XCTAssertTrue(browser.activeTab?.webView?.configuration.websiteDataStore === browser.websiteDataStore)
    }

    func testPrivateZoomLevelsAreForgotten() throws {
        let profile = makeProfile()
        let browser = BrowserModel.makePrivate(downloads: DownloadManager(), openedFrom: profile)
        browser.zoomLevels.setLevel(1.5, for: "private.example")

        XCTAssertEqual(browser.zoomLevels.level(for: "private.example"), 1.5)
        XCTAssertEqual(profile.zoomLevels.level(for: "private.example"), 1)
        XCTAssertEqual(BrowserModel.makePrivate(downloads: DownloadManager()).zoomLevels.level(for: "private.example"), 1)
    }

    func testClearingSiteDataLeavesTheCacheAndTheOtherWayAround() {
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()

        let siteData = ClearDataOptions.siteData.websiteDataTypes(from: allTypes)
        XCTAssertTrue(siteData.contains(WKWebsiteDataTypeCookies))
        XCTAssertTrue(siteData.contains(WKWebsiteDataTypeLocalStorage))
        XCTAssertTrue(siteData.isDisjoint(with: ClearDataOptions.cacheTypes))

        let cache = ClearDataOptions.cache.websiteDataTypes(from: allTypes)
        XCTAssertTrue(cache.contains(WKWebsiteDataTypeDiskCache))
        XCTAssertFalse(cache.contains(WKWebsiteDataTypeCookies))

        XCTAssertEqual(ClearDataOptions.all.websiteDataTypes(from: allTypes), allTypes)
        XCTAssertTrue(ClearDataOptions([.history, .favicons]).websiteDataTypes(from: allTypes).isEmpty)
    }

    func testClearingAllHistoryForgetsClosedWindows() async {
        let history = HistoryStore(file: nil)
        let session = SessionStore(file: nil)
        let closing = BrowserModel()
        closing.restoreSession(WindowSession(tabs: [
            TabSession(url: URL(string: "https://swift.org")!, title: "Swift", interactionState: nil),
        ], selectedIndex: 0))
        _ = session.attach(closing)
        session.detach(closing)
        history.recordVisit(to: URL(string: "https://swift.org")!, title: "Swift")
        let data = BrowsingData(history: history, session: session, dataStore: .nonPersistent())

        await data.clear(.history, range: .lastHour)
        XCTAssertTrue(history.visits.isEmpty)
        XCTAssertFalse(session.reopenableWindows.isEmpty)

        await data.clear(.history, range: .all)
        XCTAssertTrue(session.reopenableWindows.isEmpty)
    }
}
