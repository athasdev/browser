import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What an import added, shown when it's done.
struct ImportSummary: Equatable {
    var bookmarksFound = 0
    var bookmarksAdded = 0
    var visitsFound = 0
    var visitsAdded = 0
    var passwords: PasswordManager.ImportResult?
    /// Sign-ins in the CSV file that can't be saved: for sites without HTTPS, or without a password.
    var passwordsSkipped = 0
}

/// Imports from another browser into one of the user's profiles, step by step: access to the browser's folder, the
/// browser's own profile when it has several, the passwords CSV file, then reading and adding.
@MainActor
@Observable
final class BrowserImportModel {
    enum Phase: Equatable {
        case choosing
        case choosingSourceProfile
        /// Safari's folder needs Full Disk Access, or its exported data instead.
        case needsSafariAccess
        case importing(step: String, progress: Double)
        case finished(ImportSummary)
        case failed(String)
    }

    var source: ImportSource
    var importsBookmarks = true
    var importsHistory = true
    var importsPasswords = false
    var profileID: UUID
    private(set) var phase = Phase.choosing
    private(set) var sourceProfiles: [SourceProfile] = []
    var sourceProfile: SourceProfile?
    /// The passwords CSV file imported, which the user can delete once it's done.
    private(set) var passwordFile: URL?
    private(set) var deletedPasswordFile = false
    @ObservationIgnored private var sourceFolder: URL?
    @ObservationIgnored private var exportedData: URL?

    init(profileID: UUID) {
        self.profileID = profileID
        source = ImportSource.allCases.first { $0 != .safari && $0.isInstalled } ?? .safari
    }

    var canStart: Bool {
        importsBookmarks || importsHistory || importsPasswords
    }

    func selectSource(_ source: ImportSource) {
        guard source != self.source else { return }
        self.source = source
        sourceFolder = nil
        sourceProfiles = []
        sourceProfile = nil
        exportedData = nil
    }

    func backToChoosing() {
        phase = .choosing
    }

    /// Asks for what the import needs that it doesn't have yet, then imports.
    func start(into profiles: ProfileStore) async {
        if importsBookmarks || importsHistory, exportedData == nil {
            if sourceFolder == nil {
                guard let folder = askForFolderAccess() else { return }
                sourceFolder = folder
                sourceProfiles = BrowserImporter.profiles(for: source, in: folder)
                sourceProfile = sourceProfiles.first
            }
            guard !sourceProfiles.isEmpty else {
                sourceFolder = nil
                phase = .failed("No \(source.shortTitle) bookmarks or history were found there. Choose the folder "
                                + "Browser opens to, ~/\(source.dataFolderPath).")
                return
            }
            if sourceProfiles.count > 1, phase != .choosingSourceProfile {
                phase = .choosingSourceProfile
                return
            }
        }
        if importsPasswords, passwordFile == nil {
            guard let file = askForPasswordFile() else {
                phase = .choosing
                return
            }
            passwordFile = file
        }
        await run(into: profiles.data(for: profileID))
    }

