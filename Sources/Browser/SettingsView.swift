import LocalAuthentication
import SwiftUI
import WebKit

enum SettingsTab: String {
    case general
    case appearance
    case profiles
    case privacy
    case passwords
    case siteSettings
    case downloads
    case extensions

    static let storageKey = "settingsTab"
}

/// Browser ▸ Settings (⌘,). Privacy, Passwords, and Site Settings show one profile's at a time.
struct SettingsView: View {
    let profiles: ProfileStore
    let passkeys: Passkeys
    let updater: AppUpdater
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general
    /// `nil` for the default profile.
    @State private var profileID: UUID?

    private var data: ProfileData {
        profiles.data(for: profileID)
    }

    private var profilePicker: ProfilePickerSection {
        ProfilePickerSection(profiles: profiles, selection: Binding(get: { data.id }, set: { profileID = $0 }))
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(updater: updater, profiles: profiles)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "macwindow") }
                .tag(SettingsTab.appearance)
            ProfileSettings(profiles: profiles)
                .tabItem { Label("Profiles", systemImage: "person.2") }
                .tag(SettingsTab.profiles)
            // Switching profiles starts each tab over, so nothing from one profile shows for another. Each tab needs
            // an ID of its own, or the tab bar shows one tab's label for all of them.
            PrivacySettings(browsingData: data.browsingData, contentBlocker: data.contentBlocker, profiles: profiles,
                            profilePicker: profilePicker)
                .id("privacy-\(data.id)")
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(SettingsTab.privacy)
            PasswordSettings(passwords: data.passwords, passkeys: passkeys, profilePicker: profilePicker)
                .id("passwords-\(data.id)")
                .tabItem { Label("Passwords", systemImage: "key") }
                .tag(SettingsTab.passwords)
            SiteSettings(contentBlocker: data.contentBlocker, sitePermissions: data.sitePermissions,
                         zoomLevels: data.zoomLevels, compatibility: data.compatibility, profilePicker: profilePicker)
                .id("siteSettings-\(data.id)")
                .tabItem { Label("Site Settings", systemImage: "globe") }
                .tag(SettingsTab.siteSettings)
            DownloadSettings()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.downloads)
            ExtensionSettings(store: data.extensions, profilePicker: profilePicker)
                .id("extensions-\(data.id)")
                .tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.extensions)
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 500)
    }
}

/// Chooses whose settings a tab shows, once there's more than one profile.
struct ProfilePickerSection: View {
    let profiles: ProfileStore
    @Binding var selection: UUID

    var body: some View {
        if profiles.profiles.count > 1 {
            Section {
                Picker("Profile", selection: $selection) {
                    ForEach(profiles.profiles) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
            }
        }
    }
}

private struct GeneralSettings: View {
    @Bindable var updater: AppUpdater
    let profiles: ProfileStore
    @State private var defaultBrowser = DefaultBrowser()
    @State private var isShowingImport = false
    @AppStorage(SearchEngine.storageKey) private var searchEngine = SearchEngine.google
    @AppStorage(NewTabPage.storageKey) private var newTabPage = NewTabPage.startPage
    @AppStorage(SessionPreferences.restoresWindowsKey) private var restoresWindows = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Default web browser") {
                    if defaultBrowser.isDefault {
                        Text("Browser is your default web browser.")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Make Browser the Default Browser") {
                            Task { await defaultBrowser.makeDefault() }
                        }
                    }
                }
            }

            Section {
                Picker("Search engine", selection: $searchEngine) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                Picker("New tabs open with", selection: $newTabPage) {
                    ForEach(NewTabPage.allCases) { page in
                        Text(page.title).tag(page)
                    }
                }
                Toggle(isOn: $restoresWindows) {
                    Text("Reopen windows from last session on launch")
                    Text("When off, History ▸ Reopen All Windows from Last Session opens them.")
                }
            }

            Section {
                LabeledContent {
                    Button("Import…") { isShowingImport = true }
                } label: {
                    Text("Import from another browser")
                    Text("Bookmarks, history, and passwords from Safari, Chrome, Arc, Brave, Edge, or Firefox.")
                }
            }

            if let sync = profiles.sync {
                ICloudSyncSection(sync: sync)
            }

            if updater.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                    Toggle("Download and install updates automatically", isOn: $updater.downloadsAutomatically)
                        .disabled(!updater.checksAutomatically)
                    LabeledContent("Software update") {
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingImport) {
            BrowserImportView(profiles: profiles, profileID: profiles.defaultProfileID)
        }
        .task { defaultBrowser.refresh() }
        // The default browser can also change in System Settings while Settings is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            defaultBrowser.refresh()
        }
    }
}

