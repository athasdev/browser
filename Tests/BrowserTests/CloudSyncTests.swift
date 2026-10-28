import CloudKit
import XCTest
@testable import Browser

@MainActor
final class BookmarkTreeTests: XCTestCase {
    private func makeStore() -> (BookmarkStore, news: UUID, tech: UUID) {
        let store = BookmarkStore(defaults: nil)
        let news = store.addFolder(titled: "News")
        let tech = store.addFolder(titled: "Tech", in: news)
        store.add(title: "Apple", url: URL(string: "https://apple.com")!)
        store.add(title: "HN", url: URL(string: "https://news.ycombinator.com")!, in: tech)
        store.add(title: "BBC", url: URL(string: "https://bbc.co.uk")!, in: news)
        return (store, news, tech)
    }

    func testFlatteningAndRebuildingKeepsTheTree() {
        let (store, _, _) = makeStore()
        let flat = BookmarkTree.flatten(store.root)
        XCTAssertEqual(flat.count, 5)
        XCTAssertEqual(BookmarkTree.build(flat), store.root)
    }

    func testOrphansGoOnTheBookmarksBar() {
        var flat = BookmarkTree.flatten(makeStore().0.root)
        let lost = UUID()
        flat[lost] = SyncedBookmark(parentID: UUID(), position: 0, title: "Lost", url: URL(string: "https://lost.example"))
        XCTAssertEqual(BookmarkTree.build(flat).last?.id, lost)
    }

    func testAFolderCycleIsBrokenWithoutLosingAnything() {
        let a = UUID(), b = UUID()
        let cyclic = [a: SyncedBookmark(parentID: b, position: 0, title: "A"),
                      b: SyncedBookmark(parentID: a, position: 0, title: "B")]
        let built = BookmarkTree.build(cyclic)
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(BookmarkTree.flatten(built).count, 2)
    }

    func testEqualPositionsOrderTheSameOnEveryDevice() {
        let ids = (0..<4).map { _ in UUID() }
        let items = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, SyncedBookmark(parentID: nil, position: 0, title: "", url: URL(string: "https://x.example")))
        })
        XCTAssertEqual(BookmarkTree.build(items).map(\.id), ids.sorted { $0.uuidString < $1.uuidString })
    }

    func testRemoteChangesArentReportedBackButLocalOnesAre() {
        let (store, _, _) = makeStore()
        var changes = 0
        store.onChange = { changes += 1 }
        store.replaceAll(with: [])
        XCTAssertEqual(changes, 0)
        store.add(title: "New", url: URL(string: "https://new.example")!)
        XCTAssertEqual(changes, 1)
    }
}

@MainActor
final class SyncRecordTests: XCTestCase {
    private let profileID = UUID()

    func testZonesNameTheirProfile() {
        XCTAssertEqual(SyncRecords.profileID(of: SyncRecords.zoneID(for: profileID)), profileID)
        XCTAssertNil(SyncRecords.profileID(of: CKRecordZone.ID(zoneName: "other")))
    }

    func testBookmarksAndFoldersRoundTrip() {
        let zone = SyncRecords.zoneID(for: profileID)
        for item in [SyncedBookmark(parentID: UUID(), position: 3, title: "HN", url: URL(string: "https://news.ycombinator.com")),
                     SyncedBookmark(parentID: nil, position: 0, title: "Folder")] {
            let record = CKRecord(recordType: SyncRecords.bookmarkType,
                                  recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zone))
            SyncRecords.fill(record, with: item)
            XCTAssertEqual(SyncRecords.bookmark(from: record), item)
        }
    }

    func testDeviceTabsRoundTrip() {
        let device = DeviceTabs(id: "abc", name: "iPhone", platform: "iPhone",
                                tabs: [SyncedTab(title: "Apple", url: URL(string: "https://apple.com")!)],
                                modified: Date(timeIntervalSince1970: 1000))
        let record = CKRecord(recordType: SyncRecords.deviceTabsType,
                              recordID: CKRecord.ID(recordName: "device-abc", zoneID: SyncRecords.zoneID(for: profileID)))
        SyncRecords.fill(record, with: device)
        XCTAssertEqual(SyncRecords.deviceTabs(from: record), device)
        XCTAssertEqual(SyncRecords.record(fromSystemFields: SyncRecords.encodeSystemFields(of: record))?.recordID,
                       record.recordID)
    }

    func testAnUnsignedBuildNeverStartsSyncing() {
        let sync = CloudSync(directory: nil, defaults: UserDefaults(suiteName: "CloudSyncTests")!, deviceName: "Test",
                             platform: "Mac", isAvailable: false)
        XCTAssertFalse(sync.isEnabled)
        XCTAssertEqual(sync.status, .unavailable)
        sync.setEnabled(true)
        XCTAssertFalse(sync.isEnabled)
    }
}
