# Releasing

Pushing a version tag runs [the release workflow](.github/workflows/release.yml). It builds the Release configuration, signs it with the Developer ID certificate, notarizes and staples the app, makes a signed and notarized disk image, signs the update for Sparkle, adds it to the appcast, and publishes a GitHub release with the disk image and `appcast.xml`.

The release is public as soon as the workflow finishes, and Sparkle offers it to everyone, so only tag a commit you've tested.

```sh
git tag v0.2.0
git push origin v0.2.0
```

The version comes from the tag, and the build number is the number of commits. A tag with a hyphen, like `v0.2.0-beta.1`, makes a prerelease, which Sparkle doesn't offer, since the feed is the latest full release's `appcast.xml`.

## One-time setup

### Developer ID certificate

1. In Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates, add a **Developer ID Application** certificate. Only the Account Holder can create one.
2. In Keychain Access, export the certificate with its private key as a `.p12` file with a password.
3. Run `base64 -i Certificates.p12 | pbcopy` and save it as the `DEVELOPER_ID_CERTIFICATE_P12_BASE64` secret.

### Notarization key

1. In App Store Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect API, create a team key with the Developer role.
2. Download the `AuthKey_….p8` file (it can only be downloaded once), run `base64 -i AuthKey_….p8 | pbcopy`, and save it as `APP_STORE_CONNECT_API_KEY_P8_BASE64`.
3. Save the key ID as `APP_STORE_CONNECT_API_KEY_ID` and the issuer ID shown above the keys as `APP_STORE_CONNECT_API_ISSUER_ID`.

### Sparkle keys

Sparkle only installs updates signed with the private key that matches the public key in the app. `project.yml` ships with a placeholder, `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY`, and updates stay off until it's replaced.

1. Download `Sparkle-2.10.0.tar.xz` (the version in `project.yml`) from [Sparkle's releases](https://github.com/sparkle-project/Sparkle/releases) and extract it.
2. Run `./bin/generate_keys`. It saves a new private key in your login keychain and prints the public key.
3. Replace the placeholder for `SPARKLE_PUBLIC_ED_KEY` in `project.yml` with the public key and commit it, or save it as the `SPARKLE_PUBLIC_ED_KEY` repository variable.
4. Run `./bin/generate_keys -x sparkle-private-key.txt`, save the file's contents as the `SPARKLE_PRIVATE_ED_KEY` secret, and delete the file.

Keep the private key backed up in the keychain or a password manager. Without it, apps already installed can't verify new updates.

### Secrets and variables

Set these in the repository's Settings ▸ Secrets and variables ▸ Actions.

| Name | Kind | What |
| --- | --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | Secret | The Developer ID Application certificate and key, as base64 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Secret | The `.p12` file's password |
| `APPLE_TEAM_ID` | Secret | The 10-character team ID |
| `APP_STORE_CONNECT_API_KEY_P8_BASE64` | Secret | The App Store Connect API key, as base64 |
| `APP_STORE_CONNECT_API_KEY_ID` | Secret | The API key's ID |
| `APP_STORE_CONNECT_API_ISSUER_ID` | Secret | The API key's issuer ID |
| `SPARKLE_PRIVATE_ED_KEY` | Secret | Sparkle's private EdDSA key |
| `SPARKLE_PUBLIC_ED_KEY` | Variable | Sparkle's public key, unless it's in `project.yml` |
| `DEVELOPER_ID_PROVISIONING_PROFILE_BASE64` | Secret | Optional, only for passkeys (see below) |

## Passkeys

WebKit only lets an app use passkeys and security keys on any website if Apple grants it the `com.apple.developer.web-browser.public-key-credential` entitlement. The code is ready: builds with `BROWSER_PASSKEYS=YES` are signed with `Config/Browser-Passkeys.entitlements` (or `Config/BrowserAppStore-Passkeys.entitlements`), the app asks once for permission to use the user's passkeys, and Settings ▸ Passwords shows the state. Other builds leave the entitlement out, since an app signed with it but without a matching provisioning profile won't launch.

1. The Account Holder fills in Apple's [macOS Browsers Passkeys request form](https://developer.apple.com/contact/request/macos-browsers-passkeys/) for the App ID `dev.athas.browser`. Apple requires that the app declares the `http` and `https` schemes (it does), shows a field for entering addresses on launch (it does), and opens links unchanged.
2. Once Apple approves, the entitlement shows up as a managed capability for `dev.athas.browser` in Certificates, Identifiers & Profiles. Turn it on for the App ID.
3. Create a **Developer ID** provisioning profile for `dev.athas.browser` that includes it, run `base64 -i Browser.provisionprofile | pbcopy`, and save it as `DEVELOPER_ID_PROVISIONING_PROFILE_BASE64`. The release workflow then builds with passkeys.
4. For the Mac App Store, create a Mac App Store profile too and archive the `BrowserAppStore` scheme with `BROWSER_PASSKEYS=YES`.

## Mac App Store

The `BrowserAppStore` target builds the same app with the `APP_STORE` flag and without Sparkle, which the store replaces. It isn't automated: archive the `BrowserAppStore` scheme in Xcode and upload it from the Organizer.

## iCloud sync

Bookmarks and open tabs sync through the private CloudKit database in the container `iCloud.dev.athas.browser`, one
record zone per profile. Builds with `BROWSER_ICLOUD=YES` are signed with the `-iCloud` entitlements files in
`Config/`, which add the container, CloudKit, and push notifications; the app reads its entitlements and leaves
CloudKit alone without them, so other builds just show sync as unavailable.

1. In the Apple Developer portal, create the iCloud container `iCloud.dev.athas.browser` and enable iCloud (CloudKit)
   and Push Notifications for `dev.athas.browser` and `dev.athas.browser.mobile`.
2. Regenerate the provisioning profiles (Developer ID, Mac App Store, and iOS App Store) so they include the container.
3. Build or archive with `BROWSER_ICLOUD=YES`, alongside `BROWSER_PASSKEYS=YES` when that entitlement is granted.
4. Before the first public release, deploy the CloudKit schema from Development to Production in the CloudKit Console
   after running a development build once: the record types are `Bookmark`, `DeviceTabs`, and `Profile`.

