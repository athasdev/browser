import Foundation
import Observation

/// The page zoom the user chose for each site, applied whenever one of its pages loads.
@MainActor
@Observable
final class ZoomStore {
    /// The steps Zoom In and Zoom Out move between.
    static let levels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    nonisolated static let storageKey = "pageZoomLevels"

    /// `nil` keeps the levels in memory only.
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let key: String
    /// Only levels other than 100%.
    private(set) var levelsByHost: [String: Double]

    /// A profile's levels are saved under its key prefix.
    init(defaults: UserDefaults? = .standard, keyPrefix: String = "") {
        self.defaults = defaults
        key = keyPrefix + Self.storageKey
        levelsByHost = defaults?.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    func level(for host: String?) -> Double {
        host.flatMap { levelsByHost[$0] } ?? 1
    }

    func setLevel(_ level: Double, for host: String?) {
        guard let host else { return }
        levelsByHost[host] = level == 1 ? nil : level
        defaults?.set(levelsByHost, forKey: key)
    }

    func removeAll() {
        levelsByHost = [:]
        defaults?.removeObject(forKey: key)
    }

    static func level(after level: Double) -> Double {
        levels.first { $0 > level + 0.001 } ?? levels[levels.count - 1]
    }

    static func level(before level: Double) -> Double {
        levels.last { $0 < level - 0.001 } ?? levels[0]
    }
}
