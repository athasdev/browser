import AppKit
import Foundation
import Observation

struct HistoryVisit: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let url: URL
    var title: String
    let date: Date

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url.host().map(Bookmark.trimmedHost) ?? url.absoluteString
    }
}

/// Every visit to an address, combined, for ranking address bar suggestions.
struct HistoryPage: Equatable {
    let url: URL
    let title: String
    let visitCount: Int
    let lastVisit: Date
}

/// A page in the history view: the latest of a day's visits to an address.
struct HistoryEntry: Identifiable, Equatable {
    let url: URL
    let title: String
    let date: Date

    var id: String { "\(date.timeIntervalSinceReferenceDate) \(url.absoluteString)" }

    var displayTitle: String {
        HistoryVisit(url: url, title: title, date: date).displayTitle
    }
}

struct HistoryDay: Identifiable, Equatable {
    /// The start of the day.
    let date: Date
    /// Newest first.
    let entries: [HistoryEntry]

    var id: Date { date }
}

enum HistoryClearRange: CaseIterable, Identifiable {
    case lastHour
    case today
    case todayAndYesterday
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .lastHour: "Last Hour"
        case .today: "Today"
        case .todayAndYesterday: "Today and Yesterday"
        case .all: "All History"
        }
    }

    /// The earliest visit cleared.
    func start(now: Date = .now, calendar: Calendar = .current) -> Date {
        switch self {
        case .lastHour: now.addingTimeInterval(-60 * 60)
        case .today: calendar.startOfDay(for: now)
        case .todayAndYesterday:
            calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? calendar.startOfDay(for: now)
        case .all: .distantPast
        }
    }
}

/// The pages visited in every window, kept for 90 days in Application Support.
@MainActor
@Observable
final class HistoryStore {
    static let maxAge: TimeInterval = 90 * 24 * 60 * 60
    static let maxVisits = 50_000
    private static let saveDelay: Duration = .seconds(1)

    /// Oldest first.
    private(set) var visits: [HistoryVisit] = []
    @ObservationIgnored private let file: StoreFile?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var cachedPages: [HistoryPage]?
    /// Removals made before the saved history finished loading, applied to it once it has.
    @ObservationIgnored private var pendingRemovals: [(HistoryVisit) -> Bool] = []
    @ObservationIgnored private var isSaving = true

    /// Pass `nil` to keep history in memory only.
    init(file: StoreFile? = .applicationSupport(named: "History.plist")) {
        self.file = file
        guard let file else { return }
        loading = Task { [weak self] in
            let saved = await Self.loadVisits(from: file)
            self?.merge(saved)
        }
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    func waitUntilLoaded() async {
        await loading?.value
    }

    /// Adds visits from another browser, leaving out those already in history to the second, and returns how many
    /// were added. Visits older than `maxAge` aren't kept.
    @discardableResult
    func importVisits(_ imported: [HistoryVisit], now: Date = .now) async -> Int {
        await waitUntilLoaded()
        let key = { (visit: HistoryVisit) in
            "\(Int(visit.date.timeIntervalSinceReferenceDate)) \(visit.url.absoluteString)"
        }
        var known = Set(visits.map(key))
        let cutoff = now.addingTimeInterval(-Self.maxAge)
        let added = imported.filter { $0.date >= cutoff && $0.date <= now && known.insert(key($0)).inserted }
        guard !added.isEmpty else { return 0 }
        let before = visits.count
        update { visits in
            visits = (visits + added).sorted { $0.date < $1.date }
            Self.prune(&visits, now: now)
        }
        return max(0, visits.count - before)
    }

    /// Stops saving, so a deleted profile's history file isn't written again.
    func stopSaving() {
        isSaving = false
        saveTask?.cancel()
    }

    /// Adds a visit, returning its ID so the title can follow the page's.
    @discardableResult
    func recordVisit(to url: URL, title: String, at date: Date = .now) -> UUID {
        let visit = HistoryVisit(url: url, title: title, date: date)
        update { visits in
            visits.append(visit)
            Self.prune(&visits, now: date)
        }
        return visit.id
    }

    func updateTitle(of id: UUID, to title: String) {
        guard let index = visits.lastIndex(where: { $0.id == id }), visits[index].title != title else { return }
        update { $0[index].title = title }
    }

    /// The latest visits to different addresses, newest first.
    func recentVisits(limit: Int) -> [HistoryVisit] {
        var seen = Set<URL>()
        var recent: [HistoryVisit] = []
        for visit in visits.reversed() where seen.insert(visit.url).inserted {
            recent.append(visit)
            if recent.count == limit { break }
        }
        return recent
    }

    /// Visits combined by address.
    var pages: [HistoryPage] {
        if let cachedPages { return cachedPages }
        var pages: [URL: HistoryPage] = [:]
        for visit in visits {
            let page = pages[visit.url]
            pages[visit.url] = HistoryPage(url: visit.url,
                                           title: visit.title.isEmpty ? page?.title ?? "" : visit.title,
                                           visitCount: (page?.visitCount ?? 0) + 1,
                                           lastVisit: visit.date)
        }
        let result = Array(pages.values)
        cachedPages = result
        return result
    }

    /// Visits grouped by day, newest first, keeping each day's latest visit to an address.
    func days(matching query: String = "", calendar: Calendar = .current) -> [HistoryDay] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var days: [HistoryDay] = []
        var entries: [HistoryEntry] = []
        var day: Date?
        var seen = Set<URL>()
        for visit in visits.reversed() {
            guard query.isEmpty || visit.title.localizedCaseInsensitiveContains(query)
                    || visit.url.absoluteString.localizedCaseInsensitiveContains(query) else { continue }
            let visitDay = calendar.startOfDay(for: visit.date)
            if visitDay != day {
                if let day, !entries.isEmpty { days.append(HistoryDay(date: day, entries: entries)) }
                day = visitDay
                entries = []
                seen = []
            }
            if seen.insert(visit.url).inserted {
                entries.append(HistoryEntry(url: visit.url, title: visit.title, date: visit.date))
            }
        }
        if let day, !entries.isEmpty { days.append(HistoryDay(date: day, entries: entries)) }
        return days
    }

