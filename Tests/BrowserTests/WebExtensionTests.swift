import WebKit
import XCTest
@testable import Browser

final class ChromeWebStoreTests: XCTestCase {
    private let uBlockLite = "ddkjiahejlhfcafbddmgiahcphecmpfh"

    func testReadsTheExtensionIDFromStorePages() {
        XCTAssertEqual(ChromeWebStore.extensionID(from: URL(string:
            "https://chromewebstore.google.com/detail/ublock-origin-lite/\(uBlockLite)")), uBlockLite)
        XCTAssertEqual(ChromeWebStore.extensionID(from: URL(string:
            "https://chromewebstore.google.com/detail/\(uBlockLite)?hl=tr")), uBlockLite)
        XCTAssertEqual(ChromeWebStore.extensionID(from: URL(string:
            "https://chrome.google.com/webstore/detail/name/\(uBlockLite)")), uBlockLite)
    }

    func testIgnoresOtherPages() {
        XCTAssertNil(ChromeWebStore.extensionID(from: URL(string: "https://chromewebstore.google.com/category/extensions")))
        XCTAssertNil(ChromeWebStore.extensionID(from: URL(string: "https://example.com/detail/\(uBlockLite)")))
        XCTAssertNil(ChromeWebStore.extensionID(from: URL(string: "https://chromewebstore.google.com/detail/short")))
        XCTAssertFalse(ChromeWebStore.isExtensionID(String(repeating: "z", count: 32)))
    }

    func testUnwrapsPackages() throws {
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3])
        var crx3 = Data("Cr24".utf8)
        crx3 += Data([3, 0, 0, 0, 4, 0, 0, 0, 9, 9, 9, 9]) + zip
        var crx2 = Data("Cr24".utf8)
        crx2 += Data([2, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 7, 7, 8]) + zip

        XCTAssertEqual(try ChromeWebStore.archive(fromPackage: crx3), zip)
        XCTAssertEqual(try ChromeWebStore.archive(fromPackage: crx2), zip)
        XCTAssertEqual(try ChromeWebStore.archive(fromPackage: zip), zip)
    }

    func testRejectsBrokenPackages() {
        XCTAssertThrowsError(try ChromeWebStore.archive(fromPackage: Data("not a package".utf8)))
        var truncated = Data("Cr24".utf8)
        truncated += Data([3, 0, 0, 0, 200, 0, 0, 0])
        XCTAssertThrowsError(try ChromeWebStore.archive(fromPackage: truncated))
        var unknown = Data("Cr24".utf8)
        unknown += Data([9, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try ChromeWebStore.archive(fromPackage: unknown)) { error in
            XCTAssertEqual(error as? ChromeWebStore.PackageError, .unsupportedVersion(9))
        }
    }

    func testAsksTheStoreForAPackageByID() {
        let url = ChromeWebStore.packageURL(for: uBlockLite).absoluteString
        XCTAssertTrue(url.hasPrefix("https://clients2.google.com/service/update2/crx?"))
        XCTAssertTrue(url.contains("x=id%3D\(uBlockLite)%26uc"))
    }
}

@MainActor
final class WebExtensionStoreTests: XCTestCase {
    func testComparesVersionsNumerically() {
        XCTAssertTrue(WebExtensionStore.isVersion("1.10.0", newerThan: "1.9.3"))
        XCTAssertTrue(WebExtensionStore.isVersion("2026.1021.1354", newerThan: "2026.1007.2010"))
        XCTAssertFalse(WebExtensionStore.isVersion("1.2", newerThan: "1.2"))
        XCTAssertFalse(WebExtensionStore.isVersion("1.2", newerThan: "1.10"))
        XCTAssertTrue(WebExtensionStore.isVersion("1.0", newerThan: nil))
    }

    func testDescribesWhatAnExtensionCanDo() throws {
        let all = try WKWebExtension.MatchPattern(string: "<all_urls>")
        XCTAssertEqual(WebExtensionPrompts.describe([.tabs, .storage], patterns: [all]),
                       ["Read and change all your data on all websites", "Read your browsing history"])
        let site = try WKWebExtension.MatchPattern(string: "*://*.example.com/*")
        XCTAssertEqual(WebExtensionPrompts.describe([.storage], patterns: [site]),
                       ["Read and change your data on example.com"])
        XCTAssertEqual(WebExtensionPrompts.describe([.storage, .alarms], patterns: []), [])
    }