/// Saved passwords stay hidden until the user unlocks them with Touch ID or their login password, and lock again
/// when the tab closes or the app goes to the background.
private struct PasswordSettings: View {
    @Bindable var passwords: PasswordManager
    let passkeys: Passkeys
    let profilePicker: ProfilePickerSection
    @State private var isUnlocked = false
    @State private var query = ""
    @State private var revealed: [SavedPassword.ID: String] = [:]
    @State private var removing: SavedPassword?

    private var accounts: [SavedPassword] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return passwords.passwords }
        return passwords.passwords.filter {
            $0.origin.host.localizedCaseInsensitiveContains(query) || $0.username.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Form {
            profilePicker

            Section {
                Toggle(isOn: $passwords.offersToSave) {
                    Text("Offer to save passwords")
                    Text("Browser asks after you sign in to a secure site, keeps passwords in your keychain, and "
                         + "fills them in on that site when you choose. Private windows never save or fill them.")
                }
            }

            Section("Saved Passwords") {
                if isUnlocked {
                    savedPasswords
                } else {
                    HStack {
                        Text("Unlock to see your saved passwords.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Unlock…") { Task { await unlock() } }
                    }
                }
            }

            if !passwords.neverSaveSites.isEmpty {
                Section("Never Saved") {
                    ForEach(passwords.neverSaveSites, id: \.self) { site in
                        HStack {
                            Text(site)
                            Spacer()
                            Button { passwords.allowSaving(on: site) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Offer to Save Passwords Again")
                        }
                    }
                }
            }

            Section("Passkeys") {
                passkeyStatus
            }
        }
        .onDisappear(perform: lock)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in lock() }
        .confirmationDialog("Remove this saved password?", isPresented: Binding(get: { removing != nil },
                                                                                set: { if !$0 { removing = nil } }),
                            presenting: removing) { account in
            Button("Remove", role: .destructive) {
                revealed[account.id] = nil
                passwords.remove(account)
            }
        } message: { account in
            Text("Browser forgets the password for \(account.username.isEmpty ? "this site" : "“\(account.username)”") "
                 + "on \(account.origin.host). It can’t be undone.")
        }
    }

    @ViewBuilder
    private var savedPasswords: some View {
        TextField("Search", text: $query, prompt: Text("Search Passwords"))
            .labelsHidden()
        if accounts.isEmpty {
            Text(query.isEmpty ? "No passwords are saved." : "No passwords match “\(query)”.")
                .foregroundStyle(.secondary)
        }
        ForEach(accounts) { account in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.origin.port == 443 ? account.origin.host : "\(account.origin.host):\(account.origin.port)")
                    Text(account.username.isEmpty ? "No user name" : account.username)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(revealed[account.id] ?? "••••••••")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                Button {
                    revealed[account.id] = revealed[account.id] == nil ? passwords.password(for: account) : nil
                } label: {
                    Image(systemName: revealed[account.id] == nil ? "eye" : "eye.slash")
                }
                .help(revealed[account.id] == nil ? "Show Password" : "Hide Password")
                Button { copy(account) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy Password")
                Button { removing = account } label: {
                    Image(systemName: "minus.circle")
                }
                .help("Remove Password")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var passkeyStatus: some View {
        if !passkeys.isEntitled {
            VStack(alignment: .leading, spacing: 4) {
                Text("Passkeys and security keys aren’t available in this build of Browser.")
                Text("Apple only lets a browser use them once it grants the app its web browser passkey "
                     + "entitlement, and this build doesn’t have it. Websites see a browser without passkey "
                     + "support, so they offer your password or another way to sign in instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            switch passkeys.authorizationState {
            case .authorized:
                Text("Websites can ask you to sign in with your passkeys and security keys.")
                    .foregroundStyle(.secondary)
            case .notDetermined:
                LabeledContent("Use your passkeys on websites") {
                    Button("Allow…") { passkeys.requestAuthorizationIfNeeded() }
                }
            default:
                Text("Browser isn’t allowed to use your passkeys. You can allow it in System Settings.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func unlock() async {
        let context = LAContext()
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                 localizedReason: "show your saved passwords")) == true else { return }
        passwords.reload()
        isUnlocked = true
    }

    private func lock() {
        isUnlocked = false
        revealed = [:]
        query = ""
    }

    /// Marked as concealed, so clipboard managers that respect it don't keep the password.
    private func copy(_ account: SavedPassword) {
        guard let password = passwords.password(for: account) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(password, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
}

private struct AppearanceSettings: View {
    @AppStorage(TabLayout.storageKey) private var tabLayout = TabLayout.horizontal
    @AppStorage(BookmarksBarVisibility.storageKey) private var bookmarksBarVisibility = BookmarksBarVisibility.always

    var body: some View {
        Form {
            Picker("Tabs", selection: $tabLayout) {
                ForEach(TabLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            Picker("Bookmarks bar", selection: $bookmarksBarVisibility) {
                ForEach(BookmarksBarVisibility.allCases) { visibility in
                    Text(visibility.title).tag(visibility)
                }
            }
        }
    }
}

private struct PrivacySettings: View {
    let browsingData: BrowsingData
    let contentBlocker: ContentBlocker
    let profiles: ProfileStore
    let profilePicker: ProfilePickerSection
    @State private var isShowingClearData = false
    @State private var query = ""
    @State private var isConfirmingRemoveAll = false

    private var records: [WKWebsiteDataRecord] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return browsingData.siteRecords }
        return browsingData.siteRecords.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Form {
            profilePicker

            Section {
                Toggle(isOn: Binding(get: { contentBlocker.isEnabled }, set: { profiles.setTrackerBlocking($0) })) {
                    Text("Block trackers")
                    Text("Stops known tracking and advertising services from loading on other sites, in every "
                         + "profile. You can turn it off for a site from the shield in the address bar.")
                }
                LabeledContent("History and website data") {
                    Button("Clear…") { isShowingClearData = true }
                }
            }

            Section {
                TextField("Search", text: $query, prompt: Text("Search Sites"))
                    .labelsHidden()
                if !browsingData.hasLoadedSiteRecords {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if records.isEmpty {
                    Text(query.isEmpty ? "No websites have stored data." : "No sites match “\(query)”.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records, id: \.displayName) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.displayName)
                                Text(BrowsingData.summary(of: record))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") {
                                Task { await browsingData.removeData(for: [record]) }
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Website Data")
                    Spacer()
                    Button("Remove All") { isConfirmingRemoveAll = true }
                        .disabled(browsingData.siteRecords.isEmpty)
                }
            }
        }
        .task { await browsingData.loadSiteRecords() }
        .sheet(isPresented: $isShowingClearData) {
            ClearDataView(data: browsingData)
        }
        .confirmationDialog("Remove data stored by all websites?", isPresented: $isConfirmingRemoveAll) {
            Button("Remove All", role: .destructive) {
                Task { await browsingData.removeData(for: browsingData.siteRecords) }
            }
        } message: {
            Text("This signs you out of most websites, and can’t be undone.")
        }
    }
}

private struct SiteSettings: View {
    let contentBlocker: ContentBlocker
    let sitePermissions: SitePermissions
    let zoomLevels: ZoomStore
    let compatibility: SiteCompatibility
    let profilePicker: ProfilePickerSection

    var body: some View {
        Form {
            profilePicker

            Section {
                let sites = sitePermissions.mediaDecisions
                if sites.isEmpty {
                    Text("No sites have asked to use the camera or microphone.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sites) { site in
                    HStack {
                        Text(site.site)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        permissionPicker("Camera", .camera, current: site.camera, site: site.site)
                        permissionPicker("Microphone", .microphone, current: site.microphone, site: site.site)
                        removeButton { sitePermissions.removeDecisions(on: site.site) }
                    }
                }
            } header: {
                sectionHeader("Camera and Microphone", isEmpty: sitePermissions.mediaDecisions.isEmpty) {
                    sitePermissions.removeAllMediaDecisions()
                }
            } footer: {
                Text("Private windows ask again, and forget the answers when they close.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                let levels = zoomLevels.levelsByHost.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                if levels.isEmpty {
                    Text("Sites you zoom in or out on are remembered here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(levels, id: \.key) { host, level in
                    HStack {
                        Text(host)
                        Spacer()
                        Text(level, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        removeButton { zoomLevels.setLevel(1, for: host) }
                    }
                }
            } header: {
                sectionHeader("Page Zoom", isEmpty: zoomLevels.levelsByHost.isEmpty) { zoomLevels.removeAll() }
            }

            Section {
                if contentBlocker.exceptions.isEmpty {
                    Text("Trackers are blocked on every site.")
                        .foregroundStyle(.secondary)
                }
                ForEach(contentBlocker.exceptions, id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        removeButton { Task { await contentBlocker.removeException(site) } }
                    }
                }
            } header: {
                sectionHeader("Tracker Blocking Turned Off", isEmpty: contentBlocker.exceptions.isEmpty) {
                    Task { await contentBlocker.removeAllExceptions() }
                }
            }

            Section {
                let sites = compatibility.identities.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                if sites.isEmpty {
                    Text("Every site is told it’s in Safari.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sites, id: \.key) { site, identity in
                    HStack {
                        Text(site)
                        Spacer()
                        Picker("Identify as", selection: Binding(get: { identity },
                                                                 set: { compatibility.setIdentity($0, forSite: site) })) {
                            ForEach(BrowserIdentity.allCases) { Text($0.shortTitle).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        removeButton { compatibility.setIdentity(.safari, forSite: site) }
                    }
                }
            } header: {
                sectionHeader("Website Compatibility", isEmpty: compatibility.identities.isEmpty) {
                    compatibility.removeAll()
                }
            } footer: {
                Text("Sites that turn away browsers they don’t recognize often work when told they’re in Chrome. "
                     + "Choose in View ▸ Website Compatibility.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func permissionPicker(_ title: String, _ permission: SitePermissions.Permission, current: Bool?,
                                  site: String) -> some View {
        Picker(title, selection: Binding(get: { current },
                                         set: { sitePermissions.setDecision($0, for: permission, on: site) })) {
            Text("Ask").tag(Bool?.none)
            Text("Allow").tag(Bool?.some(true))
            Text("Don’t Allow").tag(Bool?.some(false))
        }
        .fixedSize()
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Reset")
    }

    private func sectionHeader(_ title: String, isEmpty: Bool, resetAll: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Reset All", action: resetAll)
                .disabled(isEmpty)
        }
    }
}

private struct DownloadSettings: View {
    @AppStorage(DownloadPreferences.asksWhereToSaveKey) private var asksWhereToSave = false

    var body: some View {
        Form {
            Toggle(isOn: $asksWhereToSave) {
                Text("Ask where to save each download")
                Text("When off, downloads save to the Downloads folder.")
            }
        }
    }
}

/// Settings ▸ General ▸ iCloud: whether bookmarks and open tabs sync to the user's other devices.
private struct ICloudSyncSection: View {
    let sync: CloudSync

    var body: some View {
        Section("iCloud") {
            Toggle(isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) })) {
                Text("Sync bookmarks and open tabs")
                Text(statusText)
            }
            .disabled(!sync.isAvailable)
        }
    }

    private var statusText: String {
        switch sync.status {
        case .unavailable: "This build isn’t signed for iCloud."
        case .off: "Each profile’s bookmarks and tabs stay on this Mac."
        case .syncing: "Syncing…"
        case .upToDate(let date): "Up to date, \(date.formatted(.relative(presentation: .named)))."
        case .failed(let message): "Couldn’t sync: \(message)"
        }
    }
}
