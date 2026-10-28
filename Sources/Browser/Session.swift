import AppKit
import Foundation
import Observation

struct TabSession: Codable, Equatable, Sendable {
    /// `nil` for a new tab.
    var url: URL?
    var title: String
    /// The archived back-forward history and scroll position. WebKit's interaction state is an `NSData`.
    var interactionState: Data?
    var isPinned = false

    private enum CodingKeys: String, CodingKey {
        case url, title, interactionState, isPinned
    }
}

extension TabSession {
    /// Tabs saved before pinning have no `isPinned`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        interactionState = try container.decodeIfPresent(Data.self, forKey: .interactionState)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

struct WindowSession: Codable, Equatable, Sendable {
    var tabs: [TabSession]
    var selectedIndex: Int
    /// The profile the window reopens in. Windows saved before profiles have none, and reopen in the profile the
    /// browser's data moved into.
    var profileID: UUID?
}

struct SessionSnapshot: Codable, Equatable, Sendable {
    /// The windows open when the app last quit, reopened on launch.
    var windows: [WindowSession] = []
    /// The windows that were open before the last one closed, for Reopen All Windows from Last Session.
    var closedWindows: [WindowSession] = []
}

/// Saves the open windows and their tabs, and reopens them on launch. Windows join with `attach(_:)`; a window
/// that shouldn't be remembered, such as a private one, just doesn't.
@MainActor
@Observable
final class SessionStore {
    private static let saveDelay: Duration = .seconds(2)

    /// What History ▸ Reopen All Windows from Last Session opens.
    private(set) var reopenableWindows: [WindowSession]
    @ObservationIgnored private let file: StoreFile?
    @ObservationIgnored private var browsers: [WeakBrowser] = []
    /// Saved windows waiting for a window to restore them into.
    @ObservationIgnored private var pendingWindows: [WindowSession]
    /// Windows already asked to open for `pendingWindows`, which shouldn't ask for more.
    @ObservationIgnored private var windowsBeingOpened = 0
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var observation = 0

    private struct WeakBrowser {
        weak var browser: BrowserModel?
    }

    /// Pass `nil` to keep nothing between launches. Without `restoresWindows`, the windows open when the app quit
    /// wait to be reopened from the History menu instead of reopening on launch.
    init(file: StoreFile? = .applicationSupport(named: "Session.plist"), restoresWindows: Bool = true) {
        self.file = file
        // Read right away, since the first window restores the session as soon as it appears.
        let saved = file?.readNow().flatMap { try? PropertyListDecoder().decode(SessionSnapshot.self, from: $0) }
            ?? SessionSnapshot()
        pendingWindows = restoresWindows ? saved.windows : []
        reopenableWindows = !restoresWindows && !saved.windows.isEmpty ? saved.windows
            : saved.windows.isEmpty ? saved.closedWindows : []
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveBeforeQuitting() }
        }
    }

    private var openBrowsers: [BrowserModel] {
        browsers.compactMap(\.browser)
    }

    var snapshot: SessionSnapshot {
        SessionSnapshot(windows: openBrowsers.map { $0.windowSession() }, closedWindows: reopenableWindows)
    }

    /// The profile of the next saved window waiting to reopen, for the window that opens on launch.
    var nextPendingProfileID: UUID? {
        pendingWindows.first?.profileID
    }

    /// Gives saved windows without a profile the fallback profile, and forgets the windows of deleted profiles.
    func assignProfiles(existing: Set<UUID>, fallback: UUID) {
        let assign = { (windows: [WindowSession]) in
            windows.compactMap { window -> WindowSession? in
                var window = window
                window.profileID = window.profileID ?? fallback
                return existing.contains(window.profileID ?? fallback) ? window : nil
            }
        }
        pendingWindows = assign(pendingWindows)
        reopenableWindows = assign(reopenableWindows)
    }

    /// Remembers a window from now on. A window that opens while saved windows are waiting restores the next one
    /// of its profile. Returns the profiles of the windows to open for the rest.
    func attach(_ browser: BrowserModel) -> [UUID?] {
        guard !openBrowsers.contains(where: { $0 === browser }) else { return [] }
        browsers.removeAll { $0.browser == nil }
        browsers.append(WeakBrowser(browser: browser))
        defer {
            observeBrowsers()
            scheduleSave()
        }
        guard let index = pendingWindows.firstIndex(where: { $0.profileID == browser.profileID }) else { return [] }
        browser.restoreSession(pendingWindows.remove(at: index))
        if windowsBeingOpened > 0 {
            windowsBeingOpened -= 1
            return []
        }
        windowsBeingOpened = pendingWindows.count
        return pendingWindows.map(\.profileID)
    }

    /// Forgets a window the user closed. Closing the last one keeps the windows for reopening later.
    func detach(_ browser: BrowserModel) {
        guard !isTerminating, openBrowsers.contains(where: { $0 === browser }) else { return }
        if openBrowsers.count == 1 {
            reopenableWindows = [browser.windowSession()]
        }
        browsers.removeAll { $0.browser == nil || $0.browser === browser }
        observeBrowsers()
        scheduleSave()
    }

    /// Restores the first window of its profile into `browser` when it only has a new tab, and returns the profiles
    /// of the windows to open for the rest.
    func reopenLastSession(reusing browser: BrowserModel?) -> [UUID?] {
        var windows = reopenableWindows
        reopenableWindows = []
        if let browser, browser.isBlank, let index = windows.firstIndex(where: { $0.profileID == browser.profileID }) {
            browser.restoreSession(windows.remove(at: index))
        }
        pendingWindows += windows
        windowsBeingOpened += windows.count
        scheduleSave()
        return windows.map(\.profileID)
    }

    /// Forgets the windows waiting to be reopened.
    func forgetClosedWindows() {
        reopenableWindows = []
        scheduleSave()
    }

    /// Forgets a profile's windows waiting to be reopened, for when its history is cleared.
    func forgetClosedWindows(in profileID: UUID?) {
        reopenableWindows.removeAll { $0.profileID == profileID }
        scheduleSave()
    }

    /// Forgets every saved window of a deleted profile.
    func forgetWindows(in profileID: UUID) {
        reopenableWindows.removeAll { $0.profileID == profileID }
        pendingWindows.removeAll { $0.profileID == profileID }
        scheduleSave()
    }

    /// Saves again whenever a window's tabs, their addresses or titles, or its selected tab change.
    private func observeBrowsers() {
        observation += 1
        let current = observation
        withObservationTracking {
            for browser in openBrowsers {
                _ = browser.activeTabID
                for tab in browser.tabs {
                    _ = tab.url
                    _ = tab.pageTitle
                    _ = tab.isNewTab
                    _ = tab.isPinned
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observation == current else { return }
                self.observeBrowsers()
                self.scheduleSave()
            }
        }
    }

    private func scheduleSave() {
        guard let file, !isTerminating else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard let self, !Task.isCancelled else { return }
            let snapshot = snapshot
            file.write { try? PropertyListEncoder.binary.encode(snapshot) }
        }
    }

    /// Saves the windows as they are, and ignores them closing as the app quits.
    func saveBeforeQuitting() {
        isTerminating = true
        saveTask?.cancel()
        file?.writeNow(try? PropertyListEncoder.binary.encode(snapshot))
    }
}
