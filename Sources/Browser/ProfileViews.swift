import AppKit
import SwiftUI

/// A profile's color with its icon, emoji, or initial.
struct ProfileBadge: View {
    let profile: BrowserProfile
    var size: CGFloat = 20

    var body: some View {
        Circle()
            .fill(profile.color.color.gradient)
            .overlay {
                switch profile.icon {
                case .emoji(let emoji):
                    Text(emoji)
                        .font(.system(size: size * 0.58))
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: size * 0.48, weight: .semibold))
                        .foregroundStyle(.white)
                case nil:
                    Text(profile.initial)
                        .font(.system(size: size * 0.52, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The profile badge in a window's toolbar, which opens windows in other profiles.
struct ProfileMenu: View {
    let profiles: ProfileStore
    let current: BrowserProfile
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    var body: some View {
        Menu {
            Text("\(current.displayName) Profile")
            Divider()
            Section("New Window in Profile") {
                ForEach(profiles.profiles) { profile in
                    Button(profile.displayName) {
                        openWindow(id: BrowserApp.windowID, value: ProfileWindowRequest(profileID: profile.id))
                    }
                }
            }
            Divider()
            Button("New Private Window") {
                openWindow(id: BrowserApp.privateWindowID, value: ProfileWindowRequest(profileID: current.id))
            }
            Button("Manage Profiles…") {
                settingsTab = .profiles
                openSettings()
            }
        } label: {
            ProfileBadge(profile: current, size: 20)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ChromeIconButtonStyle(size: 30))
        .fixedSize()
        .help("\(current.displayName) Profile")
        .accessibilityLabel("Profile: \(current.displayName)")
    }
}

/// Settings ▸ Profiles.
struct ProfileSettings: View {
    let profiles: ProfileStore
    @State private var editing: BrowserProfile?
    @State private var deleting: BrowserProfile?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                ForEach(profiles.profiles) { profile in
                    row(for: profile)
                }
            } header: {
                HStack {
                    Text("Profiles")
                    Spacer()
                    Button("Add Profile…") { editing = profiles.makeProfile() }
                }
            } footer: {
                Text("Each profile keeps its own history, bookmarks, passwords, cookies and website data, and site "
                     + "settings, and its windows show its color. New windows open in the profile of the window "
                     + "you’re in, or the default profile; File ▸ New Window in Profile opens one in another.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $editing) { profile in
            ProfileEditor(profile: profile, isNew: profiles.profile(withID: profile.id) == nil) { profiles.save($0) }
        }
        .confirmationDialog(deleting.map { "Delete the “\($0.displayName)” profile?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { profile in
            Button("Delete Profile", role: .destructive) {
                Task { await profiles.delete(profile.id) }
            }
        } message: { _ in
            Text("Its windows close, and Browser removes its history, bookmarks, saved passwords, cookies and "
                 + "website data, and site settings. It can’t be undone.")
        }
    }

    private func row(for profile: BrowserProfile) -> some View {
        let isDefault = profile.id == profiles.defaultProfileID

        return HStack(spacing: 10) {
            ProfileBadge(profile: profile, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                if isDefault {
                    Text("Default")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("New Window") {
                openWindow(id: BrowserApp.windowID, value: ProfileWindowRequest(profileID: profile.id))
            }
            Button("Edit…") { editing = profile }
            Menu {
                Button("Make Default") { profiles.setDefault(profile.id) }
                    .disabled(isDefault)
                Divider()
                Button("Delete Profile…", role: .destructive) { deleting = profile }
                    .disabled(profiles.profiles.count < 2)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }
}

/// Names a profile, and picks its color and icon.
private struct ProfileEditor: View {
    let isNew: Bool
    let save: (BrowserProfile) -> Void
    @State private var profile: BrowserProfile
    @State private var iconKind: IconKind
    @State private var emoji: String
    @State private var symbol: String
    @Environment(\.dismiss) private var dismiss

    private enum IconKind: Hashable {
        case initial
        case emoji
        case symbol
    }

    init(profile: BrowserProfile, isNew: Bool, save: @escaping (BrowserProfile) -> Void) {
        self.isNew = isNew
        self.save = save
        _profile = State(initialValue: profile)
        switch profile.icon {
        case .emoji(let emoji):
            _iconKind = State(initialValue: .emoji)
            _emoji = State(initialValue: emoji)
            _symbol = State(initialValue: ProfileIcon.symbols[0])
        case .symbol(let symbol):
            _iconKind = State(initialValue: .symbol)
            _emoji = State(initialValue: "")
            _symbol = State(initialValue: symbol)
        case nil:
            _iconKind = State(initialValue: .initial)
            _emoji = State(initialValue: "")
            _symbol = State(initialValue: ProfileIcon.symbols[0])
        }
    }

    /// The profile as edited, with the icon chosen.
    private var edited: BrowserProfile {
        var edited = profile
        switch iconKind {
        case .initial: edited.icon = nil
        case .emoji: edited.icon = emoji.first.map { .emoji(String($0)) }
        case .symbol: edited.icon = .symbol(symbol)
        }
        return edited
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ProfileBadge(profile: edited, size: 46)
                VStack(alignment: .leading, spacing: 6) {
                    Text(isNew ? "New Profile" : "Edit Profile")
                        .font(.system(size: 15, weight: .semibold))
                    TextField("Name", text: $profile.name, prompt: Text("Name"))
                        .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                HStack(spacing: 7) {
                    ForEach(ProfileColor.presets, id: \.self) { color in
                        Button { profile.color = color } label: {
                            Circle()
                                .fill(color.color)
                                .frame(width: 22, height: 22)
                                .overlay {
                                    if profile.color == color {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    ColorPicker("Custom Color", selection: Binding(get: { profile.color.color },
                                                                   set: { profile.color = ProfileColor($0) }),
                                supportsOpacity: false)
                        .labelsHidden()
                        .help("Custom Color")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Picker("Icon", selection: $iconKind) {
                    Text("Initial").tag(IconKind.initial)
                    Text("Emoji").tag(IconKind.emoji)
                    Text("Symbol").tag(IconKind.symbol)
                }
                .pickerStyle(.segmented)

                switch iconKind {
                case .initial:
                    EmptyView()
                case .emoji:
                    HStack {
                        TextField("Emoji", text: $emoji, prompt: Text("Type or paste an emoji"))
                            .labelsHidden()
                        Button("Emoji & Symbols") { NSApp.orderFrontCharacterPalette(nil) }
                    }
                case .symbol:
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 9), spacing: 6) {
                        ForEach(ProfileIcon.symbols, id: \.self) { name in
                            Button { symbol = name } label: {
                                Image(systemName: name)
                                    .frame(width: 30, height: 30)
                                    .background(symbol == name ? profile.color.color.opacity(0.3) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Profile" : "Save") {
                    save(edited)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
