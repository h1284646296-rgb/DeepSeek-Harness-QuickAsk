import Foundation

// MARK: - Hotkey specification

/// One global hotkey: a virtual key code plus Carbon modifier flags.
struct HotKeySpec: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let display: String
}

/// Parses `"option+space"`-style hotkey strings into Carbon values.
///
/// Only the combinations this launcher realistically needs are supported: a run
/// of modifiers (`cmd`/`command`, `opt`/`option`/`alt`, `ctrl`/`control`,
/// `shift`) followed by one letter, digit, or named key. Symbol forms
/// (`⌥`, `⌘`, `⌃`, `⇧`) are accepted too, because that is how the display
/// string reads.
enum QuickAskHotKey {
    // Carbon modifier masks (Events.h). Spelled out so this file needs no import.
    static let command: UInt32 = 0x0100
    static let shift: UInt32 = 0x0200
    static let option: UInt32 = 0x0800
    static let control: UInt32 = 0x1000

    /// ANSI virtual key codes for the keys worth binding.
    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "space": 49, "tab": 48, "return": 36, "enter": 36, "escape": 53,
    ]

    /// ⌥Space: unclaimed by macOS by default (Spotlight owns ⌘Space).
    static let fallback = HotKeySpec(keyCode: 49, carbonModifiers: option, display: "⌥Space")

    static func parse(_ text: String) -> HotKeySpec? {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "⌘", with: "cmd+")
            .replacingOccurrences(of: "⌥", with: "option+")
            .replacingOccurrences(of: "⌃", with: "control+")
            .replacingOccurrences(of: "⇧", with: "shift+")

        let parts = normalized
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let keyPart = parts.last, let keyCode = keyCodes[keyPart] else { return nil }

        var modifiers: UInt32 = 0
        var symbols = ""
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "super", "meta":
                modifiers |= command
                symbols += "⌘"
            case "opt", "option", "alt":
                modifiers |= option
                symbols += "⌥"
            case "ctrl", "control":
                modifiers |= control
                symbols += "⌃"
            case "shift":
                modifiers |= shift
                symbols += "⇧"
            default:
                return nil
            }
        }

        // A bare key would swallow ordinary typing system-wide; refuse it.
        guard modifiers != 0 else { return nil }
        return HotKeySpec(keyCode: keyCode, carbonModifiers: modifiers, display: symbols + label(for: keyPart))
    }

    private static func label(for key: String) -> String {
        switch key {
        case "space": return "Space"
        case "tab": return "⇥"
        case "return", "enter": return "↩"
        case "escape": return "⎋"
        default: return key.uppercased()
        }
    }
}

// MARK: - Trigger

/// What brings the panel up.
enum TriggerMode: String {
    /// 连按两下 Shift（默认，走 CGEventTap，需要「输入监视」授权）。
    case doubleShift = "double-shift"
    /// 连按两下 Shift，但把 Shift 本身注册成 Carbon 热键 —— 免授权，可能影响大写。
    case doubleShiftCarbon = "double-shift-carbon"
    /// 传统的组合键。
    case hotkey
    /// 两者都行。
    case both

    static func from(_ raw: String?) -> TriggerMode {
        guard let raw else { return .doubleShift }
        return TriggerMode(rawValue: raw.lowercased()) ?? .doubleShift
    }

    var wantsDoubleShift: Bool {
        self == .doubleShift || self == .both || self == .doubleShiftCarbon
    }
    var wantsHotKey: Bool { self == .hotkey || self == .both }
}

/// How a submitted prompt is executed.
enum RunMode: String {
    /// Stream the answer into the floating panel (Spotlight-like).
    case inline
    /// Open a Terminal window and run the one-shot there (visible, long tasks).
    case terminal

    static func from(_ raw: String?) -> RunMode {
        guard let raw else { return .inline }
        return RunMode(rawValue: raw.lowercased()) ?? .inline
    }
}

// MARK: - Model catalog

/// One selectable model, extracted from `~/.dsh/settings.yaml` by
/// `tools/model-catalog.js`.
struct CatalogModel: Equatable {
    let provider: String
    let model: String
    let name: String
    /// `nil` means the adapter did not declare a ladder: send nothing and let
    /// the harness use its own default.
    let efforts: [String]?

    var key: String { "\(provider)/\(model)" }
}

/// 面板上模型/档位的选择。
struct ModelSelection: Equatable {
    var provider: String
    var model: String
    var effort: String?

    var isEmpty: Bool { provider.isEmpty || model.isEmpty }
    var key: String { "\(provider)/\(model)" }
}

// MARK: - Configuration

