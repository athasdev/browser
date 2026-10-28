import AppKit
import Foundation
import Observation
import SwiftUI
import WebKit

/// A profile's color, kept as sRGB components so a custom color survives relaunches.
struct ProfileColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        self.init(red: Double(resolved.redComponent), green: Double(resolved.greenComponent),
                  blue: Double(resolved.blueComponent))
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    /// The accent windows had before profiles, kept by the profile the browser's data moved into.
    static let slate = ProfileColor(red: 0.38, green: 0.49, blue: 0.54)
    static let presets: [ProfileColor] = [
        slate,
        ProfileColor(red: 0.20, green: 0.48, blue: 0.92),
        ProfileColor(red: 0.36, green: 0.36, blue: 0.84),
        ProfileColor(red: 0.62, green: 0.38, blue: 0.86),
        ProfileColor(red: 0.90, green: 0.34, blue: 0.58),
        ProfileColor(red: 0.88, green: 0.30, blue: 0.27),
        ProfileColor(red: 0.95, green: 0.55, blue: 0.20),
        ProfileColor(red: 0.90, green: 0.72, blue: 0.16),
        ProfileColor(red: 0.30, green: 0.70, blue: 0.38),
        ProfileColor(red: 0.18, green: 0.66, blue: 0.68),
    ]
}

/// What a profile's badge shows instead of the first letter of its name.
enum ProfileIcon: Codable, Hashable, Sendable {
    case emoji(String)
    case symbol(String)

    static let symbols = [
        "person.fill", "briefcase.fill", "house.fill", "graduationcap.fill", "building.2.fill", "star.fill",
        "heart.fill", "leaf.fill", "flame.fill", "bolt.fill", "gamecontroller.fill", "cart.fill",
        "airplane", "hammer.fill", "paintbrush.fill", "music.note", "book.fill", "globe",
    ]
}

struct BrowserProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var color: ProfileColor
    var icon: ProfileIcon?
    /// Whether the profile keeps its data where the browser kept everything before it had profiles, so nothing had
    /// to move to make it: WebKit's default data store, the files and settings without a profile's prefix, and the
    /// keychain items without a profile's ID.
    var usesOriginalStorage: Bool

    init(id: UUID = UUID(), name: String, color: ProfileColor, icon: ProfileIcon? = nil,
         usesOriginalStorage: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
        self.usesOriginalStorage = usesOriginalStorage
    }

    var displayName: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled Profile" : name
    }

    var initial: String {
        displayName.first.map { String($0).uppercased() } ?? "?"
    }
}

/// Which profile a new window opens in. Each request is unique, since SwiftUI brings an open window to the front
/// instead of opening another for a value it's already showing.
struct ProfileWindowRequest: Codable, Hashable {
    var profileID: UUID
    /// Pages the window opens in tabs, such as a bookmark opened in a new window.
    var urls: [URL] = []
    var token = UUID()
}

/// Where a profile keeps its data. A profile's website data has a WebKit data store of its own, its history a
/// folder of its own, and its settings, bookmarks, and passwords their own keys and keychain items.
struct ProfileStorage: Hashable, Sendable {
    static let historyFileName = "History.plist"
    static let profilesFolderName = "Profiles"
    /// The settings each profile has its own of.
    static let defaultsKeys = [
        BookmarkStore.storageKey, ZoomStore.storageKey, SitePermissions.storageKey, ContentBlocker.exceptionsKey,
        ContentBlocker.signatureKey, PasswordManager.offersToSaveKey, PasswordManager.neverSaveKey,
        WebExtensionStore.storageKey, SiteCompatibility.storageKey,
    ]

    let profileID: UUID
    let isOriginal: Bool
    /// The app's folder in Application Support, or `nil` to keep files in memory only.
    let directory: URL?

    init(profile: BrowserProfile, directory: URL?) {
        profileID = profile.id
        isOriginal = profile.usesOriginalStorage
        self.directory = directory
    }

    /// `nil` for WebKit's default data store.
    var dataStoreIdentifier: UUID? {
        isOriginal ? nil : profileID
    }

    /// The folder holding the profile's files. The original profile's are in the app's folder.
    var folder: URL? {
        isOriginal ? directory
            : directory?.appending(path: Self.profilesFolderName).appending(path: profileID.uuidString)
    }

    /// Where the profile's extensions are kept.
    var extensionsFolder: URL? {
        folder?.appending(path: WebExtensionStore.folderName)
    }

    var historyFile: StoreFile? {
        folder.map { StoreFile(url: $0.appending(path: Self.historyFileName)) }
    }

