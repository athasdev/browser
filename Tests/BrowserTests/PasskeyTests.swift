import WebKit
import XCTest
@testable import Browser

@MainActor
final class PasskeyTests: XCTestCase {
    private func shims(in controller: WKUserContentController) -> [WKUserScript] {
        controller.userScripts.filter { $0.source == WebAuthnShim.script }
    }

    func testWebAuthnIsHiddenOnlyWithoutTheEntitlement() {
        XCTAssertTrue(Passkeys.hidesWebAuthn(isEntitled: false))
        XCTAssertFalse(Passkeys.hidesWebAuthn(isEntitled: true))

        let unentitled = WKUserContentController()
        WebAuthnShim.install(in: unentitled, isEntitled: false)
        let script = shims(in: unentitled).first
        XCTAssertEqual(shims(in: unentitled).count, 1)
        XCTAssertEqual(script?.injectionTime, .atDocumentStart)
        XCTAssertEqual(script?.isForMainFrameOnly, false)

        let entitled = WKUserContentController()
        WebAuthnShim.install(in: entitled, isEntitled: true)
        XCTAssertTrue(entitled.userScripts.isEmpty)
    }

    func testEveryPageGetsTheShimUnlessTheBuildIsEntitled() {
        let configuration = BrowserTab.makeConfiguration()
        XCTAssertEqual(shims(in: configuration.userContentController).count, Passkeys.shared.isEntitled ? 0 : 1)

        let browser = BrowserModel.makePrivate(downloads: DownloadManager())
        XCTAssertEqual(shims(in: browser.makeConfiguration().userContentController).count,
                       Passkeys.shared.isEntitled ? 0 : 1)
    }

    func testPagesSeeNoWebAuthnAndPasskeyRequestsFail() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        WebAuthnShim.install(in: configuration.userContentController, isEntitled: false)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.loadHTMLString("<title>Sign In</title>", baseURL: URL(string: "https://example.com/login"))
        try await waitUntil { webView.title == "Sign In" }

        let result = try await webView.callAsyncJavaScript("""
            const failure = async (options) => {
              try { await navigator.credentials.get(options); return 'resolved'; } catch (error) { return error.name + ': ' + error.message; }
            };
            return {
              publicKeyCredential: typeof PublicKeyCredential,
              hasCredentials: typeof navigator.credentials,
              passkey: navigator.credentials ? await failure({ publicKey: { challenge: new Uint8Array(16) } }) : '',
              other: navigator.credentials ? await failure({}) : '',
            };
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: String]

        XCTAssertEqual(result?["publicKeyCredential"], "undefined")
        if result?["hasCredentials"] == "object" {
            XCTAssertEqual(result?["passkey"], "NotAllowedError: Passkeys aren’t available in this browser.")
            XCTAssertFalse(result?["other"]?.contains("Passkeys aren’t available") ?? true)
        }
    }
}
