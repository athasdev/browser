import CloudKit
import Foundation
import Observation
#if os(macOS)
import Security
#endif

/// Syncs each profile's bookmarks and open tabs through the user's private iCloud database, one zone per profile, so
/// the browser on their other Macs, iPhone, and iPad shows the same bookmarks and each other's tabs. History,
/// passwords, and website data stay on the device.
@MainActor
@Observable
final class CloudSync {
    static let containerIdentifier = "iCloud.dev.athas.browser"
    nonisolated static let enabledKey = "iCloudSyncEnabled"
    /// Devices whose tabs haven't changed for this long are left out, since they're likely gone.
    static let staleDeviceInterval: TimeInterval = 14 * 24 * 60 * 60
    /// How often changes are fetched while the app is open, for builds without push notifications.
    static let fetchInterval: Duration = .seconds(5 * 60)

    enum Status: Equatable {
        /// The build isn't signed for iCloud.
        case unavailable
        case off
        case syncing
        case upToDate(Date)
        case failed(String)
    }

    /// Whether the build is signed with the iCloud entitlement. Unsigned builds can't use CloudKit at all.
    let isAvailable: Bool
    private(set) var isEnabled: Bool
    private(set) var status: Status
    /// Other devices' open tabs in each profile, most recently changed first.
    private(set) var otherDevices: [UUID: [DeviceTabs]] = [:]
    /// The names of profiles synced from other devices, for devices without a profile of that ID.
    private(set) var remoteProfileNames: [UUID: String] = [:]

    let deviceID: String
    let deviceName: String
    let platform: String

    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var profiles: [UUID: Registration] = [:]
    @ObservationIgnored private var cache: Cache
    @ObservationIgnored private let cacheFile: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tabsTask: Task<Void, Never>?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?

    private struct Registration {
        var name: String
        let bookmarks: BookmarkStore
        let tabs: @MainActor () -> [SyncedTab]
    }

    /// What's known to be in iCloud, kept between launches to tell what changed here since.
    private struct Cache: Codable {
        var engineState: CKSyncEngine.State.Serialization?
        /// By zone name, then bookmark ID.
        var bookmarks: [String: [String: SyncedBookmark]] = [:]
        /// By record name and zone name.
        var systemFields: [String: Data] = [:]
        var devices: [String: [String: DeviceTabs]] = [:]
        var profileNames: [String: String] = [:]
        var sentTabs: [String: [SyncedTab]] = [:]
        var sentProfileNames: [String: String] = [:]
    }

