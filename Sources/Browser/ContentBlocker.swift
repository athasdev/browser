import Foundation
import Observation
import WebKit

/// Blocks the trackers in `TrackerBlocklist` in a profile's web views. The rule list is compiled off the main thread
/// once, and kept in WebKit's rule list store between launches until the list or the sites where blocking is off
/// change. Each profile has its own sites where blocking is off, so its own rule list; blocking is on or off for all.
@MainActor
@Observable
final class ContentBlocker {
    static let enabledKey = "blocksTrackers"
    nonisolated static let exceptionsKey = "trackerBlockingExceptions"
    nonisolated static let signatureKey = "trackerRuleListSignature"
    nonisolated static let ruleListIdentifier = "Trackers"

    private(set) var isEnabled: Bool
    /// Sites where blocking is off, along with their subdomains. Stored without "www.".
    private(set) var exceptions: [String]
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let store: WKContentRuleListStore?
    @ObservationIgnored private var ruleList: WKContentRuleList?
    @ObservationIgnored private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private let exceptionsKey: String
    @ObservationIgnored private let signatureKey: String
    @ObservationIgnored private let identifier: String

    /// Pass `nil` defaults to keep the settings in memory only, and a `nil` store to never block anything. A profile
    /// saves its exceptions under its key prefix, and its rule list under its own identifier.
    init(defaults: UserDefaults? = nil, store: WKContentRuleListStore? = nil, keyPrefix: String = "",
         ruleListIdentifier: String = ContentBlocker.ruleListIdentifier) {
        self.defaults = defaults
        self.store = store
        exceptionsKey = keyPrefix + Self.exceptionsKey
        signatureKey = keyPrefix + Self.signatureKey
        identifier = ruleListIdentifier
        isEnabled = defaults?.object(forKey: Self.enabledKey) as? Bool ?? true
        exceptions = defaults?.stringArray(forKey: exceptionsKey) ?? []
        if store != nil { loadRuleList() }
    }

    /// Blocks trackers in a web view's pages from now on, and whenever the rule list changes.
    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        apply(to: controller)
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        defaults?.set(isEnabled, forKey: Self.enabledKey)
        controllers.allObjects.forEach(apply)
    }

    /// Whether pages from the host have their trackers blocked.
    func isBlocking(on host: String?) -> Bool {
        isEnabled && exception(covering: host) == nil
    }

    func exception(covering host: String?) -> String? {
        guard let host = host.map(Self.site) else { return nil }
        return exceptions.first { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Turns blocking on or off for a host's site, and returns once pages loaded from now on follow the change.
    func setBlocking(_ isBlocking: Bool, on host: String) async {
        let site = Self.site(host)
        if isBlocking {
            exceptions.removeAll { site == $0 || site.hasSuffix("." + $0) }
        } else if exception(covering: site) == nil {
            exceptions.append(site)
            exceptions.sort()
        }
        await saveExceptions()
    }

    func removeException(_ site: String) async {
        exceptions.removeAll { $0 == site }
        await saveExceptions()
    }

    func removeAllExceptions() async {
        exceptions = []
        await saveExceptions()
    }

    private func saveExceptions() async {
        defaults?.set(exceptions, forKey: exceptionsKey)
        await loadRuleList().value
    }

    /// The host without "www.", lowercased, as rules match it.
    static func site(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func signature(exceptions: [String]) -> String {
        "\(TrackerBlocklist.version) \(exceptions.sorted().joined(separator: " "))"
    }

    /// Loads one rule list at a time, each for the exceptions as they are when it starts.
    @discardableResult
    private func loadRuleList() -> Task<Void, Never> {
        let previous = loading
        let task = Task { [weak self] in
            await previous?.value
            await self?.loadLatestRuleList()
        }
        loading = task
        return task
    }

    private func loadLatestRuleList() async {
        guard let store else { return }
        let exceptions = exceptions
        let signature = Self.signature(exceptions: exceptions)
        if ruleList != nil, defaults?.string(forKey: signatureKey) == signature { return }
        if defaults?.string(forKey: signatureKey) == signature,
           let list = try? await store.contentRuleList(forIdentifier: identifier) {
            install(list)
            return
        }
        let encoded = await Self.encodedRules(exceptions: exceptions)
        guard let list = try? await store.compileContentRuleList(forIdentifier: identifier,
                                                                 encodedContentRuleList: encoded) else { return }
        defaults?.set(signature, forKey: signatureKey)
        install(list)
    }

    @concurrent
    nonisolated private static func encodedRules(exceptions: [String]) async -> String {
        TrackerBlocklist.encodedRules(exceptions: exceptions)
    }

    private func install(_ list: WKContentRuleList) {
        ruleList = list
        controllers.allObjects.forEach(apply)
    }

    private func apply(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        if isEnabled, let ruleList { controller.add(ruleList) }
    }
}
