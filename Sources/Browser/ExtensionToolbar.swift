import AppKit
import SwiftUI
import WebKit

/// The extensions' buttons next to the address bar, and a menu listing every extension.
struct ExtensionToolbar: View {
    let store: WebExtensionStore
    let browser: BrowserModel
    @Environment(\.openSettings) private var openSettings
    /// Only the first few show as buttons; the rest are in the menu.
    static let visibleLimit = 5

    var body: some View {
        // Redraws when an extension changes its button.
        let _ = store.actionRevision
        let loaded = store.loadedContexts

        HStack(spacing: 0) {
            ForEach(loaded.prefix(Self.visibleLimit), id: \.record.id) { item in
                ExtensionActionButton(store: store, browser: browser, record: item.record)
            }
            Menu {
                ForEach(loaded, id: \.record.id) { item in
                    Button {
                        store.performAction(of: item.record.id, in: browser, anchor: nil)
                    } label: {
                        if let icon = store.icon(for: item.record, size: 16) {
                            Image(nsImage: icon)
                        }
                        Text(item.record.name)
                    }
                }
                if !loaded.isEmpty { Divider() }
                Button("Get Extensions…") { browser.open(ChromeWebStore.home, inNewTab: true) }
                Button("Manage Extensions…") {
                    UserDefaults.standard.set(SettingsTab.extensions.rawValue, forKey: SettingsTab.storageKey)
                    openSettings()
                }
            } label: {
                Image(systemName: "puzzlepiece.extension")
            }
            // A borderless menu tints its label with the accent color and has no hover of its own; this one
            // looks and responds like the toolbar's other buttons.
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(ChromeIconButtonStyle(size: 30))
            .fixedSize()
            .help("Extensions")
        }
    }
}

private struct ExtensionActionButton: View {
    let store: WebExtensionStore
    let browser: BrowserModel
    let record: InstalledExtension
    @State private var anchor = ViewAnchor()

    var body: some View {
        let action = store.action(of: record.id, in: browser)
        let label = action?.label.isEmpty == false ? action!.label : record.name
        let badge = action?.badgeText ?? ""

        Button {
            store.performAction(of: record.id, in: browser, anchor: anchor.view)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                if let icon = action?.icon(for: CGSize(width: 16, height: 16)) ?? store.icon(for: record, size: 16) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "puzzlepiece.extension")
                }
                if !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 12, minHeight: 11)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 6, y: 5)
                }
            }
        }
        .buttonStyle(ChromeIconButtonStyle(size: 30))
        .disabled(action?.isEnabled == false)
        .help(label)
        .accessibilityLabel(badge.isEmpty ? label : "\(label), \(badge)")
        .background(ViewAnchorReader(anchor: anchor))
    }
}

/// Holds the AppKit view behind a SwiftUI view, so a popover can point at it.
@MainActor
final class ViewAnchor {
    weak var view: NSView?
}

struct ViewAnchorReader: NSViewRepresentable {
    let anchor: ViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

/// Offers to add the extension a Chrome Web Store page shows, since the store only offers it to Chrome.
struct ChromeWebStoreButton: View {
    let store: WebExtensionStore
    let storeID: String
    let window: NSWindow?

    var body: some View {
        let isInstalled = store.isInstalled(storeID: storeID)
        let isInstalling = store.installingStoreIDs.contains(storeID)

        Button {
            Task { await store.installFromChromeWebStore(storeID, in: window) }
        } label: {
            HStack(spacing: 4) {
                if isInstalling {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: isInstalled ? "checkmark" : "plus")
                }
                Text(isInstalling ? "Adding…" : isInstalled ? "Added" : "Add to Browser")
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color.accentColor.opacity(isInstalled ? 0.12 : 0.9), in: Capsule())
            .foregroundStyle(isInstalled ? Color.accentColor : .white)
        }
        .buttonStyle(.plain)
        .disabled(isInstalled || isInstalling || !store.canInstall)
        .help(isInstalled ? "This extension is added. Manage it in Settings ▸ Extensions."
                          : "Add this extension to Browser")
    }
}