    /// `directory` keeps what's known about iCloud between launches; `nil` keeps it in memory only.
    init(directory: URL?, defaults: UserDefaults = .standard, deviceName: String, platform: String,
         isAvailable: Bool = CloudSync.hasEntitlement()) {
        self.defaults = defaults
        self.isAvailable = isAvailable
        self.deviceName = deviceName
        self.platform = platform
        if let saved = defaults.string(forKey: "iCloudSyncDeviceID") {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "iCloudSyncDeviceID")
        }
        cacheFile = directory?.appending(path: "iCloudSync.json")
        cache = cacheFile.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
            ?? Cache()
        let isEnabled = isAvailable && defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.isEnabled = isEnabled
        status = isAvailable ? (isEnabled ? .syncing : .off) : .unavailable
        publishRemoteState()
        if isEnabled { start() }
    }

    /// Reads the signed entitlements, so a build without iCloud never touches CloudKit, which would crash it.
    nonisolated static func hasEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString,
                                                            nil) as? [String] else { return false }
        return services.contains("CloudKit")
        #elseif ICLOUD_SYNC
        return true
        #else
        return false
        #endif
    }

    // MARK: Profiles

    /// Syncs a profile's bookmarks, and lists its open tabs for other devices.
    func register(profileID: UUID, name: String, bookmarks: BookmarkStore,
                  tabs: @escaping @MainActor () -> [SyncedTab]) {
        profiles[profileID] = Registration(name: name, bookmarks: bookmarks, tabs: tabs)
        bookmarks.onChange = { [weak self] in self?.bookmarksDidChange(in: profileID) }
        guard isEnabled else { return }
        prepareZone(for: profileID)
        bookmarksDidChange(in: profileID)
        tabsDidChange(in: profileID, after: .zero)
        applyKnownBookmarks(to: profileID)
    }

    func renameProfile(_ profileID: UUID, to name: String) {
        profiles[profileID]?.name = name
        if isEnabled { profileDidChange(profileID) }
    }

    /// Removes a deleted profile's bookmarks and tabs from iCloud.
    func removeProfile(_ profileID: UUID) {
        profiles[profileID] = nil
        let zoneID = SyncRecords.zoneID(for: profileID)
        forgetZone(zoneID)
        engine?.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
    }

    // MARK: Turning sync on and off

    func setEnabled(_ isEnabled: Bool) {
        guard isAvailable, isEnabled != self.isEnabled else { return }
        self.isEnabled = isEnabled
        defaults.set(isEnabled, forKey: Self.enabledKey)
        if isEnabled {
            start()
            for profileID in profiles.keys {
                prepareZone(for: profileID)
                bookmarksDidChange(in: profileID)
                tabsDidChange(in: profileID, after: .zero)
            }
        } else {
            stop()
        }
    }

    /// Fetches and sends now, as when the app comes to the front.
    func syncNow() async {
        guard let engine else { return }
        status = .syncing
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            status = .upToDate(.now)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func start() {
        guard isAvailable, engine == nil else { return }
        let container = CKContainer(identifier: Self.containerIdentifier)
        let configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                       stateSerialization: cache.engineState, delegate: self)
        engine = CKSyncEngine(configuration)
        status = .syncing
        fetchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.fetchInterval)
                guard let engine = self?.engine else { return }
                try? await engine.fetchChanges()
            }
        }
    }

    /// Stops syncing and forgets what's in iCloud, leaving this device's bookmarks as they are.
    private func stop() {
        fetchTask?.cancel()
        tabsTask?.cancel()
        let engine = engine
        self.engine = nil
        Task { await engine?.cancelOperations() }
        cache = Cache()
        saveCache()
        publishRemoteState()
        status = .off
    }

    // MARK: Local changes

    private func prepareZone(for profileID: UUID) {
        let zoneID = SyncRecords.zoneID(for: profileID)
        guard cache.bookmarks[zoneID.zoneName] == nil else { return }
        cache.bookmarks[zoneID.zoneName] = [:]
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        profileDidChange(profileID)
    }

    private func profileDidChange(_ profileID: UUID) {
        let zoneID = SyncRecords.zoneID(for: profileID)
        guard let name = profiles[profileID]?.name, cache.sentProfileNames[zoneID.zoneName] != name else { return }
        engine?.state.add(pendingRecordZoneChanges: [
            .saveRecord(CKRecord.ID(recordName: SyncRecords.profileRecordName, zoneID: zoneID)),
        ])
    }

    /// Queues the bookmarks that differ from what's in iCloud.
    private func bookmarksDidChange(in profileID: UUID) {
        guard let engine, let registration = profiles[profileID] else { return }
        let zoneID = SyncRecords.zoneID(for: profileID)
        let current = BookmarkTree.flatten(registration.bookmarks.root)
        let known = cache.bookmarks[zoneID.zoneName] ?? [:]
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for (id, item) in current where known[id.uuidString] != item {
            changes.append(.saveRecord(CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)))
        }
        for name in known.keys where UUID(uuidString: name).map({ current[$0] == nil }) ?? true {
            changes.append(.deleteRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
        }
        if !changes.isEmpty { engine.state.add(pendingRecordZoneChanges: changes) }
    }

    /// Lists the profile's open tabs for other devices, a moment after they stop changing.
    func tabsDidChange(in profileID: UUID, after delay: Duration = .seconds(3)) {
        guard isEnabled else { return }
        tabsTask?.cancel()
        tabsTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            for id in self.profiles.keys {
                self.queueDeviceTabs(in: id)
            }
        }
    }

    private func queueDeviceTabs(in profileID: UUID) {
        guard let engine, let registration = profiles[profileID] else { return }
        let zoneID = SyncRecords.zoneID(for: profileID)
        guard cache.sentTabs[zoneID.zoneName] != registration.tabs() else { return }
        engine.state.add(pendingRecordZoneChanges: [
            .saveRecord(CKRecord.ID(recordName: SyncRecords.devicePrefix + deviceID, zoneID: zoneID)),
        ])
    }

    // MARK: Records

    private func record(for recordID: CKRecord.ID, bookmarks: [UUID: [UUID: SyncedBookmark]]) -> CKRecord? {
        guard let profileID = SyncRecords.profileID(of: recordID.zoneID), let registration = profiles[profileID] else {
            return nil
        }
        let name = recordID.recordName
        let type: String
        if name == SyncRecords.profileRecordName {
            type = SyncRecords.profileType
        } else if name.hasPrefix(SyncRecords.devicePrefix) {
            type = SyncRecords.deviceTabsType
        } else {
            type = SyncRecords.bookmarkType
        }
        let record = cache.systemFields[systemFieldsKey(recordID)].flatMap(SyncRecords.record(fromSystemFields:))
            .flatMap { $0.recordType == type ? $0 : nil }
            ?? CKRecord(recordType: type, recordID: recordID)
        switch type {
        case SyncRecords.profileType:
            record["name"] = registration.name
        case SyncRecords.deviceTabsType:
            SyncRecords.fill(record, with: DeviceTabs(id: deviceID, name: deviceName, platform: platform,
                                                      tabs: registration.tabs(), modified: .now))
        default:
            guard let id = UUID(uuidString: name), let item = bookmarks[profileID]?[id] else { return nil }
            SyncRecords.fill(record, with: item)
        }
        return record
    }

    private func systemFieldsKey(_ recordID: CKRecord.ID) -> String {
        "\(recordID.recordName)@\(recordID.zoneID.zoneName)"
    }

    // MARK: Remote changes

    private func apply(_ record: CKRecord) {
        let zoneName = record.recordID.zoneID.zoneName
        cache.systemFields[systemFieldsKey(record.recordID)] = SyncRecords.encodeSystemFields(of: record)
        switch record.recordType {
        case SyncRecords.bookmarkType:
            guard let item = SyncRecords.bookmark(from: record) else { return }
            cache.bookmarks[zoneName, default: [:]][record.recordID.recordName] = item
        case SyncRecords.deviceTabsType:
            guard let device = SyncRecords.deviceTabs(from: record) else { return }
            if device.id == deviceID {
                cache.sentTabs[zoneName] = device.tabs
            } else {
                cache.devices[zoneName, default: [:]][device.id] = device
            }
        case SyncRecords.profileType:
            cache.profileNames[zoneName] = record["name"] as? String
        default:
            break
        }
    }

    private func applyDeletion(of recordID: CKRecord.ID) {
        let zoneName = recordID.zoneID.zoneName
        cache.systemFields[systemFieldsKey(recordID)] = nil
        cache.bookmarks[zoneName]?[recordID.recordName] = nil
        if recordID.recordName.hasPrefix(SyncRecords.devicePrefix) {
            cache.devices[zoneName]?[String(recordID.recordName.dropFirst(SyncRecords.devicePrefix.count))] = nil
        }
    }

    /// Makes the profile's bookmarks match what's in iCloud, keeping the changes made here that haven't been sent.
    private func applyKnownBookmarks(to profileID: UUID, changedIDs: Set<String>? = nil) {
        guard let registration = profiles[profileID] else { return }
        let zoneName = SyncRecords.zoneID(for: profileID).zoneName
        guard let known = cache.bookmarks[zoneName], !known.isEmpty || changedIDs != nil else { return }
        var local = BookmarkTree.flatten(registration.bookmarks.root)
        let pending = Set((engine?.state.pendingRecordZoneChanges ?? []).compactMap { change -> String? in
            if case .saveRecord(let id) = change, id.zoneID.zoneName == zoneName { return id.recordName }
            if case .deleteRecord(let id) = change, id.zoneID.zoneName == zoneName { return id.recordName }
            return nil
        })
        let incoming = changedIDs ?? Set(known.keys)
        for name in incoming where !pending.contains(name) {
            guard let id = UUID(uuidString: name) else { continue }
            local[id] = known[name]
        }
        registration.bookmarks.replaceAll(with: BookmarkTree.build(local))
    }

    private func forgetZone(_ zoneID: CKRecordZone.ID) {
        let zoneName = zoneID.zoneName
        cache.bookmarks[zoneName] = nil
        cache.devices[zoneName] = nil
        cache.profileNames[zoneName] = nil
        cache.sentTabs[zoneName] = nil
        cache.sentProfileNames[zoneName] = nil
        cache.systemFields = cache.systemFields.filter { !$0.key.hasSuffix("@" + zoneName) }
    }

    /// Sends everything again, as after signing in to iCloud or when a zone was removed.
    private func resendEverything() {
        for profileID in profiles.keys {
            cache.bookmarks[SyncRecords.zoneID(for: profileID).zoneName] = nil
            prepareZone(for: profileID)
            bookmarksDidChange(in: profileID)
            queueDeviceTabs(in: profileID)
        }
    }

    private func publishRemoteState() {
        var devices: [UUID: [DeviceTabs]] = [:]
        var names: [UUID: String] = [:]
        let cutoff = Date.now.addingTimeInterval(-Self.staleDeviceInterval)
        for (zoneName, byDevice) in cache.devices {
            guard let profileID = SyncRecords.profileID(of: CKRecordZone.ID(zoneName: zoneName)) else { continue }
            devices[profileID] = byDevice.values
                .filter { $0.id != deviceID && $0.modified > cutoff && !$0.tabs.isEmpty }
                .sorted { $0.modified > $1.modified }
        }
        for (zoneName, name) in cache.profileNames {
            if let profileID = SyncRecords.profileID(of: CKRecordZone.ID(zoneName: zoneName)) { names[profileID] = name }
        }
        if devices != otherDevices { otherDevices = devices }
        if names != remoteProfileNames { remoteProfileNames = names }
    }

    private func saveCache() {
        guard let cacheFile, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
    }
}

