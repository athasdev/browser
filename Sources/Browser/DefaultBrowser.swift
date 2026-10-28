import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Whether macOS opens web links from other apps in this app, and asks it to.
@MainActor
@Observable
final class DefaultBrowser {
    private(set) var isDefault = false

    func refresh() {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
            isDefault = false
            return
        }
        isDefault = Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// macOS asks the user to confirm before it changes the default browser.
    func makeDefault() async {
        let app = Bundle.main.bundleURL
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http")
            // macOS usually changes HTTPS along with HTTP, which would make asking again a second prompt.
            refresh()
            if !isDefault {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https")
            }
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .html)
        } catch {
            // The user kept their current browser.
        }
        refresh()
    }
}

/// Opens the links and files other apps hand to the browser, such as a link clicked in Mail once it's the default
/// browser: in new tabs of the frontmost normal window, or in a new window when only private windows are open.
@MainActor
final class ExternalURLRouter {
    static let shared = ExternalURLRouter()

    private var browsers: [WeakBrowser] = []
    /// Links waiting for the window that was asked to open for them.
    private var pendingURLs: [URL] = []
    private var isOpeningWindow = false
    private var openWindow: OpenWindowAction?

    private struct WeakBrowser {
        weak var browser: BrowserModel?
    }

    /// Web pages and local files open; other schemes, like `javascript:`, are ignored.
    static func canOpen(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": url.host()?.isEmpty == false
        case "file": url.isFileURL
        default: false
        }
    }

    /// The first normal window of those open, front to back. A private window never takes links from other apps,
    /// since the user didn't choose to open them privately.
    static func destination(among browsers: [BrowserModel]) -> BrowserModel? {
        browsers.first { !$0.isPrivate }
    }

    /// A window joins when it appears, and takes the links that were waiting for a window to open.
    func register(_ browser: BrowserModel, openWindow: OpenWindowAction? = nil) {
        if let openWindow { self.openWindow = openWindow }
        browsers.removeAll { $0.browser == nil || $0.browser === browser }
        browsers.append(WeakBrowser(browser: browser))
        guard !browser.isPrivate else { return }
        isOpeningWindow = false
        let urls = pendingURLs
        pendingURLs = []
        browser.openInNewTabs(urls)
    }

    /// Opens a new window of a profile, with the pages in tabs.
    func openWindow(in profileID: UUID, urls: [URL]) {
        openWindow?(id: BrowserApp.windowID, value: ProfileWindowRequest(profileID: profileID, urls: urls))
    }

    func open(_ urls: [URL]) {
        let urls = urls.filter(Self.canOpen)
        guard !urls.isEmpty else { return }
        let windows = NSApp.orderedWindows
        let frontToBack = { (browser: BrowserModel) in
            windows.firstIndex { $0 === browser.window } ?? .max
        }
        let open = browsers.compactMap(\.browser).sorted { frontToBack($0) < frontToBack($1) }
        if let browser = Self.destination(among: open) {
            browser.openInNewTabs(urls)
            if let window = browser.window {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
            return
        }
        // At launch the first window appears on its own, and takes the links when it registers.
        pendingURLs += urls
        if let openWindow, !isOpeningWindow {
            isOpeningWindow = true
            openWindow(id: BrowserApp.windowID)
        }
    }
}

final class BrowserAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Passkeys.shared.requestAuthorizationIfNeeded()
    }

    /// Links and HTML files opened from other apps and the Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalURLRouter.shared.open(urls)
    }
}