    /// Removes the visits to an address on the day of `date`.
    func removeVisits(to url: URL, onDayOf date: Date, calendar: Calendar = .current) {
        remove { $0.url == url && calendar.isDate($0.date, inSameDayAs: date) }
    }

    func clear(_ range: HistoryClearRange, now: Date = .now, calendar: Calendar = .current) {
        let start = range.start(now: now, calendar: calendar)
        remove { $0.date >= start }
    }

    private func remove(where shouldRemove: @escaping (HistoryVisit) -> Bool) {
        if loading != nil { pendingRemovals.append(shouldRemove) }
        update { $0.removeAll(where: shouldRemove) }
    }

    private func update(_ change: (inout [HistoryVisit]) -> Void) {
        change(&visits)
        cachedPages = nil
        scheduleSave()
    }

    /// Adds the saved history to the visits made while it loaded.
    private func merge(_ saved: [HistoryVisit]) {
        loading = nil
        let savedCount = saved.count
        var saved = saved
        for shouldRemove in pendingRemovals {
            saved.removeAll(where: shouldRemove)
        }
        pendingRemovals = []
        visits = (saved + visits).sorted { $0.date < $1.date }
        Self.prune(&visits, now: .now)
        cachedPages = nil
        // Saves skipped while loading, and expired visits, need writing now.
        if visits.count != savedCount || saved.count != savedCount { scheduleSave() }
    }

    /// Drops visits older than `maxAge`, and the oldest beyond `maxVisits`.
    static func prune(_ visits: inout [HistoryVisit], now: Date) {
        let cutoff = now.addingTimeInterval(-maxAge)
        let expired = visits.prefix { $0.date < cutoff }.count
        let excess = max(0, visits.count - expired - maxVisits)
        if expired + excess > 0 { visits.removeFirst(expired + excess) }
    }

    private func scheduleSave() {
        guard let file, isSaving else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard let self, !Task.isCancelled, loading == nil else { return }
            let visits = visits
            file.write { try? PropertyListEncoder.binary.encode(visits) }
        }
    }

    /// Saves right away, for when the app quits. History that hasn't loaded yet is left as it is.
    func saveNow() {
        guard let file, isSaving, loading == nil else { return }
        saveTask?.cancel()
        file.writeNow(try? PropertyListEncoder.binary.encode(visits))
    }

    @concurrent
    nonisolated private static func loadVisits(from file: StoreFile) async -> [HistoryVisit] {
        guard let data = await file.read() else { return [] }
        return (try? PropertyListDecoder().decode([HistoryVisit].self, from: data)) ?? []
    }
}

extension PropertyListEncoder {
    static var binary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
