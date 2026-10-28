import WebKit
import XCTest
@testable import Browser

/// Stands in for the keychain and WebKit's data stores, and records what a profile's deletion removes.
@MainActor
private final class ProfileFixture {
    let defaults: UserDefaults
    let directory: URL
    let session = SessionStore(file: nil)
    var passwordStorages: [String: InMemoryPasswordStorage] = [:]
    var removedDataStores: [UUID?] = []

    init(name: String) {
        let suiteName = "dev.athas.browser.tests.profiles.\(name)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        directory = FileManager.default.temporaryDirectory.appending(path: "BrowserTests-\(UUID().uuidString)")
    }

    var services: ProfileServices {
        ProfileServices(defaults: defaults, directory: directory,
                        makePasswordStorage: { [unowned self] storage in
                            let key = storage.passwordItemDescription
                            if let existing = passwordStorages[key] { return existing }
                            let created = InMemoryPasswordStorage()
                            passwordStorages[key] = created
                            return created
                        },
                        makeDataStore: { _ in .nonPersistent() },
                        ruleListStore: nil,
                        removeDataStore: { [unowned self] storage in removedDataStores.append(storage.dataStoreIdentifier) })
    }

    func makeStore() -> ProfileStore {
        ProfileStore(session: session, services: services)
    }
}

@MainActor
final class ProfileTests: XCTestCase {
    func testExistingDataMovesIntoAPersonalProfileWithoutChanging() throws {
        let fixture = ProfileFixture(name: "migration")
        let bookmark = Bookmark(title: "Swift", url: URL(string: "https://swift.org")!)
        fixture.defaults.set(try JSONEncoder().encode([bookmark]), forKey: "bookmarks")
        fixture.defaults.set(["swift.org": 1.25], forKey: "pageZoomLevels")
        fixture.defaults.set(["example.com"], forKey: "trackerBlockingExceptions")

        let profiles = fixture.makeStore()

        XCTAssertEqual(profiles.profiles.map(\.name), ["Personal"])
        let personal = profiles.defaultProfile
        XCTAssertTrue(personal.usesOriginalStorage)
        XCTAssertEqual(personal.color, .slate)
        let data = profiles.data(for: personal.id)
        XCTAssertEqual(data.bookmarks.bookmarks, [bookmark])
        XCTAssertEqual(data.zoomLevels.level(for: "swift.org"), 1.25)
        XCTAssertEqual(data.contentBlocker.exceptions, ["example.com"])
        XCTAssertEqual(data.storage.historyFile?.url, fixture.directory.appending(path: "History.plist"))
        XCTAssertNil(data.storage.dataStoreIdentifier)
        XCTAssertEqual(data.storage.passwordItemDescription, KeychainPasswordStorage.itemDescription)

        // The next launch finds the same profile, rather than migrating again.
        let relaunched = fixture.makeStore()
        XCTAssertEqual(relaunched.profiles, profiles.profiles)
        XCTAssertEqual(relaunched.defaultProfileID, personal.id)
    }

    func testEachNewProfileKeepsItsDataApart() throws {
        let fixture = ProfileFixture(name: "paths")
        let profiles = fixture.makeStore()
        let personal = profiles.data(for: nil)
        let work = profiles.makeProfile()
        profiles.save(work)
        let workData = profiles.data(for: work.id)

        let storage = workData.storage
        XCTAssertFalse(storage.isOriginal)
        XCTAssertEqual(storage.dataStoreIdentifier, work.id)
        XCTAssertEqual(storage.historyFile?.url,
                       fixture.directory.appending(path: "Profiles/\(work.id.uuidString)/History.plist"))
        XCTAssertEqual(storage.defaultsKeyPrefix, "profile.\(work.id.uuidString).")
        XCTAssertNotEqual(storage.passwordItemDescription, personal.storage.passwordItemDescription)
        XCTAssertNotEqual(storage.ruleListIdentifier, personal.storage.ruleListIdentifier)
        XCTAssertNotEqual(work.color, profiles.defaultProfile.color)

        workData.bookmarks.add(title: "Work", url: URL(string: "https://work.example")!)
        workData.zoomLevels.setLevel(1.5, for: "work.example")
        try workData.passwords.save(XCTUnwrap(PasswordCapture(body: ["type": "submit", "username": "me", "password": "pw"],
                                                              isMainFrame: true,
                                                              origin: PasswordOrigin(host: "work.example"))))

        XCTAssertTrue(personal.bookmarks.bookmarks.isEmpty)
        XCTAssertEqual(personal.zoomLevels.level(for: "work.example"), 1)
        XCTAssertTrue(personal.passwords.passwords(for: PasswordOrigin(host: "work.example")).isEmpty)
        XCTAssertNotNil(fixture.defaults.data(forKey: "profile.\(work.id.uuidString).bookmarks"))
        XCTAssertNil(fixture.defaults.data(forKey: "bookmarks"))

        let relaunched = fixture.makeStore()
        XCTAssertEqual(relaunched.data(for: work.id).bookmarks.bookmarks.map(\.title), ["Work"])
        XCTAssertEqual(relaunched.data(for: work.id).zoomLevels.level(for: "work.example"), 1.5)
    }