    /// For Safari without Full Disk Access: imports what Safari exported instead.
    func chooseExportedData(into profiles: ProfileStore) async {
        let panel = NSOpenPanel()
        panel.message = "In Safari, choose File ▸ Export Browsing Data to File, and open the ZIP file it saves. "
            + "Then choose the folder it unzips to, or the Bookmarks.html file in it."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .html, .json]
        panel.directoryURL = BrowserImporter.homeDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportedData = url
        phase = .choosing
        await start(into: profiles)
    }

    private func run(into profile: ProfileData) async {
        let source = source
        let importsBookmarks = importsBookmarks
        let importsHistory = importsHistory
        let since = Date.now.addingTimeInterval(-HistoryStore.maxAge)
        let steps = Double([importsBookmarks || importsHistory, importsBookmarks, importsHistory, importsPasswords]
            .filter { $0 }.count)
        var done = 0.0
        let advance = { (step: String) in
            self.phase = .importing(step: step, progress: done / max(steps, 1))
            done += 1
        }
        var summary = ImportSummary()

        if importsBookmarks || importsHistory {
            let what = importsBookmarks && importsHistory ? "bookmarks and history"
                : importsBookmarks ? "bookmarks" : "history"
            advance("Reading \(source.shortTitle)’s \(what)…")
            let data: ImportedData
            do {
                if let exportedData {
                    data = try await Self.readExport(at: exportedData, since: since)
                } else if let folder = sourceProfile?.folder {
                    data = try await Self.read(source, from: folder, bookmarks: importsBookmarks,
                                               history: importsHistory, since: since)
                } else {
                    data = ImportedData()
                }
            } catch ImportError.needsFullDiskAccess {
                sourceFolder = nil
                phase = .needsSafariAccess
                return
            } catch {
                sourceFolder = nil
                phase = .failed("Browser couldn’t read \(source.shortTitle)’s data. \(error.localizedDescription)")
                return
            }
            if importsBookmarks {
                advance("Adding bookmarks…")
                summary.bookmarksFound = data.bookmarks.count
                summary.bookmarksAdded = profile.bookmarks.add(contentsOf: data.bookmarks)
            }
            if importsHistory {
                advance("Adding history…")
                summary.visitsFound = data.visits.count
                summary.visitsAdded = await profile.history.importVisits(data.visits.map {
                    HistoryVisit(url: $0.url, title: $0.title, date: $0.date)
                })
            }
        }

        if importsPasswords, let passwordFile {
            advance("Saving passwords to your keychain…")
            let parsed: PasswordCSV
            do {
                parsed = try await Self.readPasswords(at: passwordFile)
            } catch {
                phase = .failed("Browser couldn’t read “\(passwordFile.lastPathComponent)”. "
                                + "\(error.localizedDescription)")
                return
            }
            summary.passwords = profile.passwords.importPasswords(parsed.passwords.map { ($0.account, $0.password) })
            summary.passwordsSkipped = parsed.skipped
        }
        phase = .finished(summary)
    }

    /// The CSV file holds every password in plain text, so it's removed right away rather than put in the Trash.
    func deletePasswordFile() {
        guard let passwordFile, (try? FileManager.default.removeItem(at: passwordFile)) != nil else { return }
        deletedPasswordFile = true
    }

    private func askForFolderAccess() -> URL? {
        let panel = NSOpenPanel()
        panel.message = source.kind == .safari
            ? "Browser can only read files you give it access to. Choose Allow to let it read Safari’s bookmarks "
                + "and history in this folder. Browser doesn’t change them."
            : "Browser can only read files you give it access to. Choose Allow to let it read \(source.shortTitle)’s "
                + "bookmarks and history in this folder, where \(source.shortTitle) keeps them. Browser doesn’t "
                + "change them."
        panel.prompt = "Allow"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = false
        panel.directoryURL = source.dataFolder
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func askForPasswordFile() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose the passwords CSV file you exported. \(source.passwordExportHint)"
        panel.prompt = "Import Passwords"
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.directoryURL = BrowserImporter.homeDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    @concurrent
    nonisolated private static func read(_ source: ImportSource, from folder: URL, bookmarks: Bool, history: Bool,
                                         since: Date) async throws -> ImportedData {
        try BrowserImporter.read(source, from: folder, bookmarks: bookmarks, history: history, since: since)
    }

    @concurrent
    nonisolated private static func readExport(at url: URL, since: Date) async throws -> ImportedData {
        try BrowserImporter.readExport(at: url, since: since)
    }

    @concurrent
    nonisolated private static func readPasswords(at url: URL) async throws -> PasswordCSV {
        BrowserImporter.passwords(fromCSV: try String(contentsOf: url, encoding: .utf8))
    }
}

/// File ▸ Import From Browser, also opened from Settings ▸ General.
struct BrowserImportView: View {
    let profiles: ProfileStore
    @State private var model: BrowserImportModel
    @Environment(\.dismiss) private var dismiss

