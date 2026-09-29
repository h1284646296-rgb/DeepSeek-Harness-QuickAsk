import Foundation

// MARK: - Locations

/// Every path this app owns, in one place.
enum Paths {
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("DSHQuickAsk", isDirectory: true)
    }()

    static var config: URL {
        if let override = ProcessInfo.processInfo.environment["DSH_QUICKASK_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return supportDirectory.appendingPathComponent("config.json")
    }

    static var log: URL {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs", isDirectory: true)
        return logs.appendingPathComponent("DSHQuickAsk.log")
    }

    static var runsDirectory: URL {
        supportDirectory.appendingPathComponent("runs", isDirectory: true)
    }

    /// 删掉一天前的运行产物：`quickask-*.command` 脚本和 `run-*/` 临时
    /// settings 目录（每次按次覆盖模型都会新建一个）。
    static func cleanKeyedRuns() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantFuture
            if modified < cutoff { try? fm.removeItem(at: entry) }
        }
    }

    static var supportDirectoryIsReady: Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: supportDirectory.path) {
            try? fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        }
        return fm.fileExists(atPath: supportDirectory.path)
    }
}

// MARK: - Logging

/// A deliberately tiny append-only log. The app is a LaunchAgent, so stderr
/// goes nowhere useful; this is the only durable trace when a hotkey or a
/// headless run goes wrong.
enum Log {
    private static let queue = DispatchQueue(label: "local.dsh.quickask.log")

    static func write(_ message: String) {
        // Mirror to stderr while debugging (`--show-panel` from a terminal).
        if ProcessInfo.processInfo.environment["DSH_QUICKASK_VERBOSE"] != nil {
            FileHandle.standardError.write(Data("dsh-quickask: \(message)\n".utf8))
        }
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if !fm.fileExists(atPath: Paths.log.path) {
                try? fm.createDirectory(at: Paths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: Paths.log.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: Paths.log) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}

// MARK: - Shell quoting

/// Single-quote a string for `/bin/bash`, escaping embedded quotes.
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