    var defaultsKeyPrefix: String {
        isOriginal ? "" : "profile.\(profileID.uuidString)."
    }

    var passwordItemDescription: String {
        isOriginal ? KeychainPasswordStorage.itemDescription
            : "\(KeychainPasswordStorage.itemDescription) (\(profileID.uuidString))"
    }

    var ruleListIdentifier: String {
        isOriginal ? ContentBlocker.ruleListIdentifier : "\(ContentBlocker.ruleListIdentifier)-\(profileID.uuidString)"
    }

    /// Removes the profile's settings and files. The original profile's folder is the app's, so only its own files go.
    func removeSavedData(from defaults: UserDefaults?, fileManager: FileManager = .default) {
        for key in Self.defaultsKeys {
            defaults?.removeObject(forKey: defaultsKeyPrefix + key)
        }
        guard let folder else { return }
        if isOriginal, let extensionsFolder { try? fileManager.removeItem(at: extensionsFolder) }
        try? fileManager.removeItem(at: isOriginal ? folder.appending(path: Self.historyFileName) : folder)
    }
}

/// What profiles keep their data in, replaced in unit tests.
@MainActor
struct ProfileServices {
    /// `nil` keeps profiles and their settings in memory only.
    var defaults: UserDefaults?
    /// The app's folder in Application Support, or `nil` to keep history in memory only.
    var directory: URL?
    var makePasswordStorage: @MainActor (ProfileStorage) -> PasswordStorage
    var makeDataStore: @MainActor (ProfileStorage) -> WKWebsiteDataStore
    /// `nil` never blocks trackers.
    var ruleListStore: WKContentRuleListStore?
    /// Removes a deleted profile's website data. It throws while a web view still uses the data store.
    var removeDataStore: @MainActor (ProfileStorage) async throws -> Void

    static var live: ProfileServices {
        ProfileServices(
            defaults: .standard,
            directory: StoreFile.applicationSupportDirectory,
            makePasswordStorage: { KeychainPasswordStorage(itemDescription: $0.passwordItemDescription) },
            makeDataStore: { $0.dataStoreIdentifier.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default() },
            ruleListStore: .default(),
            removeDataStore: { storage in
                if let identifier = storage.dataStoreIdentifier {
                    try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                } else {
                    await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                                  modifiedSince: .distantPast)
                }
            })
    }

    /// For when the app runs its unit tests, which shouldn't touch the user's profiles.
    static var inMemory: ProfileServices {
        ProfileServices(defaults: nil, directory: nil, makePasswordStorage: { _ in InMemoryPasswordStorage() },
                        makeDataStore: { _ in .nonPersistent() }, ruleListStore: nil, removeDataStore: { _ in })
    }
}

/// A profile's history, bookmarks, passwords, site settings, and website data, loaded when a window first needs them.
@MainActor
final class ProfileData {
    let id: UUID
    let storage: ProfileStorage
    let history: HistoryStore
    let bookmarks: BookmarkStore
    let passwords: PasswordManager
    let zoomLevels: ZoomStore
    let compatibility: SiteCompatibility
    let sitePermissions: SitePermissions
    let contentBlocker: ContentBlocker
    let websiteDataStore: WKWebsiteDataStore
    let browsingData: BrowsingData
    let extensions: WebExtensionStore

    init(storage: ProfileStorage, services: ProfileServices, session: SessionStore) {
        let defaults = services.defaults
        let prefix = storage.defaultsKeyPrefix
        id = storage.profileID
        self.storage = storage
        history = HistoryStore(file: storage.historyFile)
        bookmarks = BookmarkStore(defaults: defaults, keyPrefix: prefix)
        passwords = PasswordManager(storage: services.makePasswordStorage(storage), defaults: defaults,
                                    keyPrefix: prefix)
        zoomLevels = ZoomStore(defaults: defaults, keyPrefix: prefix)
        compatibility = SiteCompatibility(defaults: defaults, keyPrefix: prefix)
        sitePermissions = SitePermissions(defaults: defaults, keyPrefix: prefix)
        contentBlocker = ContentBlocker(defaults: defaults, store: services.ruleListStore, keyPrefix: prefix,
                                        ruleListIdentifier: storage.ruleListIdentifier)
        websiteDataStore = services.makeDataStore(storage)
        // Without a folder, as in unit tests, extensions are kept in memory only.
        let keepsExtensions = services.directory != nil
        extensions = WebExtensionStore(defaults: defaults, keyPrefix: prefix,
                                       folder: keepsExtensions ? storage.extensionsFolder : nil,
                                       persistentID: keepsExtensions ? storage.profileID : nil,
                                       dataStore: websiteDataStore)
        browsingData = BrowsingData(history: history, session: session, dataStore: websiteDataStore,
                                    profileID: storage.profileID)
    }
}

