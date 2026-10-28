import AppKit
import Observation
import OSLog
import WebKit

/// An extension a profile has installed, and what the user allowed it to do.
struct InstalledExtension: Codable, Identifiable, Hashable {
    enum Source: Codable, Hashable {
        /// Downloaded from the Chrome Web Store, and updated from it. The ID is the store's.
        case chromeWebStore(id: String)
        /// A ZIP archive, CRX package, or folder the user chose, copied into the profile.
        case file
        /// A Safari web extension inside an app the user installed, loaded from the app.
        case app(bundlePath: String)
    }

    /// The extension's unique identifier in WebKit, which also keeps its storage apart from other extensions'.
    let id: String
    var source: Source
    var name: String
    var version: String?
    var isEnabled = true
    var grantedPermissions: [String] = []
    var grantedMatchPatterns: [String] = []
    var deniedPermissions: [String] = []
    var deniedMatchPatterns: [String] = []
    var lastUpdateCheck: Date?
    /// A newer version asks for more than the user allowed, so it waits for the user to update it.
    var hasPendingUpdate = false

    var storeID: String? {
        if case .chromeWebStore(let id) = source { return id }
        return nil
    }
}

/// A profile's web extensions: Chrome and Safari WebExtensions that WebKit runs in the profile's normal windows.
/// Private windows run none, like Safari's default. Each profile's extensions keep their own storage.
@MainActor
@Observable
final class WebExtensionStore {
    nonisolated static let storageKey = "webExtensions"
    nonisolated static let folderName = "Extensions"
    nonisolated static let log = Logger(subsystem: "dev.athas.browser", category: "extensions")
    /// How often extensions from the Chrome Web Store are checked for a newer version.
    static let updateInterval: TimeInterval = 24 * 60 * 60

    private(set) var installed: [InstalledExtension] = []
    private(set) var loadErrors: [String: String] = [:]
    /// Changes whenever an extension's button changes, so toolbars redraw.
    private(set) var actionRevision = 0
    /// Store extensions being downloaded, so their store page shows progress.
    private(set) var installingStoreIDs: Set<String> = []
    @ObservationIgnored private(set) var contexts: [String: WKWebExtensionContext] = [:]

    let controller: WKWebExtensionController
    /// Whether extensions can be installed, which needs a folder to keep them in.
    let canInstall: Bool
    /// The profile's normal windows, front to back.
    @ObservationIgnored var windows: () -> [BrowserModel] = { [] }
    /// Opens a new window of the profile with the pages in tabs.
    @ObservationIgnored var openWindow: ([URL]) -> Void = { _ in }
    /// The toolbar button last clicked, which the extension's popover points to.
    @ObservationIgnored weak var popupAnchor: NSView?

    @ObservationIgnored private let delegate = WebExtensionControllerDelegate()
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let defaultsKey: String
    @ObservationIgnored private let folder: URL?
    @ObservationIgnored private var openWindowIDs: Set<ObjectIdentifier> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var keyMonitor: Any?

