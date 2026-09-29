import Foundation

/// 按次覆盖 `agent-default-model`。
///
/// 背景：`dsh --profile headless` 用的模型来自 settings 文档里的
/// `agent-default-model` 段，而这个段又压过 composition 里的同名行 —— 所以单纯
/// 用 `--patch` 改插件 config 是没用的，存储层会把它盖掉。
///
/// 但 `settings` 插件（`@deepseek-ai/dsh-settings-file`）自己有一个 `path` 配置，
/// 而且 `--patch` overlay 在整条 patch 栈里最后生效。于是：
///
///   1. 复制一份真实 `settings.yaml`；
///   2. 只替换其中的 `agent-default-model:` 顶层块；
///   3. 写一个 `- id: settings` + `config.path` 的 overlay；
///   4. 让 headless 带上 `--patch <overlay>`。
///
/// 这样每次调用都能用自己的模型与推理档位，而全局 `~/.dsh/settings.yaml`
/// 一个字节都不会被动到（它是热重载的，直接改会和正在跑的 GUI 打架）。
enum SettingsOverride {
    /// 生成临时 settings 副本与 patch overlay，返回 overlay 的路径。
    /// 返回 nil 表示这次不需要覆盖（没选模型，或本机没有 settings.yaml）。
    static func makePatch(selection: ModelSelection?) -> URL? {
        guard let selection, !selection.model.isEmpty, !selection.provider.isEmpty else { return nil }

        let source = dshHome().appendingPathComponent("settings.yaml")
        guard FileManager.default.fileExists(atPath: source.path) else {
            Log.write("settings override skipped: \(source.path) not found")
            return nil
        }

        let directory = writableRunsDirectory().appendingPathComponent("run-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let rewritten = try rewrite(document: source, selection: selection)
            let settingsCopy = directory.appendingPathComponent("settings.yaml")
            try rewritten.write(to: settingsCopy, atomically: true, encoding: .utf8)
            let patch = directory.appendingPathComponent("patch.yml")
            try patchBody(settingsPath: settingsCopy.path).write(to: patch, atomically: true, encoding: .utf8)
            Log.write("settings override: \(selection.provider)/\(selection.model) effort=\(selection.effort ?? "-")")
            return patch
        } catch {
            Log.write("settings override failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// overlay 的内容：把 `settings` 行的文档路径换成临时副本。
    static func patchBody(settingsPath: String) -> String {
        """
        # 由 DSH Quick Ask 生成。把 settings 文档换成本次的临时副本，
        # 从而在不改动全局 ~/.dsh/settings.yaml 的前提下按次选择模型与推理档位。
        - id: settings
          config:
            path: \(quote(settingsPath))
        """
    }

    /// 只替换 `agent-default-model:` 这个顶层块，其它行原样保留。
    ///
    /// 刻意不做完整 YAML 解析：这份文件里有大量注释、锚点（`&bailian_efforts`）
    /// 和别名引用，重新序列化会全部丢掉；而我们要改的只是一个顶层映射。
    static func rewrite(document: URL, selection: ModelSelection) throws -> String {
        let text = try String(contentsOf: document, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")

        var block: [String] = ["agent-default-model:"]
        block.append("  provider: \(quote(selection.provider))")
        block.append("  model: \(quote(selection.model))")
        if let effort = selection.effort, !effort.isEmpty {
            block.append("  reasoningEffort: \(quote(effort))")
        }

        var output: [String] = []
        var replaced = false
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if !replaced, line.hasPrefix("agent-default-model:") {
                output.append(contentsOf: block)
                index += 1
                // 跳过属于这个键的缩进块（以及其中的空行）。
                while index < lines.count {
                    let candidate = lines[index]
                    let trimmed = candidate.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { index += 1; continue }
                    if candidate.hasPrefix(" ") || candidate.hasPrefix("\t") { index += 1; continue }
                    break
                }
                replaced = true
                continue
            }
            output.append(line)
            index += 1
        }

        if !replaced {
            if output.last?.isEmpty == false { output.append("") }
            output.append(contentsOf: block)
        }
        lines = output
        return lines.joined(separator: "\n")
    }

    /// 优先用 Application Support 下的 runs 目录；万一不可写（受限环境、
    /// 只读家目录），退到系统临时目录 —— 有兜底总比整条按次覆盖静默失效好。
    static func writableRunsDirectory() -> URL {
        let primary = Paths.runsDirectory
        if (try? FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)) != nil {
            return primary
        }
        Log.write("runs 目录不可写，退到临时目录：\(primary.path)")
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dsh-quickask-runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static func dshHome() -> URL {
        if let home = ProcessInfo.processInfo.environment["DSH_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh", isDirectory: true)
    }

    private static func quote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
