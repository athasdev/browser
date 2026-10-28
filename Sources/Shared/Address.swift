import Foundation

/// Where words typed into the address bar are searched for.
enum SearchEngine: String, CaseIterable, Identifiable {
    case google
    case duckDuckGo
    case bing
    case kagi
    case ecosia

    static let storageKey = "searchEngine"

    var id: Self { self }

    var title: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        case .ecosia: "Ecosia"
        }
    }

    /// The engine chosen in Settings ▸ General.
    static var current: SearchEngine {
        UserDefaults.standard.string(forKey: storageKey).flatMap(SearchEngine.init) ?? .google
    }

    func searchURL(for query: String) -> URL? {
        let address = switch self {
        case .google: "https://www.google.com/search"
        case .duckDuckGo: "https://duckduckgo.com/"
        case .bing: "https://www.bing.com/search"
        case .kagi: "https://kagi.com/search"
        case .ecosia: "https://www.ecosia.org/search"
        }
        guard var components = URLComponents(string: address) else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        // Search engines read "+" as a space, so "c++" needs it encoded.
        let encodedQuery = components.percentEncodedQuery?.replacing("+", with: "%2B")
        components.percentEncodedQuery = encodedQuery
        return components.url
    }
}

enum BrowserAddress {
    static func url(for input: String, searchEngine: SearchEngine = .current) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           url.host() != nil {
            return url
        }

        if !text.contains(where: \.isWhitespace),
           (text.contains(".") || text == "localhost"),
           let url = URL(string: "https://\(text)"),
           url.host() != nil {
            return url
        }

        return searchEngine.searchURL(for: text)
    }
}
