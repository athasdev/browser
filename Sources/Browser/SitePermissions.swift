import Foundation
import Observation

/// What the user allowed or refused each site to do. Camera and microphone answers are kept between launches for
/// normal windows, and listed in Settings ▸ Site Settings; downloads are remembered until the app quits.
@MainActor
@Observable
final class SitePermissions {
    enum Permission: String {
        /// Downloading files the user didn't click to download.
        case downloads
        case camera
        case microphone

        /// Whether the answer is saved between launches.
        var isSaved: Bool {
            self != .downloads
        }
    }

    private struct Key: Hashable {
        let site: String
        let permission: Permission
    }

    /// A site's saved camera and microphone answers, `nil` where it hasn't asked.
    struct SiteDecisions: Identifiable, Equatable {
        let site: String
        var camera: Bool?
        var microphone: Bool?

        var id: String { site }
    }

    nonisolated static let storageKey = "sitePermissions"

    /// `nil` keeps every answer in memory only.
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let defaultsKey: String
    private var decisions: [Key: Bool] = [:]
    @ObservationIgnored private var prompts: [String: Task<Bool?, Never>] = [:]

    /// A profile's answers are saved under its key prefix.
    init(defaults: UserDefaults? = nil, keyPrefix: String = "") {
        self.defaults = defaults
        defaultsKey = keyPrefix + Self.storageKey
        let saved = defaults?.dictionary(forKey: defaultsKey) as? [String: [String: Bool]] ?? [:]
        for (site, answers) in saved {
            for (name, isAllowed) in answers {
                guard let permission = Permission(rawValue: name), permission.isSaved else { continue }
                decisions[Key(site: site, permission: permission)] = isAllowed
            }
        }
    }

    /// Refused if any of the permissions was refused, allowed only once all of them were allowed.
    func decision(for permissions: Set<Permission>, on site: String) -> Bool? {
        let known = permissions.map { decisions[Key(site: site, permission: $0)] }
        if known.contains(false) { return false }
        return known.allSatisfy { $0 == true } ? true : nil
    }

    /// Asks only when the site's answer isn't known yet, sharing one prompt between requests that arrive together.
    /// A prompt that ends without an answer, because its tab closed, refuses without remembering it.
    func decide(_ permissions: Set<Permission>, on site: String,
                ask: @escaping @MainActor () async -> Bool?) async -> Bool {
        if let decision = decision(for: permissions, on: site) { return decision }
        let promptKey = ([site] + permissions.map(\.rawValue).sorted()).joined(separator: " ")
        if let prompt = prompts[promptKey] { return await prompt.value ?? false }
        let prompt = Task(operation: ask)
        prompts[promptKey] = prompt
        let answer = await prompt.value
        prompts[promptKey] = nil
        guard let isAllowed = answer else { return false }
        for permission in permissions {
            decisions[Key(site: site, permission: permission)] = isAllowed
        }
        save()
        return isAllowed
    }

    /// Sites with a camera or microphone answer, sorted by name.
    var mediaDecisions: [SiteDecisions] {
        var sites: [String: SiteDecisions] = [:]
        for (key, isAllowed) in decisions where key.permission.isSaved {
            var site = sites[key.site] ?? SiteDecisions(site: key.site)
            if key.permission == .camera { site.camera = isAllowed } else { site.microphone = isAllowed }
            sites[key.site] = site
        }
        return sites.values.sorted { $0.site.localizedStandardCompare($1.site) == .orderedAscending }
    }

    /// Sets an answer, or forgets it with `nil` so the site asks again.
    func setDecision(_ isAllowed: Bool?, for permission: Permission, on site: String) {
        decisions[Key(site: site, permission: permission)] = isAllowed
        save()
    }

    func removeDecisions(on site: String) {
        decisions = decisions.filter { $0.key.site != site }
        save()
    }

    func removeAllMediaDecisions() {
        decisions = decisions.filter { !$0.key.permission.isSaved }
        save()
    }

    private func save() {
        guard let defaults else { return }
        var saved: [String: [String: Bool]] = [:]
        for (key, isAllowed) in decisions where key.permission.isSaved {
            saved[key.site, default: [:]][key.permission.rawValue] = isAllowed
        }
        defaults.set(saved, forKey: defaultsKey)
    }
}