struct QuickAskConfig {
    var trigger: TriggerMode
    /// 组合键。`hotkeyEnabled == false` 表示显式关掉（配置里写 `"hotkey": ""`）。
    var hotkey: HotKeySpec
    var hotkeyEnabled: Bool
    /// Two Shift presses inside this window count as a double press.
    var doubleShiftWindow: TimeInterval
    var workspace: String
    var nodePath: String
    var dshEntry: String
    var mode: RunMode
    /// Rainbow marquee around the panel.
    var rainbow: Bool
    /// `duang` (bundled), a system sound name, or `""` for silence.
    var sound: String
    var catalog: [CatalogModel]
    var selection: ModelSelection
    /// 诊断开关：把每个 Shift 按键事件写进日志，用来判断权限是否生效。
    var debugShiftEvents: Bool
    /// Non-fatal problems found while loading, surfaced by `--diagnose`.
    var notes: [String]

    /// Used when no catalog has been extracted yet: the DeepSeek adapter's own
    /// built-in list and the effort ladder it accepts.
    static let builtinCatalog: [CatalogModel] = [
        CatalogModel(provider: "deepseek-official", model: "deepseek-flash",
                     name: "DeepSeek-V41-Flash", efforts: ["off", "low", "high", "max"]),
        CatalogModel(provider: "deepseek-official", model: "deepseek-v4-flash",
                     name: "DeepSeek-V4-Flash", efforts: ["off", "low", "high", "max"]),
        CatalogModel(provider: "deepseek-official", model: "deepseek-v4-pro",
                     name: "DeepSeek-V4-Pro", efforts: ["off", "low", "high", "max"]),
        CatalogModel(provider: "deepseek-official", model: "deepseek-v4-flash-vision-exp",
                     name: "DeepSeek-V4-Flash-Vision-Exp", efforts: ["off", "low", "high", "max"]),
    ]

    static func load() -> QuickAskConfig {
        var notes: [String] = []
        let url = Paths.config
        var raw: [String: Any] = [:]

        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            raw = parsed
        } else {
            notes.append("未读到配置文件 \(url.path)，全部使用默认值")
        }

        let hotkeyText = raw["hotkey"] as? String
        var hotkey = QuickAskHotKey.fallback
        var hotkeyEnabled = true
        if let hotkeyText {
            if hotkeyText.trimmingCharacters(in: .whitespaces).isEmpty {
                // 显式关闭：默认只用双击 Shift，不再占用任何组合键。
                hotkeyEnabled = false
            } else if let parsed = QuickAskHotKey.parse(hotkeyText) {
                hotkey = parsed
            } else {
                notes.append("hotkey \"\(hotkeyText)\" 无法解析，回退到 \(QuickAskHotKey.fallback.display)")
            }
        }

        let defaultWorkspace = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/harness", isDirectory: true)
        var workspace = (raw["workspace"] as? String) ?? defaultWorkspace.path
        workspace = (workspace as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: workspace) {
            notes.append("workspace \(workspace) 不存在，回退到用户主目录")
            workspace = FileManager.default.homeDirectoryForCurrentUser.path
        }

        let node = RuntimeResolver.resolveNode(configured: raw["nodePath"] as? String)
        let entry = RuntimeResolver.resolveDshEntry(configured: raw["dshEntry"] as? String)
        if let node { notes.append("node = \(node.path)") } else { notes.append("找不到 node") }
        if let entry { notes.append("dsh = \(entry.path)") } else { notes.append("找不到 dsh 入口") }

        var catalog = parseCatalog(raw["catalog"])
        if catalog.isEmpty {
            catalog = builtinCatalog
            notes.append("模型目录为空，使用内置的 DeepSeek 列表")
        }

        // 选择优先级：配置文件里记住的 > settings.yaml 里的当前默认 > 目录第一项。
        var selection = ModelSelection(
            provider: (raw["provider"] as? String) ?? "",
            model: (raw["model"] as? String) ?? "",
            effort: raw["effort"] as? String
        )
        if selection.isEmpty, let current = raw["catalog"] as? [String: Any], let now = current["current"] as? [String: Any] {
            selection = ModelSelection(
                provider: (now["provider"] as? String) ?? "",
                model: (now["model"] as? String) ?? "",
                effort: now["effort"] as? String
            )
        }
        if selection.isEmpty, let first = catalog.first {
            selection = ModelSelection(provider: first.provider, model: first.model, effort: first.efforts?.first)
        }

        let windowMs = (raw["doubleShiftWindowMs"] as? NSNumber)?.doubleValue ?? 400

