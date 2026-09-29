import AppKit
import Foundation

/// Non-GUI entry points: the report printed by `--diagnose`, the model-catalog
/// extractor, and the foreground one-shot runner used by `--ask` / `--selftest`.
///
/// The foreground runner deliberately does **not** reuse `HeadlessRunner`: that
/// class streams through `DispatchQueue.main`, which needs a running event
/// loop. Here stdout and stderr are merged into one pipe and drained with
/// blocking reads, which needs nothing at all and therefore cannot hang.
enum Diagnostics {
    static func report(config: QuickAskConfig) -> String {
        var lines: [String] = []
        lines.append("DSH Quick Ask — 诊断")
        lines.append("")
        lines.append("配置文件      : \(Paths.config.path)")
        lines.append("               \(FileManager.default.fileExists(atPath: Paths.config.path) ? "存在" : "不存在（使用默认值）")")
        lines.append("日志          : \(Paths.log.path)")
        lines.append("触发方式      : \(config.trigger.rawValue)")
        lines.append("              · 连按两下 Shift: \(config.trigger.wantsDoubleShift ? "开" : "关")（窗口 \(Int(config.doubleShiftWindow * 1000))ms，需要辅助功能/输入监视授权）")
        lines.append("              · 组合键        : \(config.trigger.wantsHotKey ? config.hotkey.display : "关")")
        lines.append("默认执行方式  : \(config.mode.rawValue)")
        lines.append("权限          : 输入监视=\(AccessibilityGate.hasListenAccess) 辅助功能=\(AccessibilityGate.isTrusted)")
        lines.append("              · 双击 Shift（免授权备选）可注册 Carbon 热键: \(CarbonDoubleShift.probe() ? "是" : "否")")
        lines.append("彩虹跑马灯    : \(config.rainbow ? "开" : "关")")
        lines.append("音效          : \(config.sound.isEmpty ? "关" : config.sound)")
        lines.append("工作区        : \(config.workspace)")
        lines.append("               \(FileManager.default.fileExists(atPath: config.workspace) ? "存在" : "不存在")")
        lines.append("node          : \(config.nodePath.isEmpty ? "未找到" : config.nodePath)")
        lines.append("dsh 入口      : \(config.dshEntry.isEmpty ? "未找到" : config.dshEntry)")
        lines.append("")
        lines.append("模型选择      : \(config.selection.model.isEmpty ? "（未选）" : "\(config.selection.provider)/\(config.selection.model)")")
        lines.append("推理深度      : \(config.selection.effort ?? "（默认）")")
        lines.append("模型目录      : \(config.catalog.count) 个")
        for entry in config.catalog.prefix(24) {
            let efforts = entry.efforts.map { $0.joined(separator: "/") } ?? "默认"
            lines.append("              · \(entry.name)  [\(entry.provider)/\(entry.model)] 推理=\(efforts)")
        }
        if config.catalog.count > 24 { lines.append("              · …") }
        lines.append("")

        if config.notes.isEmpty {
            lines.append("备注          : 无")
        } else {
            lines.append("备注:")
            for note in config.notes { lines.append("  · \(note)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Live keyboard watch

    /// 实时旁听 `flagsChanged`，把每一个 Shift 事件打出来。
    ///
    /// 这是回答「连按两下 Shift 为什么没反应」的唯一确定手段：如果这里一个事件都
    /// 打不出来，就是没授权；如果打出来了但面板不出，那就是判定逻辑的问题。
    static func watchShift(seconds: Double) -> Int32 {
        let trusted = AccessibilityGate.isTrusted
        let listen = AccessibilityGate.hasListenAccess
        print("输入监视授权 (CGPreflightListenEventAccess) = \(listen)")
        print("辅助功能授权 (AXIsProcessTrusted)            = \(trusted)")
        print("")
        if !listen, !trusted {
            print("⚠️  两项都没有。下面多半收不到任何事件。")
            print("    请到「系统设置 → 隐私与安全性」给 DSH Quick Ask 打开")
            print("    「辅助功能」或「输入监视」，然后完全重启 App 再试。")
            print("")
        }

        var count = 0
        let monitor = DoubleShiftMonitor(window: 0.4)
        monitor.onEvent = { (keyCode: Int64, shiftDown: Bool) in
            count += 1
            let name = keyCode == 56 ? "左Shift" : (keyCode == 60 ? "右Shift" : "其它(\(keyCode))")
            print("  [\(count)] \(name) \(shiftDown ? "按下" : "松开")")
        }

        guard monitor.arm() else {
            print("✗ CGEvent.tapCreate 失败：没有授权，无法旁听键盘。")
            print("  请到「系统设置 → 隐私与安全性」勾选「DSH Quick Ask」的")
            print("  「输入监视」（或「辅助功能」），然后把本命令重跑一次。")
            return 1
        }
        print("✓ 事件 tap 已建立，开始旁听 \(Int(seconds)) 秒。")
        print("  现在连按两下 Shift（其它键不会打印）…")
        print("")

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        monitor.disarm()
        print("")
        if count == 0 {
            print("✗ 这段时间里一个 Shift 事件都没收到 —— 授权没生效。")
            print("  · 确认「系统设置 → 隐私与安全性 → 输入监视」里 DSH Quick Ask 是打开的；")
            print("  · 授权后必须**完全退出并重启 App**，macOS 不会给已运行的进程补发权限。")
            return 2
        }
        print("✓ 共收到 \(count) 个事件 —— 监听链路是通的。")
        return 0
    }

    // MARK: - Trigger logic self-test

    /// 「连按两下 Shift」判定逻辑的离线自检。
    ///
    /// 事件 tap 本身没法在自动化里模拟真实按键（那需要辅助功能权限），但把按键
    /// 时序喂给状态机、断言「该触发的触发、不该触发的不触发」是可以的 —— 而这段
    /// 时序逻辑正是最容易写错的地方。
    static func triggerSelfTest() -> Int32 {
        var failures = 0
        var cases = 0

        func expect(_ name: String, _ expected: Bool, _ actual: Bool) {
            cases += 1
            let mark = expected == actual ? "✓" : "✗"
            print("    \(mark) \(name)  期望=\(expected ? "触发" : "不触发") 实际=\(actual ? "触发" : "不触发")")
            if expected != actual { failures += 1 }
        }

        print("双击 Shift 判定自检（窗口 400ms，冷却 500ms）")

        // 1) 400ms 内按两下 → 触发
        var detector = DoubleShiftDetector(window: 0.4)
        _ = detector.feed(keyCode: 56, shiftDown: true, at: 0.00)
        _ = detector.feed(keyCode: 56, shiftDown: false, at: 0.05)
        expect("快速两下（间隔 200ms）", true, detector.feed(keyCode: 56, shiftDown: true, at: 0.20))

        // 2) 超过窗口 → 不算；随后再补一下才算
        detector = DoubleShiftDetector(window: 0.4)
        _ = detector.feed(keyCode: 56, shiftDown: true, at: 0.00)
        _ = detector.feed(keyCode: 56, shiftDown: false, at: 0.05)
        let slow = detector.feed(keyCode: 56, shiftDown: true, at: 0.60)
        expect("间隔 600ms 的第一下", false, slow)
        _ = detector.feed(keyCode: 56, shiftDown: false, at: 0.65)
        expect("紧接着的下一对", true, detector.feed(keyCode: 56, shiftDown: true, at: 0.80))

        // 3) 只按一下 → 不触发
        detector = DoubleShiftDetector(window: 0.4)
        _ = detector.feed(keyCode: 56, shiftDown: true, at: 0.00)
        expect("单按一下", false, detector.feed(keyCode: 56, shiftDown: false, at: 0.05))

        // 4) 连按三下 → 只触发一次
        detector = DoubleShiftDetector(window: 0.4)
        _ = detector.feed(keyCode: 56, shiftDown: true, at: 0.00)
        _ = detector.feed(keyCode: 56, shiftDown: false, at: 0.05)
        let first = detector.feed(keyCode: 56, shiftDown: true, at: 0.15)
        _ = detector.feed(keyCode: 56, shiftDown: false, at: 0.20)
        let third = detector.feed(keyCode: 56, shiftDown: true, at: 0.30)
        expect("连按三下的第二下", true, first)
        expect("连按三下的第三下（冷却中）", false, third)

        // 5) 右 Shift 同样有效
        detector = DoubleShiftDetector(window: 0.4)
        _ = detector.feed(keyCode: 60, shiftDown: true, at: 0.00)
        _ = detector.feed(keyCode: 60, shiftDown: false, at: 0.05)
        expect("右 Shift 两下", true, detector.feed(keyCode: 60, shiftDown: true, at: 0.25))

        // 6) 长按产生的重复事件不算第二次
        detector = DoubleShiftDetector(window: 0.4)
        _ = detector.feed(keyCode: 56, shiftDown: true, at: 0.00)
        _ = detector.feed(keyCode: 56, shiftDown: true, at: 0.05)
        expect("长按重复事件", false, detector.feed(keyCode: 56, shiftDown: true, at: 0.10))

        // 7) 非 Shift 键被忽略
        detector = DoubleShiftDetector(window: 0.4)
        _ = detector.feed(keyCode: 0, shiftDown: true, at: 0.00)
        _ = detector.feed(keyCode: 1, shiftDown: true, at: 0.05)
        expect("按 A、S 两下", false, detector.feed(keyCode: 2, shiftDown: true, at: 0.10))

        print(failures == 0 ? "  全部通过（\(cases) 项）" : "  \(failures)/\(cases) 项失败")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Model catalog

    /// 运行随包的 `model-catalog.js`（用 dsh 自带的 js-yaml），拿回目录 JSON。
    static func extractCatalog(config: QuickAskConfig) -> [String: Any]? {
        guard let script = Bundle.main.url(forResource: "model-catalog", withExtension: "js") else {
            FileHandle.standardError.write(Data("dsh-quickask: 包里没有 model-catalog.js\n".utf8))
            return nil
        }
        guard !config.nodePath.isEmpty else {
            FileHandle.standardError.write(Data("dsh-quickask: 没有 node，无法提取模型目录\n".utf8))
            return nil
        }

        let settings = SettingsOverride.dshHome().appendingPathComponent("settings.yaml")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.nodePath)
        process.arguments = [script.path, settings.path, config.dshEntry]
        process.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("dsh-quickask: 启动 node 失败 \(error.localizedDescription)\n".utf8))
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            FileHandle.standardError.write(Data("dsh-quickask: model-catalog.js 退出码 \(process.terminationStatus)\n".utf8))
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 提取目录并写回配置文件，返回新的模型个数。
    @discardableResult
    static func refreshCatalog(config: QuickAskConfig) -> Int {
        guard let catalog = extractCatalog(config: config) else { return 0 }
        QuickAskConfig.persist(["catalog": catalog])
        let models = catalog["models"] as? [[String: Any]] ?? []
        Log.write("模型目录已刷新：\(models.count) 个模型")
        return models.count
    }

    /// 走**面板那条完全相同的代码路径**（HeadlessRunner）跑一次。
    /// 存在的意义就是让「面板里按回车」这件事可以被自动化测试覆盖 ——
    /// 上一版正是因为没有这条路径的测试，漏掉了 argv 里少一个入口路径的 bug。
    static func runInline(task: String, config: QuickAskConfig) -> Int32 {
        guard !config.nodePath.isEmpty, !config.dshEntry.isEmpty else {
            FileHandle.standardError.write(Data("dsh-quickask: 无法解析 node 或 dsh 入口\n".utf8))
            return 2
        }
        let patch = SettingsOverride.makePatch(selection: config.selection)
        let runner = HeadlessRunner()
        runner.deliverOnMainThread = false

        var code: Int32 = -1
        var finished = false
        runner.onStdErr = { text in FileHandle.standardOutput.write(Data(text.utf8)) }
        runner.onStdOut = { text in FileHandle.standardOutput.write(Data(text.utf8)) }
        runner.onFinish = { status, seconds in
            FileHandle.standardError.write(Data(String(format: "[inline done] code=%d %.1fs\n", status, seconds).utf8))
            code = status
            finished = true
        }

        runner.start(
            task: task,
            workspace: config.workspace,
            node: config.nodePath,
            dshEntry: config.dshEntry,
            patch: patch
        )

        let deadline = Date().addingTimeInterval(600)
        while !finished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return finished ? code : 124
    }

    // MARK: - Foreground run

    /// Runs one headless turn in the foreground, mirroring every byte to this
    /// process's stdout, and returns the child's exit code.
    static func runForeground(task: String, config: QuickAskConfig) -> Int32 {
        guard !config.nodePath.isEmpty, !config.dshEntry.isEmpty else {
            FileHandle.standardError.write(Data("dsh-quickask: 无法解析 node 或 dsh 入口，请先运行 --diagnose\n".utf8))
            return 2
        }

        let patch = SettingsOverride.makePatch(selection: config.selection)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.nodePath)
        process.arguments = HeadlessInvocation.arguments(entry: config.dshEntry, task: task, patch: patch)
        process.currentDirectoryURL = URL(fileURLWithPath: config.workspace)

        var environment = ProcessInfo.processInfo.environment
        let nodeDirectory = (config.nodePath as NSString).deletingLastPathComponent
        environment["PATH"] = [
            nodeDirectory, "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("dsh-quickask: 启动失败 \(error.localizedDescription)\n".utf8))
            return 127
        }

        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            FileHandle.standardOutput.write(chunk)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
