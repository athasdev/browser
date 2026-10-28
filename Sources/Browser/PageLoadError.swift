import Foundation
import SwiftUI

/// Why a page couldn't load, shown in the tab in place of the page.
struct PageLoadError: Equatable {
    enum Kind: Equatable {
        case offline
        case serverNotFound
        case cannotConnect
        case timedOut
        case invalidCertificate
        case secureConnectionFailed
        /// The page's web process crashed again right after reloading, so it isn't reloaded again.
        case crashed
        case other(String)
    }

    let kind: Kind
    let url: URL?

    /// The domain of WebKit's own load errors, which `WKError` doesn't cover.
    static let webKitErrorDomain = "WebKitErrorDomain"

    init(kind: Kind, url: URL?) {
        self.kind = kind
        self.url = url
    }

    /// `nil` for loads that didn't fail: cancelled ones, pages that became downloads or are shown by a plug-in,
    /// and links to schemes such as `mailto:` that WebKit can't show.
    init?(_ error: Error, url fallbackURL: URL?) {
        let error = error as NSError
        url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? fallbackURL
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorCancelled), (NSURLErrorDomain, NSURLErrorUnsupportedURL),
             (Self.webKitErrorDomain, 101), (Self.webKitErrorDomain, 102), (Self.webKitErrorDomain, 204):
            return nil
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet), (NSURLErrorDomain, NSURLErrorDataNotAllowed),
             (NSURLErrorDomain, NSURLErrorInternationalRoamingOff):
            kind = .offline
        case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            kind = .serverNotFound
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost), (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            kind = .cannotConnect
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            kind = .timedOut
        case (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid):
            kind = .invalidCertificate
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
             (NSURLErrorDomain, NSURLErrorClientCertificateRejected),
             (NSURLErrorDomain, NSURLErrorClientCertificateRequired):
            kind = .secureConnectionFailed
        default:
            kind = .other(error.localizedDescription)
        }
    }

    private var host: String {
        url?.host() ?? "the server"
    }

    var title: String {
        switch kind {
        case .offline: "You Are Not Connected to the Internet"
        case .serverNotFound: "Can’t Find the Server"
        case .cannotConnect: "Can’t Connect to the Server"
        case .timedOut: "The Server Isn’t Responding"
        case .invalidCertificate: "This Connection Isn’t Private"
        case .secureConnectionFailed: "Can’t Establish a Secure Connection"
        case .crashed: "This Page Keeps Crashing"
        case .other: "Can’t Open This Page"
        }
    }

    var message: String {
        switch kind {
        case .offline:
            "This page can’t be shown because your Mac isn’t connected to the internet."
        case .serverNotFound:
            "Browser can’t open the page because it can’t find the server “\(host)”."
        case .cannotConnect:
            "Browser can’t open the page because it can’t connect to the server “\(host)”."
        case .timedOut:
            "“\(host)” took too long to respond."
        case .invalidCertificate:
            "The certificate for “\(host)” isn’t valid. The site may be impersonating “\(host)” to steal "
                + "your personal or financial information, so Browser won’t open it."
        case .secureConnectionFailed:
            "Browser can’t establish a secure connection to the server “\(host)”."
        case .crashed:
            "A problem with the page on “\(host)” made it close more than once, so Browser stopped reloading it. "
                + "It may need a feature WebKit doesn’t have; you can open it in another browser."
        case .other(let description):
            description
        }
    }

    var symbolName: String {
        switch kind {
        case .offline: "wifi.slash"
        case .invalidCertificate, .secureConnectionFailed: "lock.slash"
        case .crashed: "exclamationmark.octagon"
        default: "exclamationmark.triangle"
        }
    }
}

/// Covers a page that failed to load. There's no way past a certificate error, only Try Again.
struct PageErrorView: View {
    let error: PageLoadError
    let isLoading: Bool
    /// Another browser that might show the page, offered for errors other than certificate ones.
    var otherBrowser: OtherBrowsers.App? = nil
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: error.symbolName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(error.title)
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(error.message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack {
                Button("Try Again", action: retry)
                    .disabled(isLoading)
                if let otherBrowser, let url = error.url, error.kind != .invalidCertificate {
                    Button("Open in \(otherBrowser.name)") { OtherBrowsers.open(url, in: otherBrowser) }
                }
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