        return QuickAskConfig(
            trigger: TriggerMode.from(raw["trigger"] as? String),
            hotkey: hotkey,
            hotkeyEnabled: hotkeyEnabled,
            doubleShiftWindow: max(0.15, windowMs / 1000),
            workspace: workspace,
            nodePath: node?.path ?? "",
            dshEntry: entry?.path ?? "",
            mode: RunMode.from(raw["mode"] as? String),
            rainbow: (raw["rainbow"] as? NSNumber)?.boolValue ?? true,
            sound: (raw["sound"] as? String) ?? "duang",
            catalog: catalog,
            selection: selection,
            debugShiftEvents: (raw["debugShiftEvents"] as? NSNumber)?.boolValue ?? false,
            notes: notes
        )
    }

    /// 面板上改动选择后写回配置文件，下次启动仍然记得。
    static func persistSelection(_ selection: ModelSelection) {
        persist([
            "provider": selection.provider,
            "model": selection.model,
            "effort": selection.effort ?? "",
        ])
    }

    /// 把若干键合并回磁盘上的配置文件（保留其它键）。
    static func persist(_ updates: [String: Any]) {
        guard Paths.supportDirectoryIsReady else { return }
        var raw: [String: Any] = [:]
        if let data = try? Data(contentsOf: Paths.config),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            raw = parsed
        }
        for (key, value) in updates { raw[key] = value }
        guard let data = try? JSONSerialization.data(
            withJSONObject: raw,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? data.write(to: Paths.config)
    }

    static func writeDefaultIfMissing(workspace: String, node: String, dsh: String, catalog: [CatalogModel]) {
        guard Paths.supportDirectoryIsReady else { return }
        guard !FileManager.default.fileExists(atPath: Paths.config.path) else { return }
        var body: [String: Any] = [
            "trigger": TriggerMode.doubleShift.rawValue,
            // 默认不占用任何组合键：只认连按两下 Shift。
            "hotkey": "",
            "doubleShiftWindowMs": 400,
            "workspace": workspace,
            "nodePath": node,
            "dshEntry": dsh,
            "mode": "inline",
            "rainbow": true,
            "sound": "duang",
        ]
        if let first = catalog.first {
            body["provider"] = first.provider
            body["model"] = first.model
            body["effort"] = first.efforts?.first ?? ""
        }
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.config)
        }
    }

    static func parseCatalog(_ raw: Any?) -> [CatalogModel] {
        guard let dictionary = raw as? [String: Any],
              let list = dictionary["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let provider = entry["provider"] as? String,
                  let model = entry["model"] as? String else { return nil }
            return CatalogModel(
                provider: provider,
                model: model,
                name: (entry["name"] as? String) ?? model,
                efforts: entry["efforts"] as? [String]
            )
        }
    }
}

// MARK: - Runtime resolution

/// Finds the Node binary and the `dsh` entry script.
///
/// The installer normally bakes both paths into `config.json`; these searches
/// exist so the app still works when the config is missing, stale, or when the
/// npx cache directory changed after an upgrade.
enum RuntimeResolver {
    static func resolveNode(configured: String?) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let configured, !configured.isEmpty { candidates.append((configured as NSString).expandingTildeInPath) }
        candidates += [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node",
        ]
        // nvm / fnm style version managers.
        let home = fm.homeDirectoryForCurrentUser
        for base in [".nvm/versions/node", ".local/share/fnm/node-versions", ".volta/bin"] {
            let dir = home.appendingPathComponent(base, isDirectory: true)
            if let entries = try? fm.contentsOfDirectory(atPath: dir.path) {
                for entry in entries.sorted().reversed() {
                    candidates.append(dir.appendingPathComponent(entry).appendingPathComponent("bin/node").path)
                    candidates.append(dir.appendingPathComponent(entry).appendingPathComponent("node").path)
                }
            }
        }
        return firstExecutable(candidates)
    }

    static func resolveDshEntry(configured: String?) -> URL? {
        let fm = FileManager.default
        if let configured, !configured.isEmpty {
            let path = (configured as NSString).expandingTildeInPath
            if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }

        var candidates: [URL] = []
        let home = fm.homeDirectoryForCurrentUser

        // The npx cache: `~/.npm/_npx/<hash>/node_modules/@deepseek-ai/dsh/lib/bin.js`
        let npxRoot = home.appendingPathComponent(".npm/_npx", isDirectory: true)
        if let hashes = try? fm.contentsOfDirectory(atPath: npxRoot.path) {
            for hash in hashes {
                candidates.append(npxRoot
                    .appendingPathComponent(hash)
                    .appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js"))
            }
        }

        candidates += [
            URL(fileURLWithPath: "/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"),
            home.appendingPathComponent(".dsh/profiles/node_modules/@deepseek-ai/dsh/lib/bin.js"),
            home.appendingPathComponent(".local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"),
        ]

        // Newest wins: an upgraded install beats a stale copy.
        let existing = candidates.filter { fm.fileExists(atPath: $0.path) }
        let newest = existing.max { a, b in modificationDate(a) < modificationDate(b) }
        return newest
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func firstExecutable(_ paths: [String]) -> URL? {
        let fm = FileManager.default
        for path in paths where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