    func testWithoutAFolderNothingCanBeInstalledOrIsKept() {
        let store = WebExtensionStore(defaults: nil, folder: nil, persistentID: nil, dataStore: .nonPersistent())
        XCTAssertFalse(store.canInstall)
        XCTAssertTrue(store.installed.isEmpty)
        XCTAssertFalse(store.controller.configuration.isPersistent)
    }

    func testPrivateWindowsRunNoExtensions() {
        let store = WebExtensionStore(defaults: nil, folder: nil, persistentID: nil, dataStore: .nonPersistent())
        let browser = BrowserModel(websiteDataStore: .nonPersistent(), extensions: store)
        XCTAssertNil(browser.extensions)
        XCTAssertNil(browser.makeConfiguration().webExtensionController)
    }

    func testNormalWindowsRunTheProfilesExtensions() {
        let store = WebExtensionStore(defaults: nil, folder: nil, persistentID: nil, dataStore: .default())
        let browser = BrowserModel(websiteDataStore: .default(), extensions: store)
        XCTAssertTrue(browser.makeConfiguration().webExtensionController === store.controller)
        XCTAssertTrue(browser.tabs.first?.extensionTab.tab === browser.tabs.first)
        XCTAssertTrue(browser.extensionWindow.browser === browser)
    }
}

@MainActor
final class SiteCompatibilityTests: XCTestCase {
    func testSitesShareTheirChoiceAcrossSubdomains() {
        let compatibility = SiteCompatibility()
        compatibility.setIdentity(.chrome, for: URL(string: "https://www.example.com/page"))

        XCTAssertEqual(compatibility.identity(for: URL(string: "https://app.example.com/")), .chrome)
        XCTAssertEqual(compatibility.identity(for: URL(string: "https://other.org/")), .safari)
        XCTAssertNotNil(compatibility.userAgent(for: URL(string: "https://example.com")))
        XCTAssertNil(compatibility.userAgent(for: URL(string: "https://other.org")))
    }

    func testSafariIsTheDefaultAndIsntStored() {
        let compatibility = SiteCompatibility()
        compatibility.setIdentity(.firefox, forSite: "example.com")
        compatibility.setIdentity(.safari, forSite: "example.com")
        XCTAssertTrue(compatibility.identities.isEmpty)
    }

    func testOnlyWebPagesHaveASite() {
        XCTAssertNil(SiteCompatibility.site(of: URL(string: "file:///Users/me/page.html")))
        XCTAssertNil(SiteCompatibility.site(of: nil))
        XCTAssertEqual(SiteCompatibility.site(of: URL(string: "https://news.bbc.co.uk/")), "bbc.co.uk")
    }

    func testChoicesAreKeptPerProfile() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SiteCompatibilityTests"))
        defaults.removePersistentDomain(forName: "SiteCompatibilityTests")
        SiteCompatibility(defaults: defaults, keyPrefix: "a.").setIdentity(.chrome, forSite: "example.com")

        XCTAssertEqual(SiteCompatibility(defaults: defaults, keyPrefix: "a.").identities, ["example.com": .chrome])
        XCTAssertTrue(SiteCompatibility(defaults: defaults, keyPrefix: "b.").identities.isEmpty)
    }

    func testIdentitiesNameTheirBrowser() {
        XCTAssertTrue(BrowserIdentity.chrome.userAgent?.contains("Chrome/") == true)
        XCTAssertTrue(BrowserIdentity.firefox.userAgent?.contains("Firefox/") == true)
        XCTAssertNil(BrowserIdentity.safari.userAgent)
    }
}

@MainActor
final class CrashRecoveryTests: XCTestCase {
    func testAPageThatCrashesAgainSoonIsntReloaded() {
        let tab = BrowserTab()
        let start = ContinuousClock.now
        XCTAssertFalse(tab.recordCrash(at: start))
        XCTAssertTrue(tab.recordCrash(at: start + .seconds(5)))
    }

    func testCrashesFarApartAreReloaded() {
        let tab = BrowserTab()
        let start = ContinuousClock.now
        XCTAssertFalse(tab.recordCrash(at: start))
        XCTAssertFalse(tab.recordCrash(at: start + .seconds(60)))
    }

    func testTheCrashErrorOffersAnotherBrowser() {
        let error = PageLoadError(kind: .crashed, url: URL(string: "https://example.com"))
        XCTAssertEqual(error.title, "This Page Keeps Crashing")
        XCTAssertEqual(error.symbolName, "exclamationmark.octagon")
    }
}
