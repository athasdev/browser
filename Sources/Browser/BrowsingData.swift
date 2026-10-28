import Foundation
import Observation
import SwiftUI
import WebKit

/// What Clear History and Website Data removes.
struct ClearDataOptions: OptionSet, Hashable {
    let rawValue: Int

    static let history = ClearDataOptions(rawValue: 1 << 0)
    /// Cookies, storage, databases, and service workers.
    static let siteData = ClearDataOptions(rawValue: 1 << 1)
    static let cache = ClearDataOptions(rawValue: 1 << 2)
    static let favicons = ClearDataOptions(rawValue: 1 << 3)

    static let all: ClearDataOptions = [.history, .siteData, .cache, .favicons]

    static let cacheTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeFetchCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
    ]

    /// The WebKit data types to remove, out of `allTypes`.
    @MainActor
    func websiteDataTypes(from allTypes: Set<String> = WKWebsiteDataStore.allWebsiteDataTypes()) -> Set<String> {
        var types = Set<String>()
        if contains(.siteData) { types.formUnion(allTypes.subtracting(Self.cacheTypes)) }
        if contains(.cache) { types.formUnion(allTypes.intersection(Self.cacheTypes)) }
        return types
    }
}

/// The history and website data a profile's windows keep, which Settings ▸ Privacy and History ▸ Clear History and
/// Website Data remove. Private windows keep theirs apart, and lose it when they close.
@MainActor
@Observable
final class BrowsingData {
    let history: HistoryStore
    let session: SessionStore
    @ObservationIgnored let dataStore: WKWebsiteDataStore
    /// The profile whose closed windows clearing all history forgets.
    @ObservationIgnored let profileID: UUID?
    /// Sites with cookies, storage, or cache, sorted by name. Empty until `loadSiteRecords()`.
    private(set) var siteRecords: [WKWebsiteDataRecord] = []
    private(set) var hasLoadedSiteRecords = false

    init(history: HistoryStore, session: SessionStore, dataStore: WKWebsiteDataStore = .default(),
         profileID: UUID? = nil) {
        self.history = history
        self.session = session
        self.dataStore = dataStore
        self.profileID = profileID
    }

    /// Removes what the options name from the time range. Clearing all history also forgets the profile's closed
    /// windows that History ▸ Reopen All Windows from Last Session would open.
    func clear(_ options: ClearDataOptions, range: HistoryClearRange, now: Date = .now) async {
        let start = range.start(now: now)
        if options.contains(.history) {
            history.clear(range, now: now)
            if range == .all { session.forgetClosedWindows(in: profileID) }
        }
        let types = options.websiteDataTypes()
        if !types.isEmpty {
            await dataStore.removeData(ofTypes: types, modifiedSince: start)
        }
        if options.contains(.favicons) {
            await FaviconStore.clear(since: start)
        }
        if hasLoadedSiteRecords { await loadSiteRecords() }
    }

    func loadSiteRecords() async {
        let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        siteRecords = records.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        hasLoadedSiteRecords = true
    }

    func removeData(for records: [WKWebsiteDataRecord]) async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        await loadSiteRecords()
    }

    /// What a site has stored, for the site data list.
    static func summary(of record: WKWebsiteDataRecord) -> String {
        let types = record.dataTypes
        var parts: [String] = []
        if types.contains(WKWebsiteDataTypeCookies) { parts.append("Cookies") }
        if !types.isDisjoint(with: [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
                                    WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases,
                                    WKWebsiteDataTypeFileSystem]) {
            parts.append("Local storage")
        }
        if types.contains(WKWebsiteDataTypeServiceWorkerRegistrations) { parts.append("Service workers") }
        if !types.isDisjoint(with: ClearDataOptions.cacheTypes) { parts.append("Cache") }
        return parts.isEmpty ? "Other data" : parts.joined(separator: ", ")
    }
}

/// History ▸ Clear History and Website Data, also opened from Settings ▸ Privacy.
struct ClearDataView: View {
    let data: BrowsingData
    @Environment(\.dismiss) private var dismiss
    @State private var range = HistoryClearRange.lastHour
    @State private var options: ClearDataOptions = [.history, .siteData, .cache]
    @State private var isClearing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clear History and Website Data")
                .font(.system(size: 15, weight: .semibold))

            Picker("Clear:", selection: $range) {
                ForEach(HistoryClearRange.allCases) { range in
                    Text(range == .all ? "All Time" : range.title).tag(range)
                }
            }
            .fixedSize()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("History", isOn: binding(for: .history))
                Toggle(isOn: binding(for: .siteData)) {
                    Text("Cookies and website data")
                    Text("Signs you out of most websites.")
                }
                Toggle("Cached images and files", isOn: binding(for: .cache))
                Toggle("Site icons", isOn: binding(for: .favicons))
            }

            Text("Other profiles and private windows aren’t affected. A private window’s data is removed when it "
                 + "closes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if isClearing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clear") {
                    isClearing = true
                    Task {
                        await data.clear(options, range: range)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(options.isEmpty || isClearing)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func binding(for option: ClearDataOptions) -> Binding<Bool> {
        Binding(get: { options.contains(option) },
                set: { if $0 { options.insert(option) } else { options.remove(option) } })
    }
}
