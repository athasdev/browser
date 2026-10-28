import Foundation

/// What a new tab shows.
enum NewTabPage: String, CaseIterable, Identifiable {
    /// The greeting, search field, and favorites.
    case startPage
    case blank

    static let storageKey = "newTabPage"

    var id: Self { self }

    var title: String {
        switch self {
        case .startPage: "Start Page"
        case .blank: "Blank Page"
        }
    }
}

enum SessionPreferences {
    /// Whether the windows open when the app quit reopen on launch. Otherwise they wait in History ▸ Reopen All
    /// Windows from Last Session.
    static let restoresWindowsKey = "restoresWindowsOnLaunch"

    static var restoresWindows: Bool {
        UserDefaults.standard.object(forKey: restoresWindowsKey) as? Bool ?? true
    }
}

enum DownloadPreferences {
    /// Whether each download asks where to save it, instead of saving to the Downloads folder.
    static let asksWhereToSaveKey = "asksWhereToSaveDownloads"

    static var asksWhereToSave: Bool {
        UserDefaults.standard.bool(forKey: asksWhereToSaveKey)
    }
}