extension CloudSync: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let update):
            cache.engineState = update.stateSerialization

        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                resendEverything()
            case .signOut, .switchAccounts:
                let state = cache.engineState
                cache = Cache()
                cache.engineState = state
                resendEverything()
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions {
                forgetZone(deletion.zoneID)
                // Another device deleted the profile, or the user removed the browser's iCloud data: keep this
                // device's bookmarks and send them again.
                if let profileID = SyncRecords.profileID(of: deletion.zoneID), profiles[profileID] != nil {
                    prepareZone(for: profileID)
                    bookmarksDidChange(in: profileID)
                }
            }

        case .fetchedRecordZoneChanges(let changes):
            var changedByZone: [String: Set<String>] = [:]
            for modification in changes.modifications {
                apply(modification.record)
                if modification.record.recordType == SyncRecords.bookmarkType {
                    changedByZone[modification.record.recordID.zoneID.zoneName, default: []]
                        .insert(modification.record.recordID.recordName)
                }
            }
            for deletion in changes.deletions {
                applyDeletion(of: deletion.recordID)
                if deletion.recordType == SyncRecords.bookmarkType {
                    changedByZone[deletion.recordID.zoneID.zoneName, default: []].insert(deletion.recordID.recordName)
                }
            }
            for (zoneName, names) in changedByZone {
                if let profileID = SyncRecords.profileID(of: CKRecordZone.ID(zoneName: zoneName)) {
                    applyKnownBookmarks(to: profileID, changedIDs: names)
                }
            }
            publishRemoteState()

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                apply(record)
                if record.recordType == SyncRecords.profileType {
                    cache.sentProfileNames[record.recordID.zoneID.zoneName] = record["name"] as? String
                }
            }
            for recordID in sent.deletedRecordIDs {
                applyDeletion(of: recordID)
            }
            for failure in sent.failedRecordSaves {
                let recordID = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    // Another device changed it first; its version wins.
                    if let server = failure.error.serverRecord {
                        apply(server)
                        if let profileID = SyncRecords.profileID(of: recordID.zoneID) {
                            applyKnownBookmarks(to: profileID, changedIDs: [recordID.recordName])
                        }
                    }
                case .zoneNotFound:
                    cache.bookmarks[recordID.zoneID.zoneName] = nil
                    if let profileID = SyncRecords.profileID(of: recordID.zoneID) { prepareZone(for: profileID) }
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                case .unknownItem:
                    cache.systemFields[systemFieldsKey(recordID)] = nil
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                default:
                    status = .failed(failure.error.localizedDescription)
                }
            }
            publishRemoteState()

        case .didFetchChanges, .didSendChanges:
            if case .failed = status {} else { status = .upToDate(.now) }

        case .willFetchChanges, .willSendChanges:
            status = .syncing

        case .sentDatabaseChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
        saveCache()
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        let bookmarks = profiles.mapValues { BookmarkTree.flatten($0.bookmarks.root) }
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        // CloudKit takes up to 400 changes in a request.
        for change in pending.prefix(350) {
            switch change {
            case .saveRecord(let recordID):
                if let record = record(for: recordID, bookmarks: bookmarks) {
                    recordsToSave.append(record)
                } else {
                    syncEngine.state.remove(pendingRecordZoneChanges: [change])
                }
            case .deleteRecord(let recordID):
                recordIDsToDelete.append(recordID)
            @unknown default:
                break
            }
        }
        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete)
    }
}
