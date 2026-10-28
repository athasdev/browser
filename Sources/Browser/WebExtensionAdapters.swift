import AppKit
import WebKit

/// A tab as extensions see it, through the `tabs` API. Each tab keeps one, so extensions see the same tab
/// whenever they ask, even while it's suspended.
@MainActor
final class WebExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: BrowserTab?

    private var browser: BrowserModel? {
        tab?.browser
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        browser?.extensionWindow
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, let index = browser?.tabs.firstIndex(where: { $0 === tab }) else { return NSNotFound }
        return index
    }

    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        browser?.tab(withID: tab?.openerID)?.extensionTab
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        tab?.webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        tab?.title
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        tab?.isPinned ?? false
    }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab { browser?.setPinned(pinned, for: tab.id) }
        completionHandler(nil)
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        tab?.contentView.bounds.size ?? .zero
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        tab?.pageZoom ?? 1
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext,
                       completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.setZoom(zoomFactor)
        completionHandler(nil)
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        tab?.url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(tab?.isLoading ?? false)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext,
                completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin, let webView = tab?.webView {
            webView.reloadFromOrigin()
        } else {
            tab?.reload()
        }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.webView?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab, let browser {
            browser.activeTabID = tab.id
            browser.window?.makeKeyAndOrderFront(nil)
        }
        completionHandler(nil)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let tab else { return false }
        return browser?.activeTabID == tab.id
    }

    func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let tab, let browser else { return completionHandler(nil, nil) }
        browser.duplicateTab(tab.id)
        completionHandler(browser.activeTab?.extensionTab, nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab { browser?.closeTab(tab.id) }
        completionHandler(nil)
    }
}

/// A window as extensions see it, through the `windows` API.
@MainActor
final class WebExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var browser: BrowserModel?

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        browser?.tabs.map(\.extensionTab) ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        browser?.activeTab?.extensionTab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = browser?.window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext,
                        completionHandler: @escaping ((any Error)?) -> Void) {
        guard let window = browser?.window else { return completionHandler(nil) }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        switch state {
        case .minimized:
            window.miniaturize(nil)
        case .fullscreen:
            if !isFullScreen { window.toggleFullScreen(nil) }
        case .maximized:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if !window.isZoomed { window.zoom(nil) }
        case .normal:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if isFullScreen { window.toggleFullScreen(nil) }
        @unknown default:
            break
        }
        completionHandler(nil)
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        browser?.isPrivate ?? false
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        browser?.window?.screen?.frame ?? NSScreen.main?.frame ?? .zero
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        browser?.window?.frame ?? .zero
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext,
                  completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.window?.setFrame(frame, display: true, animate: true)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.window?.performClose(nil)
        completionHandler(nil)
    }
}

