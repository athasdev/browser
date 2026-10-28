import AuthenticationServices
import Observation
import Security
import WebKit

/// Passkeys and security keys in web pages. WebKit only runs WebAuthn for any site in an app Apple has granted its
/// web browser passkey entitlement, which builds get with BROWSER_PASSKEYS=YES (see RELEASING.md). WebKit then
/// handles the requests itself; the browser asks once for the user's permission to use their passkeys.
@MainActor
@Observable
final class Passkeys {
    static let shared = Passkeys()
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    let isEntitled: Bool
    private(set) var authorizationState: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState
    @ObservationIgnored private let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
    @ObservationIgnored private var isRequestingAuthorization = false

    init() {
        isEntitled = Self.hasEntitlement()
        authorizationState = isEntitled ? manager.authorizationStateForPlatformCredentials : .denied
    }

    /// Reads the signed entitlements, so a build without the entitlement never asks for passkeys. Unsigned builds,
    /// and builds signed without Apple's provisioning profile, never have it.
    static func hasEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? Bool == true
    }

    /// Without the entitlement WebKit still shows WebAuthn to pages, but can't finish a request: sites offer a
    /// passkey, and WebKit falls back to signing in with a phone over Bluetooth, which fails too.
    static func hidesWebAuthn(isEntitled: Bool) -> Bool {
        !isEntitled
    }

    /// Asks the user, once, to let the browser use their passkeys. The app asks as it launches and again when a
    /// window makes its first page, so the prompt is up before any page can start signing in.
    func requestAuthorizationIfNeeded() {
        guard isEntitled, authorizationState == .notDetermined, !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        Task {
            authorizationState = await manager.requestAuthorizationForPublicKeyCredentials()
            isRequestingAuthorization = false
        }
    }
}

/// Hides WebAuthn from pages in builds that can't use it, so sites treat the browser like one without passkey
/// support and offer a password or another way to sign in, instead of a passkey prompt that can only fail.
///
/// Removing `PublicKeyCredential` works better than leaving it and answering that no authenticator is available:
/// Google, GitHub, and Apple ID all check for it before offering passkeys, but with it present they still offer
/// signing in with a phone or security key, which fails the same way. Calls that skip the check and ask for a
/// `publicKey` credential fail as if the user cancelled; other credential requests work as before. This only
/// changes what pages see; WebKit itself refuses WebAuthn without the entitlement either way.
@MainActor
enum WebAuthnShim {
    static func install(in controller: WKUserContentController, isEntitled: Bool) {
        guard Passkeys.hidesWebAuthn(isEntitled: isEntitled) else { return }
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
    }

    static let script = """
    (() => {
      for (const name of ['PublicKeyCredential', 'AuthenticatorResponse', 'AuthenticatorAttestationResponse',
                          'AuthenticatorAssertionResponse']) {
        try { delete window[name]; } catch {}
      }
      const container = window.CredentialsContainer?.prototype;
      if (!container) return;
      for (const method of ['create', 'get']) {
        const original = container[method];
        if (typeof original !== 'function') continue;
        Object.defineProperty(container, method, {
          configurable: true,
          writable: true,
          value: function (options) {
            if (options && options.publicKey) {
              return Promise.reject(new DOMException('Passkeys aren’t available in this browser.', 'NotAllowedError'));
            }
            return original.apply(this, arguments);
          },
        });
      }
    })();
    """
}
