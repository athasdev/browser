import Foundation

/// Fills the gaps between the Chrome extension APIs that extensions from the Chrome Web Store expect and the ones
/// WebKit has. An extension that touches a missing API while it starts, like 1Password with `chrome.notifications`,
/// stops with an error, so every page and background script of an installed extension first loads a small script
/// that adds harmless stand-ins for the missing APIs.
enum ExtensionCompatibility: Sendable {
    static let scriptName = "__browser_compat.js"
    static let backgroundWrapperName = "__browser_background.js"

    /// Stand-ins for APIs WebKit lacks, added only where an API is missing, so WebKit's own always win.
    static let script = #"""
    (() => {
      const namespaces = [globalThis.chrome, globalThis.browser].filter(Boolean);
      if (!namespaces.length) return;
      const event = () => {
        const listeners = new Set();
        return {
          addListener: (listener) => listeners.add(listener),
          removeListener: (listener) => listeners.delete(listener),
          hasListener: (listener) => listeners.has(listener),
          hasListeners: () => listeners.size > 0,
        };
      };
      // Chrome's APIs take a callback or return a promise.
      const answer = (value, callback) => {
        if (typeof callback === "function") { setTimeout(() => callback(value)); return undefined; }
        return Promise.resolve(value);
      };
      const lastArgument = (args) => args.length && typeof args[args.length - 1] === "function" ? args[args.length - 1] : undefined;
      const setting = () => ({
        get: (details, callback) => answer({ value: false, levelOfControl: "controllable_by_this_extension" }, callback),
        set: (details, callback) => answer(undefined, callback),
        clear: (details, callback) => answer(undefined, callback),
        onChange: event(),
      });
      const define = (name, value) => {
        for (const namespace of namespaces) {
          if (namespace[name] !== undefined) continue;
          try { Object.defineProperty(namespace, name, { value, configurable: true, enumerable: true }); } catch {}
        }
      };
      // Events WebKit doesn't send. Listening to one that's missing throws, which stops an extension starting.
      const events = {
        webNavigation: ["onCreatedNavigationTarget", "onTabReplaced", "onHistoryStateUpdated", "onReferenceFragmentUpdated"],
        tabs: ["onReplaced", "onHighlighted", "onAttached", "onDetached", "onZoomChange"],
        windows: ["onBoundsChanged"],
        runtime: ["onSuspend", "onSuspendCanceled", "onRestartRequired", "onUpdateAvailable"],
        storage: [],
      };
      const constants = (values) => () => Object.freeze(Object.fromEntries(values.map((value) => [value.toUpperCase(), value])));
      // Parts of an area WebKit doesn't have: the storage an administrator's policy fills, and the constants Chrome
      // names its string values with.
      const areas = {
        scripting: { ExecutionWorld: constants(["ISOLATED", "MAIN"]) },
        runtime: {
          OnInstalledReason: constants(["install", "update", "chrome_update", "shared_module_update"]),
          ContextType: constants(["TAB", "POPUP", "BACKGROUND", "OFFSCREEN_DOCUMENT", "SIDE_PANEL", "DEVELOPER_TOOLS"]),
          PlatformOs: constants(["mac", "win", "android", "cros", "linux", "openbsd", "fuchsia"]),
        },
        tabs: { TabStatus: constants(["unloaded", "loading", "complete"]), TAB_ID_NONE: () => -1 },
        windows: {
          WindowType: constants(["normal", "popup", "panel", "app", "devtools"]),
          WindowState: constants(["normal", "minimized", "maximized", "fullscreen", "locked-fullscreen"]),
          WINDOW_ID_NONE: () => -1, WINDOW_ID_CURRENT: () => -2,
        },
        contextMenus: {
          ContextType: constants(["all", "page", "frame", "selection", "link", "editable", "image", "video", "audio",
                                  "launcher", "browser_action", "page_action", "action"]),
          ItemType: constants(["normal", "checkbox", "radio", "separator"]),
        },
        storage: {
          managed: () => ({
            get: (...args) => answer({}, lastArgument(args)),
            getBytesInUse: (...args) => answer(0, lastArgument(args)),
            onChanged: event(),
          }),
        },
      };
      // WebKit's API objects ignore attempts to replace their areas, so the namespace itself is replaced with a
      // proxy that answers the missing events and passes everything else through.
      const areaProxies = new Map();
      const withEvents = (area, target) => {
        const names = events[area] ?? [];
        if ((!names.length && !areas[area]) || !target || typeof target !== "object") return target;
        if (areaProxies.has(target)) return areaProxies.get(target);
        const stubs = Object.fromEntries(names.filter((name) => target[name] === undefined).map((name) => [name, event()]));
        for (const [name, make] of Object.entries(areas[area] ?? {})) {
          if (target[name] === undefined) stubs[name] = make();
        }
        const proxy = !Object.keys(stubs).length ? target : new Proxy(target, {
          get(object, property) {
            const value = Reflect.get(object, property, object);
            if (value === undefined && property in stubs) return stubs[property];
            return typeof value === "function" ? value.bind(object) : value;
          },
          has: (object, property) => property in stubs || Reflect.has(object, property),
        });
        areaProxies.set(target, proxy);
        return proxy;
      };
      for (const key of ["chrome", "browser"]) {
        const namespace = globalThis[key];
        if (!namespace || namespace.__browserCompat) continue;
        const proxy = new Proxy(namespace, {
          get(object, property) {
            if (property === "__browserCompat") return true;
            const value = Reflect.get(object, property, object);
            return typeof value === "function" ? value.bind(object) : withEvents(property, value);
          },
        });
        try { Object.defineProperty(globalThis, key, { value: proxy, configurable: true, writable: true }); } catch {}
      }
      let notificationCount = 0;
      define("notifications", {
        create: (...args) => {
          const id = typeof args[0] === "string" ? args[0] : `notification-${++notificationCount}`;
          return answer(id, lastArgument(args));
        },
        update: (...args) => answer(false, lastArgument(args)),
        clear: (...args) => answer(false, lastArgument(args)),
        getAll: (...args) => answer({}, lastArgument(args)),
        getPermissionLevel: (...args) => answer("denied", lastArgument(args)),
        onClicked: event(), onClosed: event(), onButtonClicked: event(), onShowSettings: event(),
        onPermissionLevelChanged: event(),
        TemplateType: { BASIC: "basic", IMAGE: "image", LIST: "list", PROGRESS: "progress" },
        PermissionLevel: { GRANTED: "granted", DENIED: "denied" },
      });
      define("privacy", {
        network: { networkPredictionEnabled: setting(), webRTCIPHandlingPolicy: setting() },
        services: {
          autofillAddressEnabled: setting(), autofillCreditCardEnabled: setting(), autofillEnabled: setting(),
          passwordSavingEnabled: setting(),
        },
        websites: { hyperlinkAuditingEnabled: setting(), thirdPartyCookiesAllowed: setting() },
      });
      define("idle", {
        queryState: (...args) => answer("active", lastArgument(args)),
        setDetectionInterval: () => {},
        getAutoLockDelay: (...args) => answer(0, lastArgument(args)),
        onStateChanged: event(),
        IdleState: { ACTIVE: "active", IDLE: "idle", LOCKED: "locked" },
      });
    })();
    """#

    enum PatchError: LocalizedError {
        case missingManifest

        var errorDescription: String? {
            "The extension has no manifest.json."
        }
    }

    /// Adds the compatibility script to an unpacked extension: before its background script, and at the top of every
    /// page it has. Patching twice changes nothing.
    static func patch(directory: URL, fileManager: FileManager = .default) throws {
        let manifestURL = directory.appending(path: "manifest.json")
        guard let data = fileManager.contents(atPath: manifestURL.path),
              var manifest = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
        else { throw PatchError.missingManifest }
        let scriptURL = directory.appending(path: scriptName)
        if fileManager.contents(atPath: scriptURL.path) != Data(script.utf8) {
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
        }

        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String, worker != backgroundWrapperName {
                let isModule = background["type"] as? String == "module"
                let path = "/" + worker.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let wrapper = isModule ? "import \"/\(scriptName)\";\nimport \"\(path)\";\n"
                                       : "importScripts(\"/\(scriptName)\", \"\(path)\");\n"
                try Data(wrapper.utf8).write(to: directory.appending(path: backgroundWrapperName), options: .atomic)
                background["service_worker"] = backgroundWrapperName
            }
            if let scripts = background["scripts"] as? [String], scripts.first != scriptName {
                background["scripts"] = [scriptName] + scripts
            }
            manifest["background"] = background
            let output = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
            if output != data { try output.write(to: manifestURL, options: .atomic) }
        }

        if var contentScripts = manifest["content_scripts"] as? [[String: Any]] {
            var changed = false
            for index in contentScripts.indices {
                guard var scripts = contentScripts[index]["js"] as? [String], scripts.first != scriptName,
                      contentScripts[index]["world"] as? String != "MAIN" else { continue }
                scripts.insert(scriptName, at: 0)
                contentScripts[index]["js"] = scripts
                changed = true
            }
            if changed {
                manifest["content_scripts"] = contentScripts
                let output = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
                try output.write(to: manifestURL, options: .atomic)
            }
        }

        let pages = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { ["html", "htm"].contains($0.pathExtension.lowercased()) } ?? []
        for page in pages {
            try addScript(to: page)
        }
    }

    private static func addScript(to page: URL) throws {
        guard var html = try? String(contentsOf: page, encoding: .utf8) else { return }
        let tag = "<script src=\"/\(scriptName)\"></script>"
        guard !html.contains(tag) else { return }
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            html.insert(contentsOf: tag, at: head.upperBound)
        } else if let doctype = html.range(of: "<!doctype[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            html.insert(contentsOf: tag, at: doctype.upperBound)
        } else {
            html = tag + html
        }
        try html.write(to: page, atomically: true, encoding: .utf8)
    }

    /// Unpacks a ZIP archive into a folder, so the extension's files can be patched.
    static func unzip(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }

    /// What extension pages and background scripts are told about the browser. Extensions from the Chrome Web
    /// Store look for Chrome or Safari in it to choose their code paths, and stop when they find neither.
    static let applicationNameForUserAgent = "Chrome/\(ChromeWebStore.compatibleChromeVersion) Safari/605.1.15"
}