/// Answers what extensions ask the browser for: its windows and tabs, new tabs and windows, permissions, and
/// popovers.
@MainActor
final class WebExtensionControllerDelegate: NSObject, WKWebExtensionControllerDelegate {
    weak var store: WebExtensionStore?

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        store?.windows().map(\.extensionWindow) ?? []
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        store?.focusedBrowser?.extensionWindow
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let store else { return completionHandler(nil, nil) }
        let browser = (configuration.window as? WebExtensionWindow)?.browser
            ?? store.focusedBrowser ?? store.windows().first
        guard let browser else {
            store.openWindow(configuration.url.map { [$0] } ?? [])
            return completionHandler(nil, nil)
        }
        let previousID = browser.activeTabID
        browser.open(configuration.url ?? URL(string: "about:blank")!, inNewTab: true)
        guard let tab = browser.activeTab else { return completionHandler(nil, nil) }
        if configuration.shouldBePinned { browser.setPinned(true, for: tab.id) }
        if !configuration.shouldBeActive, let previousID { browser.activeTabID = previousID }
        completionHandler(tab.extensionTab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        guard let store else { return completionHandler(nil, nil) }
        let existing = Set(store.windows().map(ObjectIdentifier.init))
        store.openWindow(configuration.tabURLs)
        // SwiftUI opens the window on its next update, and the window registers when it appears.
        Task { @MainActor in
            for _ in 0..<40 {
                if let browser = store.windows().first(where: { !existing.contains(ObjectIdentifier($0)) }) {
                    return completionHandler(browser.extensionWindow, nil)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            completionHandler(nil, nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        store?.openOptions(for: extensionContext.uniqueIdentifier)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        Task {
            let isAllowed = await WebExtensionPrompts.askForAccess(
                extensionContext, to: WebExtensionPrompts.describe(permissions, patterns: []),
                in: (tab as? WebExtensionTab)?.tab?.browser?.window)
            completionHandler(isAllowed ? permissions : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        Task {
            let hosts = Set(urls.compactMap { $0.host() }).sorted()
            let isAllowed = await WebExtensionPrompts.askForAccess(
                extensionContext, to: [WebExtensionPrompts.siteAccess(hosts)],
                in: (tab as? WebExtensionTab)?.tab?.browser?.window)
            completionHandler(isAllowed ? urls : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        Task {
            let isAllowed = await WebExtensionPrompts.askForAccess(
                extensionContext, to: WebExtensionPrompts.describe([], patterns: matchPatterns),
                in: (tab as? WebExtensionTab)?.tab?.browser?.window)
            completionHandler(isAllowed ? matchPatterns : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        store?.actionDidChange()
    }

    /// Shows the extension's popover under its toolbar button, or under the toolbar when the button isn't showing.
    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover else { return completionHandler(nil) }
        if let anchor = store?.popupAnchor, anchor.window?.isVisible == true {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let contentView = (store?.focusedBrowser ?? store?.windows().first)?.window?.contentView {
            let rect = NSRect(x: contentView.bounds.maxX - 60, y: contentView.bounds.maxY - 80, width: 1, height: 1)
            popover.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
        completionHandler(nil)
        #if DEBUG
        if let popupWebView = action.popupWebView { Self.diagnose(popupWebView, name: context.webExtension.displayName) }
        #endif
    }

    #if DEBUG
    /// Logs what the popover's page gets from the extension APIs it most often waits on, to find one that hangs.
    private static func diagnose(_ webView: WKWebView, name: String?) {
        let probe = """
        const withTimeout = (label, promise) => Promise.race([
            Promise.resolve().then(() => promise).then(v => label + ': ' + JSON.stringify(v)?.slice(0, 160),
                                                       e => label + ' threw: ' + e),
            new Promise(r => setTimeout(() => r(label + ': TIMED OUT'), 2500))]);
        const api = globalThis.browser ?? globalThis.chrome;
        return (await Promise.all([
            withTimeout('tabs.query current', api.tabs.query({active: true, currentWindow: true}).then(t => t.map(x => x.url))),
            withTimeout('windows.getCurrent', api.windows.getCurrent().then(w => w.id)),
            withTimeout('windows.getLastFocused', api.windows.getLastFocused().then(w => w.id)),
            withTimeout('storage.local', api.storage.local.get(null).then(v => Object.keys(v).length + ' keys')),
            withTimeout('runtime.sendMessage', api.runtime.sendMessage({command: 'diagnose'})),
            withTimeout('document', document.readyState + ', body text ' + (document.body?.innerText.length ?? 0)),
        ])).join('\\n');
        """
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            do {
                let result = try await webView.callAsyncJavaScript(probe, contentWorld: .page)
                WebExtensionStore.log.notice("Popup probe \(name ?? "?", privacy: .public):\n\(String(describing: result ?? "nil"), privacy: .public)")
            } catch {
                WebExtensionStore.log.notice("Popup probe \(name ?? "?", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    #endif
}

/// The questions extensions make the browser ask: whether to add one, and whether it may do more.
@MainActor
enum WebExtensionPrompts {
    static func confirmInstall(_ webExtension: WKWebExtension, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add “\(WebExtensionStore.name(of: webExtension))”?"
        let access = describe(webExtension.requestedPermissions, patterns: webExtension.allRequestedMatchPatterns)
        var details = access.isEmpty ? ["It doesn’t need access to your data."]
                                     : ["It can:"] + access.map { "• \($0)" }
        if let description = webExtension.displayDescription, !description.isEmpty {
            details.insert(description + "\n", at: 0)
        }
        alert.informativeText = details.joined(separator: "\n")
        alert.icon = webExtension.icon(for: CGSize(width: 64, height: 64))
        alert.addButton(withTitle: "Add Extension")
        alert.addButton(withTitle: "Cancel")
        return await present(alert, in: window) == .alertFirstButtonReturn
    }

    static func askForAccess(_ context: WKWebExtensionContext, to access: [String], in window: NSWindow?) async -> Bool {
        guard !access.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Allow “\(WebExtensionStore.name(of: context.webExtension))” to do more?"
        alert.informativeText = (["It’s asking to:"] + access.map { "• \($0)" }).joined(separator: "\n")
        alert.icon = context.webExtension.icon(for: CGSize(width: 64, height: 64))
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        return await present(alert, in: window ?? NSApp.keyWindow) == .alertFirstButtonReturn
    }

    static func showError(_ error: Error, title: String, in window: NSWindow?) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = await present(alert, in: window)
    }

    /// What the permissions let an extension do, in the words Chrome uses, leaving out the ones that need no warning.
    static func describe(_ permissions: Set<WKWebExtension.Permission>,
                         patterns: Set<WKWebExtension.MatchPattern>) -> [String] {
        var lines: [String] = []
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            lines.append("Read and change all your data on all websites")
        } else {
            let hosts = Set(patterns.compactMap(\.host)).sorted()
            if !hosts.isEmpty { lines.append(siteAccess(hosts)) }
        }
        let warnings: [(WKWebExtension.Permission, String)] = [
            (.tabs, "Read your browsing history"),
            (.webNavigation, "Read your browsing history"),
            (.cookies, "Read and change cookies on the sites it can access"),
            (.declarativeNetRequest, "Block content on any page"),
            (.declarativeNetRequestWithHostAccess, "Block content on the sites it can access"),
            (.clipboardWrite, "Change what you copy and paste"),
            (.nativeMessaging, "Communicate with apps on your Mac"),
        ]
        for (permission, line) in warnings where permissions.contains(permission) && !lines.contains(line) {
            lines.append(line)
        }
        return lines
    }

    static func siteAccess(_ hosts: [String]) -> String {
        let hosts = hosts.map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0 }
        let named = hosts.prefix(4).joined(separator: ", ")
        let more = hosts.count > 4 ? " and \(hosts.count - 4) more" : ""
        return "Read and change your data on \(named)\(more)"
    }

    private static func present(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.isVisible {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }
}

/// A page's web view, which adds what extensions put in the page's context menu.
final class BrowserWebView: WKWebView {
    weak var tab: BrowserTab?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let tab, let items = tab.browser?.extensions?.menuItems(for: tab), !items.isEmpty else { return }
        menu.addItem(.separator())
        items.forEach(menu.addItem)
    }
}
