# Browser

A native macOS browser built with SwiftUI and WebKit, with an iPhone and iPad companion.

- Runs Chrome and Safari WebExtensions: add them from the Chrome Web Store with **Add to Browser** in the address
  bar, from a ZIP, CRX, or folder, or from Safari extensions in your apps (Settings ▸ Extensions).
- Tells sites that turn away unknown browsers that it's Chrome or Firefox (View ▸ Website Compatibility), and opens
  pages that need another engine in another browser (View ▸ Open Page In).
- Syncs each profile's bookmarks and open tabs through iCloud with your other Macs, iPhone, and iPad, and hands pages
  off to them.

## Requirements

- macOS 15.4 or later; iOS and iPadOS 18.4 or later
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build

```sh
xcodegen generate
xcodebuild -project Browser.xcodeproj -scheme Browser -configuration Debug -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO
open DerivedData/Build/Products/Debug/Browser.app
```

The iPhone and iPad app is the `BrowserMobile` scheme. iCloud sync needs a build signed with `BROWSER_ICLOUD=YES`
(see [RELEASING.md](RELEASING.md)); other builds work without it.

## Contributing

See the [contributing guide](CONTRIBUTING.md). Pull requests can only be merged once you agree to the [Contributor License Agreement](CONTRIBUTOR_LICENSE_AGREEMENT.md).

## License

Copyright (C) 2026 Athas

Browser is licensed under the [GNU Affero General Public License v3.0](LICENSE) or later. Athas may also distribute it under other terms, such as through the Mac App Store.