/// The user's profiles, like separate people using the browser: each keeps its own history, bookmarks, passwords,
/// cookies and website data, site settings, and windows. The browser's data from before it had profiles stays where
/// it was, in the profile made for it, "Personal".
@MainActor
@Observable
final class ProfileStore {
    static let profilesKey = "profiles"
    static let defaultProfileKey = "defaultProfile"
    /// Deleted profiles whose website data couldn't be removed yet, because a web view still used it.
    static let pendingRemovalsKey = "profileDataPendingRemoval"

    private(set) var profiles: [BrowserProfile]
    private(set) var defaultProfileID: UUID
    @ObservationIgnored let session: SessionStore
    /// Syncs each profile's bookmarks and open tabs with iCloud, or `nil` where nothing syncs, as in unit tests.
    @ObservationIgnored let sync: CloudSync?
    @ObservationIgnored private let services: ProfileServices
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var loaded: [UUID: ProfileData] = [:]
    @ObservationIgnored private var browsers: [WeakBrowser] = []

    private struct WeakBrowser {
        weak var browser: BrowserModel?
    }

    init(session: SessionStore, services: ProfileServices, sync: CloudSync? = nil) {
        self.session = session
        self.services = services
        self.sync = sync
        let defaults = services.defaults
        let saved = defaults?.data(forKey: Self.profilesKey)
            .flatMap { try? JSONDecoder().decode([BrowserProfile].self, from: $0) } ?? []
        if saved.isEmpty {
            let personal = BrowserProfile(name: "Personal", color: .slate, usesOriginalStorage: true)
            profiles = [personal]
            defaultProfileID = personal.id
            save()
        } else {
            profiles = saved
            let savedDefault = defaults?.string(forKey: Self.defaultProfileKey).flatMap(UUID.init(uuidString:))
            defaultProfileID = saved.first { $0.id == savedDefault }?.id ?? saved[0].id
        }
        session.assignProfiles(existing: Set(profiles.map(\.id)),
                               fallback: profiles.first(where: \.usesOriginalStorage)?.id ?? defaultProfileID)
        if !(defaults?.stringArray(forKey: Self.pendingRemovalsKey) ?? []).isEmpty {
            Task { await removePendingDataStores() }
        }
        if let sync {
            // Changes from other devices show up when the user comes back to the browser.
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { Task { await sync.syncNow() } }
                }
        }
    }

    /// The open web pages of a profile's normal windows, for its other devices.
    func openTabs(in profileID: UUID) -> [SyncedTab] {
        browsers(in: profileID).flatMap(\.tabs).compactMap { tab in
            guard !tab.isNewTab, let url = tab.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return nil
            }
            return SyncedTab(title: tab.title, url: url)
        }
    }

    var defaultProfile: BrowserProfile {
        profile(withID: defaultProfileID) ?? profiles[0]
    }

    func profile(withID id: UUID?) -> BrowserProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// A profile's data, or the default profile's for one that doesn't exist.
    func data(for id: UUID?) -> ProfileData {
        let profile = profile(withID: id) ?? defaultProfile
        if let data = loaded[profile.id] { return data }
        let data = ProfileData(storage: ProfileStorage(profile: profile, directory: services.directory),
                               services: services, session: session)
        loaded[profile.id] = data
        let profileID = profile.id
        data.extensions.windows = { [weak self] in self?.browsers(in: profileID) ?? [] }
        data.extensions.openWindow = { ExternalURLRouter.shared.openWindow(in: profileID, urls: $0) }
        sync?.register(profileID: profileID, name: profile.displayName, bookmarks: data.bookmarks) { [weak self] in
            self?.openTabs(in: profileID) ?? []
        }
        return data
    }

    /// The profile a window shows, or the one that opened a private window.
    func profile(for browser: BrowserModel) -> BrowserProfile? {
        profile(withID: browser.profileID ?? browser.openerProfileID)
    }

    /// Every window registers, so a deleted profile's windows can close.
    func register(_ browser: BrowserModel) {
        browsers.removeAll { $0.browser == nil || $0.browser === browser }
        browsers.append(WeakBrowser(browser: browser))
        if let profileID = browser.profileID, let sync {
            browser.onTabsChange = { sync.tabsDidChange(in: profileID) }
            sync.tabsDidChange(in: profileID)
        }
    }

    /// The frontmost normal window of a profile, for pages opened from a window that isn't a browser's, like the
    /// bookmarks manager.
    func frontmostBrowser(in profileID: UUID) -> BrowserModel? {
        browsers(in: profileID).first
    }

    /// The profile's normal windows, front to back.
    func browsers(in profileID: UUID) -> [BrowserModel] {
        let windows = NSApp.orderedWindows
        let frontToBack = { (browser: BrowserModel) in
            windows.firstIndex { $0 === browser.window } ?? .max
        }
        return browsers.compactMap(\.browser)
            .filter { $0.profileID == profileID }
            .sorted { frontToBack($0) < frontToBack($1) }
    }

    // MARK: Editing

    /// A new profile with the next preset color, not yet added.
    func makeProfile() -> BrowserProfile {
        let used = Set(profiles.map(\.color))
        let color = ProfileColor.presets.first { !used.contains($0) }
            ?? ProfileColor.presets[profiles.count % ProfileColor.presets.count]
        return BrowserProfile(name: "Profile \(profiles.count + 1)", color: color)
    }

    /// Adds a new profile, or saves changes to an existing one's name, color, and icon.
    func save(_ profile: BrowserProfile) {
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profile.usesOriginalStorage = profiles[index].usesOriginalStorage
            profiles[index] = profile
        } else {
            profile.usesOriginalStorage = false
            profiles.append(profile)
        }
        save()
        sync?.renameProfile(profile.id, to: profile.displayName)
    }

    func setDefault(_ id: UUID) {
        guard profile(withID: id) != nil else { return }
        defaultProfileID = id
        save()
    }

    /// Tracker blocking is on or off for every profile.
    func setTrackerBlocking(_ isEnabled: Bool) {
        data(for: defaultProfileID).contentBlocker.setEnabled(isEnabled)
        for data in loaded.values {
            data.contentBlocker.setEnabled(isEnabled)
        }
    }

    /// Closes the profile's windows, including private ones it opened, and removes everything it kept: history,
    /// bookmarks, passwords, site settings, saved windows, and website data. The last profile can't be deleted.
    func delete(_ id: UUID) async {
        guard profiles.count > 1, let profile = profile(withID: id) else { return }
        for browser in browsers.compactMap(\.browser)
        where browser.profileID == id || browser.openerProfileID == id {
            browser.window?.close()
        }
        browsers.removeAll { $0.browser == nil || $0.browser?.profileID == id || $0.browser?.openerProfileID == id }
        profiles.removeAll { $0.id == id }
        if defaultProfileID == id { defaultProfileID = profiles[0].id }
        save()
        sync?.removeProfile(id)
        session.forgetWindows(in: id)

        let storage = ProfileStorage(profile: profile, directory: services.directory)
        let data = loaded.removeValue(forKey: id)
        data?.history.stopSaving()
        await data?.extensions.removeAll()
        storage.removeSavedData(from: services.defaults)
        if let data {
            data.passwords.removeAll()
        } else {
            try? services.makePasswordStorage(storage).removeAll()
        }
        try? await services.ruleListStore?.removeContentRuleList(forIdentifier: storage.ruleListIdentifier)
        if storage.dataStoreIdentifier != nil {
            var pending = services.defaults?.stringArray(forKey: Self.pendingRemovalsKey) ?? []
            pending.append(id.uuidString)
            services.defaults?.set(pending, forKey: Self.pendingRemovalsKey)
            // The closed windows' web views let go of the data store once SwiftUI releases them.
            try? await Task.sleep(for: .seconds(1))
            await removePendingDataStores()
        } else {
            try? await services.removeDataStore(storage)
        }
    }

    /// Removes the website data of deleted profiles, keeping those still in use to try again on the next launch.
    func removePendingDataStores() async {
        let pending = services.defaults?.stringArray(forKey: Self.pendingRemovalsKey) ?? []
        var failed: [String] = []
        for id in pending {
            guard let uuid = UUID(uuidString: id), profile(withID: uuid) == nil else { continue }
            let storage = ProfileStorage(profile: BrowserProfile(id: uuid, name: "", color: .slate),
                                         directory: services.directory)
            do {
                try await services.removeDataStore(storage)
            } catch {
                failed.append(id)
            }
        }
        // Profiles deleted while this ran are still waiting.
        let current = services.defaults?.stringArray(forKey: Self.pendingRemovalsKey) ?? []
        services.defaults?.set(current.filter { !pending.contains($0) } + failed, forKey: Self.pendingRemovalsKey)
    }

    private func save() {
        guard let defaults = services.defaults else { return }
        defaults.set(try? JSONEncoder().encode(profiles), forKey: Self.profilesKey)
        defaults.set(defaultProfileID.uuidString, forKey: Self.defaultProfileKey)
    }
}