    func testProfilesCanBeRenamedRecoloredAndMadeTheDefault() {
        let fixture = ProfileFixture(name: "editing")
        let profiles = fixture.makeStore()
        var work = profiles.makeProfile()
        work.name = "  Work  "
        work.icon = .emoji("💼")
        profiles.save(work)
        work.color = ProfileColor(red: 1, green: 0, blue: 0)
        // Saving can't move a profile's data.
        work.usesOriginalStorage = true
        profiles.save(work)
        profiles.setDefault(work.id)

        let relaunched = fixture.makeStore()
        let saved = relaunched.profile(withID: work.id)
        XCTAssertEqual(saved?.name, "Work")
        XCTAssertEqual(saved?.icon, .emoji("💼"))
        XCTAssertEqual(saved?.color, ProfileColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(saved?.usesOriginalStorage, false)
        XCTAssertEqual(relaunched.defaultProfileID, work.id)
        XCTAssertEqual(relaunched.data(for: nil).id, work.id)
    }

    func testDeletingAProfileRemovesEverythingItKept() async throws {
        let fixture = ProfileFixture(name: "deletion")
        let profiles = fixture.makeStore()
        let personal = profiles.defaultProfile
        let work = profiles.makeProfile()
        profiles.save(work)
        profiles.setDefault(work.id)
        let data = profiles.data(for: work.id)
        data.bookmarks.add(title: "Work", url: URL(string: "https://work.example")!)
        data.sitePermissions.setDecision(true, for: .camera, on: "https://work.example")
        try data.passwords.save(XCTUnwrap(PasswordCapture(body: ["type": "submit", "username": "me", "password": "pw"],
                                                          isMainFrame: true,
                                                          origin: PasswordOrigin(host: "work.example"))))
        let historyFolder = try XCTUnwrap(data.storage.folder)
        try FileManager.default.createDirectory(at: historyFolder, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: historyFolder.appending(path: "History.plist"))
        profiles.data(for: personal.id).bookmarks.add(title: "Personal", url: URL(string: "https://personal.example")!)

        let window = BrowserModel(profile: data, downloads: DownloadManager())
        window.restoreSession(WindowSession(tabs: [TabSession(url: URL(string: "https://work.example")!, title: "Work",
                                                              interactionState: nil)], selectedIndex: 0))
        _ = fixture.session.attach(window)
        fixture.session.detach(window)
        XCTAssertEqual(fixture.session.reopenableWindows.count, 1)

        await profiles.delete(work.id)

        XCTAssertEqual(profiles.profiles.map(\.id), [personal.id])
        XCTAssertEqual(profiles.defaultProfileID, personal.id)
        XCTAssertTrue(fixture.session.reopenableWindows.isEmpty)
        XCTAssertNil(fixture.defaults.data(forKey: "profile.\(work.id.uuidString).bookmarks"))
        XCTAssertNil(fixture.defaults.object(forKey: "profile.\(work.id.uuidString).sitePermissions"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyFolder.path))
        XCTAssertEqual(try fixture.passwordStorages[data.storage.passwordItemDescription]?.savedPasswords(), [])
        XCTAssertEqual(fixture.removedDataStores, [work.id])
        XCTAssertEqual(fixture.defaults.stringArray(forKey: ProfileStore.pendingRemovalsKey), [])
        // The other profile keeps its data.
        XCTAssertEqual(profiles.data(for: personal.id).bookmarks.bookmarks.map(\.title), ["Personal"])
        XCTAssertNotNil(fixture.defaults.data(forKey: "bookmarks"))

        // The last profile stays.
        await profiles.delete(personal.id)
        XCTAssertEqual(profiles.profiles.map(\.id), [personal.id])
    }

    func testDeletingTheOriginalProfileRemovesOnlyItsOwnFiles() async throws {
        let fixture = ProfileFixture(name: "original-deletion")
        let profiles = fixture.makeStore()
        let personal = profiles.defaultProfile
        profiles.save(profiles.makeProfile())
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data().write(to: fixture.directory.appending(path: "History.plist"))
        try Data().write(to: fixture.directory.appending(path: "Session.plist"))
        fixture.defaults.set(["swift.org": 1.25], forKey: "pageZoomLevels")

        await profiles.delete(personal.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appending(path: "History.plist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appending(path: "Session.plist").path))
        XCTAssertNil(fixture.defaults.object(forKey: "pageZoomLevels"))
        XCTAssertEqual(fixture.removedDataStores, [nil])
        XCTAssertEqual(profiles.profiles.count, 1)
        XCTAssertNotEqual(profiles.defaultProfileID, personal.id)
    }

    func testWindowsReopenInTheirProfiles() {
        let fixture = ProfileFixture(name: "session")
        let file = StoreFile(url: fixture.directory.appending(path: "Session.plist"))
        let session = SessionStore(file: file)
        let profiles = ProfileStore(session: session, services: fixture.services)
        let personal = profiles.defaultProfile
        let work = profiles.makeProfile()
        profiles.save(work)
        for (profile, title) in [(work, "Work"), (personal, "Personal")] {
            let browser = BrowserModel(profile: profiles.data(for: profile.id), downloads: DownloadManager())
            browser.restoreSession(WindowSession(tabs: [TabSession(url: URL(string: "data:text/html,\(title)")!,
                                                                   title: title, interactionState: nil)],
                                                 selectedIndex: 0))
            _ = session.attach(browser)
        }
        XCTAssertEqual(session.snapshot.windows.map(\.profileID), [work.id, personal.id])
        session.saveBeforeQuitting()

        // On launch the first window opens in the first saved window's profile, and asks for the rest.
        let relaunched = SessionStore(file: file)
        let relaunchedProfiles = ProfileStore(session: relaunched, services: fixture.services)
        XCTAssertEqual(relaunched.nextPendingProfileID, work.id)
        let first = BrowserModel(profile: relaunchedProfiles.data(for: relaunched.nextPendingProfileID),
                                 downloads: DownloadManager())
        XCTAssertEqual(relaunched.attach(first), [personal.id])
        XCTAssertEqual(first.activeTab?.title, "Work")
        let second = BrowserModel(profile: relaunchedProfiles.data(for: personal.id), downloads: DownloadManager())
        XCTAssertEqual(relaunched.attach(second), [])
        XCTAssertEqual(second.activeTab?.title, "Personal")

        // Reopening them later from the History menu works the same way.
        let waiting = SessionStore(file: file, restoresWindows: false)
        let waitingProfiles = ProfileStore(session: waiting, services: fixture.services)
        let personalWindow = BrowserModel(profile: waitingProfiles.data(for: personal.id), downloads: DownloadManager())
        XCTAssertEqual(waiting.reopenLastSession(reusing: personalWindow), [work.id])
        XCTAssertEqual(personalWindow.activeTab?.title, "Personal")
    }

    func testSavedWindowsWithoutAProfileJoinTheOriginalOne() {
        let session = SessionStore(file: nil)
        let closing = BrowserModel()
        _ = session.attach(closing)
        session.detach(closing)
        XCTAssertNil(session.reopenableWindows.first?.profileID ?? nil)

        let profiles = ProfileStore(session: session, services: .inMemory)

        XCTAssertEqual(session.reopenableWindows.map(\.profileID), [profiles.defaultProfileID])
        session.assignProfiles(existing: [], fallback: profiles.defaultProfileID)
        XCTAssertTrue(session.reopenableWindows.isEmpty)
    }

    func testPrivateWindowsBelongToNoProfile() {
        let profiles = ProfileStore(session: SessionStore(file: nil), services: .inMemory)
        let personal = profiles.data(for: nil)
        let privateWindow = BrowserModel.makePrivate(downloads: DownloadManager(), openedFrom: personal)

        XCTAssertNil(privateWindow.profileID)
        XCTAssertEqual(privateWindow.openerProfileID, personal.id)
        XCTAssertEqual(profiles.profile(for: privateWindow)?.id, personal.id)
        XCTAssertNil(privateWindow.windowSession().profileID)
    }

    func testProfileColorsRoundTrip() throws {
        let color = ProfileColor(red: 0.2, green: 0.4, blue: 0.6)
        let converted = ProfileColor(color.color)

        XCTAssertEqual(converted.red, 0.2, accuracy: 0.01)
        XCTAssertEqual(converted.green, 0.4, accuracy: 0.01)
        XCTAssertEqual(converted.blue, 0.6, accuracy: 0.01)
        let profile = BrowserProfile(name: " work ", color: color, icon: .symbol("briefcase.fill"))
        XCTAssertEqual(try JSONDecoder().decode(BrowserProfile.self, from: JSONEncoder().encode(profile)), profile)
        XCTAssertEqual(profile.initial, "W")
        XCTAssertEqual(BrowserProfile(name: " ", color: color).displayName, "Untitled Profile")
    }
}
