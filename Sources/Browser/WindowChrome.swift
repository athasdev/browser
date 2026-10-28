import AppKit
import SwiftUI

enum BrowserChrome {
    /// Height of the row that holds the window controls and tabs.
    static let tabRowHeight: CGFloat = 40
    static let tabHeight: CGFloat = 30
    static let navigationBarHeight: CGFloat = 46
    static let sidebarWidth: CGFloat = 236
    static let sidebarTabHeight: CGFloat = 32
    /// Inset shared by the navigation bar and the page, so their edges line up.
    static let edgeInset: CGFloat = 8

    static let windowButtonSize: CGFloat = 14
    static let windowButtonSpacing: CGFloat = 23

    /// Height of the top row the window controls are centered in for a tab layout.
    static func titlebarHeight(for layout: TabLayout) -> CGFloat {
        layout == .vertical ? navigationBarHeight : tabRowHeight
    }

    /// Matches the vertical inset so the window controls sit equally far from the top and left edges.
    static func windowButtonLeading(titlebarHeight: CGFloat) -> CGFloat {
        (titlebarHeight - windowButtonSize) / 2
    }

    static func windowButtonsTrailing(titlebarHeight: CGFloat) -> CGFloat {
        windowButtonLeading(titlebarHeight: titlebarHeight) + windowButtonSpacing * 2 + windowButtonSize
    }
}

enum TabLayout: String, CaseIterable, Identifiable {
    case horizontal
    case vertical

    static let storageKey = "tabLayout"
    /// Whether the tab strip or sidebar is hidden, leaving the navigation bar as the window's top row.
    static let hiddenStorageKey = "tabsHidden"

    var id: Self { self }

    var title: String {
        switch self {
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        }
    }

    var toggled: TabLayout { self == .vertical ? .horizontal : .vertical }
}

/// Keeps the window controls centered in the tab row, which is taller than the default title bar, and reports
/// the window it's in and when the user closes it.
struct WindowChromeConfigurator: NSViewRepresentable {
    let titlebarHeight: CGFloat
    @Binding var isFullScreen: Bool
    var onWindowChange: (NSWindow?) -> Void = { _ in }
    var onClose: () -> Void = {}

    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: WindowChromeView, context: Context) {
        view.onFullScreenChange = { isFullScreen = $0 }
        view.onWindowChange = onWindowChange
        view.onClose = onClose
        view.titlebarHeight = titlebarHeight
    }
}

final class WindowChromeView: NSView {
    var onFullScreenChange: ((Bool) -> Void)?
    var onWindowChange: ((NSWindow?) -> Void)?
    var onClose: (() -> Void)?
    var titlebarHeight = BrowserChrome.tabRowHeight {
        didSet {
            if titlebarHeight != oldValue { layoutWindowButtons() }
        }
    }
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        onWindowChange?(window)
        guard let window else { return }

        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeScreenNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutWindowButtons() }
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClose?() }
        })
        DispatchQueue.main.async { [weak self] in self?.layoutWindowButtons() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func layoutWindowButtons() {
        guard let window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if let onFullScreenChange {
            DispatchQueue.main.async { onFullScreenChange(isFullScreen) }
        }

        guard !isFullScreen,
              let closeButton = window.standardWindowButton(.closeButton),
              let titlebarView = closeButton.superview,
              let titlebarContainer = titlebarView.superview else { return }

        let height = titlebarHeight
        let containerFrame = NSRect(x: titlebarContainer.frame.minX,
                                    y: window.frame.height - height,
                                    width: titlebarContainer.frame.width,
                                    height: height)
        if titlebarContainer.frame != containerFrame {
            titlebarContainer.frame = containerFrame
        }

        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in buttonTypes.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            let origin = NSPoint(
                x: BrowserChrome.windowButtonLeading(titlebarHeight: height)
                    + CGFloat(index) * BrowserChrome.windowButtonSpacing,
                y: ((titlebarView.bounds.height - button.frame.height) / 2).rounded()
            )
            if button.frame.origin != origin {
                button.setFrameOrigin(origin)
            }
        }
    }
}

extension BrowserChrome {
    /// Laid over the window's glass in a private window, so it reads as different at a glance.
    static let privateTint = Color(red: 0.11, green: 0.08, blue: 0.20).opacity(0.72)
}

extension View {
    /// A private window's tabs, toolbar, and new tab page are always dark. Its pages keep the system appearance.
    @ViewBuilder
    func privateChrome(_ isPrivate: Bool) -> some View {
        if isPrivate {
            environment(\.colorScheme, .dark)
        } else {
            self
        }
    }
}