    init(profiles: ProfileStore, profileID: UUID) {
        self.profiles = profiles
        _model = State(initialValue: BrowserImportModel(profileID: profileID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import From Another Browser")
                .font(.system(size: 15, weight: .semibold))

            switch model.phase {
            case .choosing:
                choosing
            case .choosingSourceProfile:
                sourceProfilePicker
            case .needsSafariAccess:
                safariAccess
            case .importing(let step, let progress):
                ProgressView(value: progress) {
                    Text(step)
                }
                .padding(.vertical, 8)
            case .finished(let summary):
                finished(summary)
            case .failed(let message):
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                buttons {
                    Button("Back") { model.backToChoosing() }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 2) {
                ForEach(ImportSource.allCases) { source in
                    sourceRow(source)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Bookmarks", isOn: $model.importsBookmarks)
                Toggle(isOn: $model.importsHistory) {
                    Text("History")
                    Text("The last 90 days, like Browser keeps.")
                }
                Toggle(isOn: $model.importsPasswords) {
                    Text("Passwords")
                    Text("From a CSV file you export from \(model.source.shortTitle). "
                         + model.source.passwordExportHint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if profiles.profiles.count > 1 {
                Picker("Import into", selection: $model.profileID) {
                    ForEach(profiles.profiles) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
                .fixedSize()
            }

            Text(model.source.kind == .safari
                 ? "Browser asks for access to Safari’s folder, since it can only read files you choose. "
                    + "Reading it also needs Full Disk Access; without it, you can import what Safari exports."
                 : "Browser asks for access to the folder where \(model.source.shortTitle) keeps its bookmarks and "
                    + "history, since it can only read files you choose.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            buttons {
                Button("Import…") { Task { await model.start(into: profiles) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            }
        }
    }

    private func sourceRow(_ source: ImportSource) -> some View {
        let isSelected = model.source == source

        return Button { model.selectSource(source) } label: {
            HStack(spacing: 10) {
                if let app = source.applicationURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "globe")
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.secondary)
                }
                Text(source.title)
                Spacer()
                if !source.isInstalled {
                    Text("Not installed")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sourceProfilePicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(model.source.shortTitle) has more than one profile. Which one do you want to import from?")
                .fixedSize(horizontal: false, vertical: true)
            Picker("Profile", selection: $model.sourceProfile) {
                ForEach(model.sourceProfiles, id: \.self) { profile in
                    Text(profile.name).tag(Optional(profile))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            buttons {
                Button("Import") { Task { await model.start(into: profiles) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var safariAccess: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macOS only lets apps with Full Disk Access read Safari’s bookmarks and history.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Either turn on Browser in System Settings ▸ Privacy & Security ▸ Full Disk Access and try again, "
                 + "or in Safari choose File ▸ Export Browsing Data to File, and import the exported data.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Full Disk Access Settings") {
                    let address = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                    if let url = URL(string: address) { NSWorkspace.shared.open(url) }
                }
                Button("Choose Exported Data…") { Task { await model.chooseExportedData(into: profiles) } }
            }
            buttons {
                Button("Try Again") { Task { await model.start(into: profiles) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finished(_ summary: ImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.importsBookmarks {
                summaryLine("star", summary.bookmarksFound == 0 ? "No bookmarks were found."
                            : "Added \(summary.bookmarksAdded) of \(summary.bookmarksFound) bookmarks; the rest "
                                + "were already bookmarked.",
                            short: "Added \(summary.bookmarksAdded) bookmarks.",
                            isShort: summary.bookmarksAdded == summary.bookmarksFound)
            }
            if model.importsHistory {
                summaryLine("clock", summary.visitsFound == 0 ? "No history from the last 90 days was found."
                            : "Added \(summary.visitsAdded) of \(summary.visitsFound) visits from the last 90 days; "
                                + "the rest were already in history.",
                            short: "Added \(summary.visitsAdded) visits from the last 90 days.",
                            isShort: summary.visitsAdded == summary.visitsFound)
            }
            if let passwords = summary.passwords {
                summaryLine("key", passwordSummary(passwords, skipped: summary.passwordsSkipped))
            }
            if model.passwordFile != nil {
                Divider()
                if model.deletedPasswordFile {
                    Text("The CSV file was deleted.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("The CSV file still holds your passwords in plain text, where any app can read them.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Delete CSV File") { model.deletePasswordFile() }
                    }
                }
            }
            buttons(showsCancel: false) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func passwordSummary(_ result: PasswordManager.ImportResult, skipped: Int) -> String {
        var parts = ["Saved \(result.added) \(result.added == 1 ? "password" : "passwords") to your keychain."]
        if result.alreadySaved > 0 {
            parts.append("\(result.alreadySaved) were already saved, and kept their saved password.")
        }
        if skipped > 0 {
            parts.append("\(skipped) weren’t imported, since they weren’t for secure (HTTPS) sites or had no "
                         + "password.")
        }
        if result.failed > 0 {
            parts.append("\(result.failed) couldn’t be saved.")
        }
        return parts.joined(separator: " ")
    }

    private func summaryLine(_ symbol: String, _ text: String, short: String = "", isShort: Bool = false) -> some View {
        Label {
            Text(isShort && !short.isEmpty ? short : text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
        }
    }

    private func buttons(showsCancel: Bool = true, @ViewBuilder primary: () -> some View) -> some View {
        HStack {
            Spacer()
            if showsCancel {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            primary()
        }
    }
}