    /// A profile's extensions keep their files in `folder` and their storage under `persistentID`. Without either,
    /// as in unit tests, nothing is kept.
    init(defaults: UserDefaults?, keyPrefix: String = "", folder: URL?, persistentID: UUID?,
         dataStore: WKWebsiteDataStore) {
        self.defaults = defaults
        defaultsKey = keyPrefix + Self.storageKey
        self.folder = folder
        canInstall = folder != nil
        let configuration = persistentID.map { WKWebExtensionController.Configuration(identifier: $0) }
            ?? .nonPersistent()
        configuration.defaultWebsiteDataStore = dataStore
        let webViewConfiguration = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        webViewConfiguration.applicationNameForUserAgent = ExtensionCompatibility.applicationNameForUserAgent
        configuration.webViewConfiguration = webViewConfiguration
        controller = WKWebExtensionController(configuration: configuration)
        installed = defaults?.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode([InstalledExtension].self, from: $0) } ?? []
        delegate.store = self
        controller.delegate = delegate
        observeWindowsAndPermissions()
        guard !installed.isEmpty else { return }
        Task {
            for record in installed where record.isEnabled {
                await load(record)
            }
            await checkForUpdates()
        }
    }

    /// The loaded extensions with a toolbar button, in the order they were installed.
    var loadedContexts: [(record: InstalledExtension, context: WKWebExtensionContext)] {
        installed.compactMap { record in contexts[record.id].map { (record, $0) } }
    }

    func record(withID id: String) -> InstalledExtension? {
        installed.first { $0.id == id }
    }

    func isInstalled(storeID: String) -> Bool {
        installed.contains { $0.storeID == storeID }
    }

    func icon(for record: InstalledExtension, size: CGFloat = 32) -> NSImage? {
        contexts[record.id]?.webExtension.icon(for: CGSize(width: size, height: size))
    }

    // MARK: Installing

    /// Downloads an extension from the Chrome Web Store and asks the user to add it. Adding one that's installed
    /// updates it.
    func installFromChromeWebStore(_ storeID: String, in window: NSWindow?) async {
        guard canInstall, ChromeWebStore.isExtensionID(storeID), !installingStoreIDs.contains(storeID) else { return }
        installingStoreIDs.insert(storeID)
        defer { installingStoreIDs.remove(storeID) }
        do {
            let archive = try await ChromeWebStore.downloadArchive(for: storeID)
            let staged = try stage(archive: archive)
            try await install(from: staged, id: storeID, source: .chromeWebStore(id: storeID), in: window)
        } catch {
            await WebExtensionPrompts.showError(error, title: "Couldn’t add the extension", in: window)
        }
    }

    /// Installs a ZIP archive, CRX package, or unpacked folder the user chose.
    func install(fromFile url: URL, in window: NSWindow?) async {
        guard canInstall else { return }
        do {
            let staged: URL
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                staged = try stage(directory: url)
            } else {
                staged = try stage(archive: ChromeWebStore.archive(fromPackage: Data(contentsOf: url)))
            }
            try await install(from: staged, id: UUID().uuidString, source: .file, in: window)
        } catch {
            await WebExtensionPrompts.showError(error, title: "Couldn’t add the extension", in: window)
        }
    }

    /// Adds a Safari web extension from an installed app. Its files stay in the app.
    func installAppExtension(at bundleURL: URL, in window: NSWindow?) async {
        do {
            guard let bundle = Bundle(url: bundleURL) else { throw CocoaError(.fileReadNoSuchFile) }
            let webExtension = try await WKWebExtension(appExtensionBundle: bundle)
            let id = installed.first { $0.source == .app(bundlePath: bundleURL.path) }?.id ?? UUID().uuidString
            try await add(webExtension, id: id, source: .app(bundlePath: bundleURL.path), in: window)
        } catch {
            await WebExtensionPrompts.showError(error, title: "Couldn’t add the extension", in: window)
        }
    }

    /// Validates a staged extension, asks the user, and moves it into place.
    private func install(from staged: URL, id: String, source: InstalledExtension.Source,
                         in window: NSWindow?) async throws {
        defer { try? FileManager.default.removeItem(at: staged) }
        let webExtension = try await WKWebExtension(resourceBaseURL: staged)
        guard await WebExtensionPrompts.confirmInstall(webExtension, in: window) else { return }
        unload(id)
        try await moveIntoPlace(staged, id: id)
        let installedExtension = try await WKWebExtension(resourceBaseURL: fileURL(forID: id))
        try await add(installedExtension, id: id, source: source, in: nil, confirmed: true)
    }

    /// Records an extension with everything it asks for allowed, and loads it.
    private func add(_ webExtension: WKWebExtension, id: String, source: InstalledExtension.Source,
                     in window: NSWindow?, confirmed: Bool = false) async throws {
        if !confirmed {
            guard await WebExtensionPrompts.confirmInstall(webExtension, in: window) else { return }
        }
        unload(id)
        var record = InstalledExtension(id: id, source: source, name: Self.name(of: webExtension),
                                        version: webExtension.version)
        record.grantedPermissions = webExtension.requestedPermissions.map(\.rawValue).sorted()
        record.grantedMatchPatterns = webExtension.allRequestedMatchPatterns.map(\.string).sorted()
        record.lastUpdateCheck = .now
        if let index = installed.firstIndex(where: { $0.id == id }) {
            installed[index] = record
        } else {
            installed.append(record)
        }
        save()
        await load(record, webExtension: webExtension)
    }

    // MARK: Managing

    func setEnabled(_ isEnabled: Bool, for id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }), installed[index].isEnabled != isEnabled else {
            return
        }
        installed[index].isEnabled = isEnabled
        save()
        if isEnabled {
            let record = installed[index]
            Task { await load(record) }
        } else {
            unload(id)
        }
    }

    /// Removes an extension with its files and the data it stored.
    func remove(_ id: String) async {
        guard let record = record(withID: id) else { return }
        let context = contexts[id]
        unload(id)
        installed.removeAll { $0.id == id }
        loadErrors[id] = nil
        save()
        // An app's extension stays in the app.
        let hasOwnFiles = if case .app = record.source { false } else { true }
        if hasOwnFiles, let folder {
            try? FileManager.default.removeItem(at: folder.appending(path: id))
            try? FileManager.default.removeItem(at: folder.appending(path: "\(id).zip"))
        }
        if let context,
           let dataRecord = await controller.dataRecord(ofTypes: WKWebExtensionController.allExtensionDataTypes,
                                                        for: context) {
            await controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: [dataRecord])
        }
    }

    /// Removes every extension, for a profile that's being deleted.
    func removeAll() async {
        for record in installed {
            await remove(record.id)
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Opens the extension's settings page in a new tab of the frontmost window.
    func openOptions(for id: String) {
        guard let url = contexts[id]?.optionsPageURL else { return }
        if let browser = windows().first {
            browser.open(url, inNewTab: true)
            browser.window?.makeKeyAndOrderFront(nil)
        } else {
            openWindow([url])
        }
    }

    /// Clicks an extension's toolbar button for the window's active tab, showing its popover under `anchor`.
    func performAction(of id: String, in browser: BrowserModel, anchor: NSView?) {
        guard let context = contexts[id] else { return }
        popupAnchor = anchor
        context.performAction(for: browser.activeTab?.extensionTab)
    }

    func action(of id: String, in browser: BrowserModel) -> WKWebExtension.Action? {
        contexts[id]?.action(for: browser.activeTab?.extensionTab)
    }

    /// Items the extensions add to a page's context menu.
    func menuItems(for tab: BrowserTab) -> [NSMenuItem] {
        loadedContexts.flatMap { $0.context.menuItems(for: tab.extensionTab) }
    }

    func actionDidChange() {
        actionRevision += 1
    }

    // MARK: Updating

    /// Updates Chrome Web Store extensions not checked within a day, or all of them when `force` is set. An update
    /// that asks for more than the user allowed waits for the user, who updates it from Settings.
    func checkForUpdates(force: Bool = false) async {
        guard canInstall else { return }
        for record in installed {
            guard let storeID = record.storeID,
                  force || record.lastUpdateCheck.map({ -$0.timeIntervalSinceNow > Self.updateInterval }) ?? true
            else { continue }
            await update(record, storeID: storeID)
        }
    }

    private func update(_ record: InstalledExtension, storeID: String) async {
        defer { setLastUpdateCheck(.now, for: record.id) }
        guard let archive = try? await ChromeWebStore.downloadArchive(for: storeID),
              let staged = try? stage(archive: archive) else { return }
        defer { try? FileManager.default.removeItem(at: staged) }
        guard let candidate = try? await WKWebExtension(resourceBaseURL: staged),
              let newVersion = candidate.version,
              Self.isVersion(newVersion, newerThan: record.version) else { return }
        let asked = Set(candidate.requestedPermissions.map(\.rawValue))
        let askedPatterns = Set(candidate.allRequestedMatchPatterns.map(\.string))
        guard asked.isSubset(of: record.grantedPermissions), askedPatterns.isSubset(of: record.grantedMatchPatterns)
        else {
            modify(record.id) { $0.hasPendingUpdate = true }
            return
        }
        unload(record.id)
        do {
            try await moveIntoPlace(staged, id: record.id)
        } catch {
            if record.isEnabled { await load(record) }
            return
        }
        modify(record.id) {
            $0.version = newVersion
            $0.hasPendingUpdate = false
        }
        if let updated = self.record(withID: record.id), updated.isEnabled { await load(updated) }
    }

    nonisolated static func isVersion(_ version: String, newerThan installed: String?) -> Bool {
        guard let installed else { return true }
        return version.compare(installed, options: .numeric) == .orderedDescending
    }

    private func setLastUpdateCheck(_ date: Date, for id: String) {
        modify(id) { $0.lastUpdateCheck = date }
    }

    // MARK: Loading

    private func load(_ record: InstalledExtension, webExtension: WKWebExtension? = nil) async {
        guard contexts[record.id] == nil else { return }
        do {
            let webExtension = if let webExtension { webExtension } else { try await makeExtension(for: record) }
            guard self.record(withID: record.id)?.isEnabled == true, contexts[record.id] == nil else { return }
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = record.id
            context.inspectionName = record.name
            #if DEBUG
            context.isInspectable = true
            #endif
            for permission in record.grantedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission))
            }
            for permission in record.deniedPermissions {
                context.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.Permission(rawValue: permission))
            }
            for pattern in record.grantedMatchPatterns.compactMap(Self.matchPattern) {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            for pattern in record.deniedMatchPatterns.compactMap(Self.matchPattern) {
                context.setPermissionStatus(.deniedExplicitly, for: pattern)
            }
            try controller.load(context)
            contexts[record.id] = context
            loadErrors[record.id] = nil
            modify(record.id) {
                $0.name = Self.name(of: webExtension)
                $0.version = webExtension.version ?? $0.version
            }
            actionRevision += 1
        } catch {
            loadErrors[record.id] = error.localizedDescription
            Self.log.error("Couldn’t load \(record.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func unload(_ id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
        actionRevision += 1
    }

    private func makeExtension(for record: InstalledExtension) async throws -> WKWebExtension {
        if case .app(let path) = record.source {
            guard let bundle = Bundle(path: path) else { throw CocoaError(.fileReadNoSuchFile) }
            return try await WKWebExtension(appExtensionBundle: bundle)
        }
        return try await WKWebExtension(resourceBaseURL: await fileURL(forID: record.id))
    }

    /// Keeps what the user allowed or refused when the extension asks while it runs.
    private func savePermissions(ofContextWithID contextID: ObjectIdentifier) {
        guard let (id, context) = contexts.first(where: { ObjectIdentifier($0.value) == contextID }) else { return }
        modify(id) {
            $0.grantedPermissions = context.grantedPermissions.keys.map(\.rawValue).sorted()
            $0.deniedPermissions = context.deniedPermissions.keys.map(\.rawValue).sorted()
            $0.grantedMatchPatterns = context.grantedPermissionMatchPatterns.keys.map(\.string).sorted()
            $0.deniedMatchPatterns = context.deniedPermissionMatchPatterns.keys.map(\.string).sorted()
        }
    }

    private static func matchPattern(_ string: String) -> WKWebExtension.MatchPattern? {
        try? WKWebExtension.MatchPattern(string: string)
    }

    static func name(of webExtension: WKWebExtension) -> String {
        webExtension.displayName ?? webExtension.displayShortName ?? "Extension"
    }

    // MARK: Files

    /// An archive or folder copied next to the installed extensions, where WebKit can read it while the user decides.
    private func stage(archive: Data) throws -> URL {
        guard let folder else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: ".staging-\(UUID().uuidString).zip")
        try archive.write(to: url, options: .atomic)
        return url
    }

    private func stage(directory: URL) throws -> URL {
        guard let folder else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: ".staging-\(UUID().uuidString)")
        let isScoped = directory.startAccessingSecurityScopedResource()
        defer { if isScoped { directory.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: directory, to: url)
        return url
    }

    /// Replaces the extension's files with the staged ones, unpacked into a folder and patched for the APIs WebKit
    /// lacks. The work happens off the main thread, since large extensions take a moment to unpack.
    private func moveIntoPlace(_ staged: URL, id: String) async throws {
        guard let folder else { throw CocoaError(.fileWriteNoPermission) }
        try await Task.detached {
            let fileManager = FileManager.default
            let unpacked = folder.appending(path: ".unpacking-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: unpacked) }
            if staged.pathExtension == "zip" {
                try ExtensionCompatibility.unzip(staged, to: unpacked)
            } else {
                try fileManager.copyItem(at: staged, to: unpacked)
            }
            try ExtensionCompatibility.patch(directory: unpacked)
            let destination = folder.appending(path: id)
            for existing in [folder.appending(path: "\(id).zip"), destination]
            where fileManager.fileExists(atPath: existing.path) {
                try fileManager.removeItem(at: existing)
            }
            try fileManager.moveItem(at: unpacked, to: destination)
        }.value
    }

    /// The extension's folder, after unpacking an archive kept by an earlier version and patching it again, so it
    /// gets the current compatibility script.
    private func fileURL(forID id: String) async throws -> URL {
        guard let folder else { throw CocoaError(.fileReadNoSuchFile) }
        let archive = folder.appending(path: "\(id).zip")
        let directory = folder.appending(path: id)
        if FileManager.default.fileExists(atPath: archive.path) {
            try await moveIntoPlace(archive, id: id)
        } else {
            try await Task.detached { try ExtensionCompatibility.patch(directory: directory) }.value
        }
        return directory
    }

    private func modify(_ id: String, _ change: (inout InstalledExtension) -> Void) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        var record = installed[index]
        change(&record)
        guard record != installed[index] else { return }
        installed[index] = record
        save()
    }

    private func save() {
        defaults?.set(try? JSONEncoder().encode(installed), forKey: defaultsKey)
    }

    // MARK: Safari extensions in apps

    /// Safari web extensions inside installed apps, which can run here too. Features that talk to their app, such as
    /// a password manager's, need the app's own browser support and don't work.
    nonisolated static func appExtensionBundles(fileManager: FileManager = .default) -> [URL] {
        let folders = [URL(filePath: "/Applications"), fileManager.homeDirectoryForCurrentUser.appending(path: "Applications")]
        return folders.flatMap { folder -> [URL] in
            let apps = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return apps.filter { $0.pathExtension == "app" }.flatMap { app -> [URL] in
                let plugIns = app.appending(path: "Contents/PlugIns")
                let bundles = (try? fileManager.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)) ?? []
                return bundles.filter { bundle in
                    guard bundle.pathExtension == "appex",
                          let info = NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")),
                          let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String
                    else { return false }
                    return point == "com.apple.Safari.web-extension"
                }
            }
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Windows and tabs

    /// The profile's main window, or else its frontmost one. An extension's popover becomes the key window while
    /// it's open, but the window it belongs to stays the main window, which is the one the popover asks about.
    var focusedBrowser: BrowserModel? {
        let windows = windows()
        return windows.first { $0.window?.isMainWindow == true } ?? windows.first
    }

    func didOpenWindow(_ browser: BrowserModel) {
        guard openWindowIDs.insert(ObjectIdentifier(browser)).inserted else { return }
        controller.didOpenWindow(browser.extensionWindow)
        for tab in browser.tabs {
            controller.didOpenTab(tab.extensionTab)
        }
        if let tab = browser.activeTab { controller.didActivateTab(tab.extensionTab) }
        if browser.window?.isMainWindow == true { controller.didFocusWindow(browser.extensionWindow) }
    }

    func didCloseWindow(_ browser: BrowserModel) {
        guard openWindowIDs.remove(ObjectIdentifier(browser)) != nil else { return }
        for tab in browser.tabs {
            controller.didCloseTab(tab.extensionTab, windowIsClosing: true)
        }
        controller.didCloseWindow(browser.extensionWindow)
    }

    /// Reports tabs that opened, closed, or moved, comparing the window's tabs with what they were.
    func tabsDidChange(in browser: BrowserModel, from oldTabs: [BrowserTab]) {
        guard openWindowIDs.contains(ObjectIdentifier(browser)) else { return }
        let oldIDs = Set(oldTabs.map(\.id))
        let newIDs = Set(browser.tabs.map(\.id))
        for tab in oldTabs where !newIDs.contains(tab.id) {
            controller.didCloseTab(tab.extensionTab)
        }
        for tab in browser.tabs where !oldIDs.contains(tab.id) {
            controller.didOpenTab(tab.extensionTab)
        }
        let keptBefore = oldTabs.filter { newIDs.contains($0.id) }
        let keptAfter = browser.tabs.filter { oldIDs.contains($0.id) }
        for (index, tab) in keptAfter.enumerated() where keptBefore[index] !== tab {
            guard let oldIndex = oldTabs.firstIndex(where: { $0 === tab }) else { continue }
            controller.didMoveTab(tab.extensionTab, from: oldIndex, in: browser.extensionWindow)
        }
    }

    func didActivate(_ tab: BrowserTab?, previous: BrowserTab?, in browser: BrowserModel) {
        guard openWindowIDs.contains(ObjectIdentifier(browser)), let tab else { return }
        controller.didActivateTab(tab.extensionTab, previousActiveTab: previous?.extensionTab)
    }

    func tabDidChange(_ tab: BrowserTab, _ properties: WKWebExtension.TabChangedProperties) {
        guard let browser = tab.browser, openWindowIDs.contains(ObjectIdentifier(browser)),
              browser.tabs.contains(where: { $0 === tab }) else { return }
        controller.didChangeTabProperties(properties, for: tab.extensionTab)
    }

    private func observeWindowsAndPermissions() {
        // Only a browser window becoming main changes the focused window: popovers, panels, and Settings don't.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification,
                                                                object: nil, queue: .main) { [weak self] note in
            let windowID = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, !self.contexts.isEmpty,
                      let browser = self.windows().first(where: { $0.window.map(ObjectIdentifier.init) == windowID })
                else { return }
                self.controller.didFocusWindow(browser.extensionWindow)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification,
                                                                object: nil, queue: .main) { note in
            let context = note.object as? WKWebExtensionContext
            let name = context?.webExtension.displayName ?? "Extension"
            let errors = context?.errors.map(\.localizedDescription) ?? []
            for error in errors {
                Self.log.error("\(name, privacy: .public): \(error, privacy: .public)")
            }
        })
        let permissionNotifications: [Notification.Name] = [
            WKWebExtensionContext.permissionsWereGrantedNotification,
            WKWebExtensionContext.permissionsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionsWereRemovedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification,
        ]
        for name in permissionNotifications {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil,
                                                                    queue: .main) { [weak self] note in
                guard let contextID = (note.object as? WKWebExtensionContext).map(ObjectIdentifier.init) else { return }
                MainActor.assumeIsolated { self?.savePermissions(ofContextWithID: contextID) }
            })
        }
        // Extensions' keyboard shortcuts work in the profile's windows.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isHandled = MainActor.assumeIsolated { self?.performCommand(for: event) ?? false }
            return isHandled ? nil : event
        }
    }

    private func performCommand(for event: NSEvent) -> Bool {
        guard !contexts.isEmpty, windows().contains(where: { $0.window === event.window }) else { return false }
        return loadedContexts.contains { $0.context.performCommand(for: event) }
    }
}
