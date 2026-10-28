import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Extensions: one profile's extensions, and where to get more.
struct ExtensionSettings: View {
    let store: WebExtensionStore
    let profilePicker: ProfilePickerSection
    @State private var appExtensions: [URL] = []
    @State private var isCheckingForUpdates = false

    var body: some View {
        Form {
            profilePicker

            Section {
                if store.installed.isEmpty {
                    Text("Extensions add features to Browser, like blocking ads or managing passwords.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.installed) { record in
                    ExtensionRow(store: store, record: record)
                }
            } header: {
                Text("Installed")
            } footer: {
                Text("Extensions don’t run in private windows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button("Open Store") { openStore() }
                } label: {
                    Text("Chrome Web Store")
                    Text("Open an extension’s page and click Add to Browser in the address bar.")
                }
                LabeledContent {
                    Button("Choose…") { chooseFile() }
                        .disabled(!store.canInstall)
                } label: {
                    Text("Install from a file")
                    Text("A ZIP archive, a CRX package, or an unpacked extension folder.")
                }
                LabeledContent {
                    Button(isCheckingForUpdates ? "Checking…" : "Check Now") {
                        isCheckingForUpdates = true
                        Task {
                            await store.checkForUpdates(force: true)
                            isCheckingForUpdates = false
                        }
                    }
                    .disabled(isCheckingForUpdates || !store.installed.contains { $0.storeID != nil })
                } label: {
                    Text("Updates")
                    Text("Extensions from the Chrome Web Store update every day.")
                }
            } header: {
                Text("Get Extensions")
            }

            if !appExtensions.isEmpty {
                Section {
                    ForEach(appExtensions, id: \.self) { bundle in
                        LabeledContent {
                            let isAdded = store.installed.contains { $0.source == .app(bundlePath: bundle.path) }
                            Button(isAdded ? "Added" : "Add") {
                                Task { await store.installAppExtension(at: bundle, in: NSApp.keyWindow) }
                            }
                            .disabled(isAdded)
                        } label: {
                            Text(bundle.deletingPathExtension().lastPathComponent)
                            Text(Self.appName(containing: bundle))
                        }
                    }
                } header: {
                    Text("Safari Extensions in Your Apps")
                } footer: {
                    Text("Features that need their app, such as filling passwords from a password manager’s app, "
                         + "don’t work.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            appExtensions = await Task.detached { WebExtensionStore.appExtensionBundles() }.value
        }
    }

    private func openStore() {
        ExternalURLRouter.shared.open([ChromeWebStore.home])
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder, UTType(filenameExtension: "crx") ?? .data]
        panel.message = "Choose an extension’s ZIP archive, CRX package, or folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.install(fromFile: url, in: NSApp.keyWindow) }
    }

    private static func appName(containing bundle: URL) -> String {
        var url = bundle
        while url.pathComponents.count > 1, url.pathExtension != "app" {
            url.deleteLastPathComponent()
        }
        return "In " + url.deletingPathExtension().lastPathComponent
    }
}

private struct ExtensionRow: View {
    let store: WebExtensionStore
    let record: InstalledExtension
    @State private var isConfirmingRemoval = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon = store.icon(for: record) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 20))
                }
            }
            .frame(width: 28, height: 28)
            .opacity(record.isEnabled ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name).fontWeight(.medium)
                    if let version = record.version {
                        Text(version).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Text(sourceDescription).font(.callout).foregroundStyle(.secondary)
                if let error = store.loadErrors[record.id] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 12) {
                    if store.contexts[record.id]?.optionsPageURL != nil {
                        Button("Options") { store.openOptions(for: record.id) }
                    }
                    if record.hasPendingUpdate, let storeID = record.storeID {
                        Button("Update…") {
                            Task { await store.installFromChromeWebStore(storeID, in: NSApp.keyWindow) }
                        }
                    }
                    Button("Remove…", role: .destructive) { isConfirmingRemoval = true }
                }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.top, 2)
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { record.isEnabled },
                                            set: { store.setEnabled($0, for: record.id) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 2)
        .confirmationDialog("Remove “\(record.name)”?", isPresented: $isConfirmingRemoval) {
            Button("Remove", role: .destructive) { Task { await store.remove(record.id) } }
        } message: {
            Text("Its settings and the data it stored are removed too.")
        }
    }

    private var sourceDescription: String {
        switch record.source {
        case .chromeWebStore: "From the Chrome Web Store"
        case .file: "Installed from a file"
        case .app(let path):
            "Safari extension in " + (path.split(separator: "/").first { $0.hasSuffix(".app") }
                .map { String($0.dropLast(4)) } ?? "an app")
        }
    }
}
