import AppKit
import Foundation

/// The exact argv both execution paths hand to `node <dsh bin.js>`.
///
/// `entry` 是**必填参数**，不是可选的：node 的第一个位置参数必须是脚本路径，
/// 少了它 node 会把 `--profile` 当成自己的选项，直接
/// `/usr/local/bin/node: bad option: --profile` 然后 exit 9。
/// 之前这个列表是各处自己拼的，面板那条路就漏掉了入口路径 ——
/// 把入口变成签名的一部分之后，这种漏写在编译期就不可能发生。
enum HeadlessInvocation {
    /// `--patch` must follow `--profile`, exactly as the launcher documents it
    /// (`dsh --profile tui --patch ./extra.yml`): the launcher consumes its own
    /// flags, then everything left over reaches the booted app.
    static func arguments(entry: String, task: String, patch: URL?) -> [String] {
        var args = [entry, "--profile", "headless"]
        if let patch { args += ["--patch", patch.path] }
        args.append(task)
        return args
    }
}

/// Runs one `dsh --profile headless "<task>"` turn and streams both of its
/// output channels back to the caller.
///
/// The headless profile is the harness's own one-shot surface: it answers a
/// single task, streams provider reasoning to stderr, prints the final
/// assistant message to stdout, and exits. That contract is what makes an
/// inline "ask and watch" panel possible without reimplementing any protocol.
final class HeadlessRunner {
    private var process: Process?
    private(set) var isRunning = false
    private var startedAt: Date?

    var onStdErr: ((String) -> Void)?
    var onStdOut: ((String) -> Void)?
    var onFinish: ((Int32, Double) -> Void)?

    /// 回调投递方式。面板要走主线程（UI），命令行工具直接在当前线程回更省事、
    /// 也不用依赖主 runloop 会不会 drain 主队列。
    var deliverOnMainThread = true

    private func deliver(_ work: @escaping () -> Void) {
        if deliverOnMainThread {
            DispatchQueue.main.async(execute: work)
        } else {
            work()
        }
    }

    /// Launches one turn. `workspace` becomes the child's working directory —
    /// it is the equivalent of the session workspace a GUI session would use.
    /// `patch`, when present, carries the per-run model / effort override.
    func start(task: String, workspace: String, node: String, dshEntry: String, patch: URL?) {
        guard !isRunning else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = HeadlessInvocation.arguments(entry: dshEntry, task: task, patch: patch)
        p.currentDirectoryURL = URL(fileURLWithPath: workspace)

        var environment = ProcessInfo.processInfo.environment
        let nodeDirectory = (node as NSString).deletingLastPathComponent
        environment["PATH"] = [
            nodeDirectory,
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
        if environment["HOME"] == nil || environment["HOME"]!.isEmpty {
            environment["HOME"] = NSHomeDirectory()
        }
        p.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            self?.deliver { self?.onStdOut?(text) }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            self?.deliver { self?.onStdErr?(text) }
        }

        p.terminationHandler = { [weak self] finished in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let elapsed = self?.startedAt.map { Date().timeIntervalSince($0) } ?? 0
            self?.deliver {
                self?.isRunning = false
                self?.process = nil
                self?.onFinish?(finished.terminationStatus, elapsed)
            }
        }

        do {
            try p.run()
        } catch {
            Log.write("headless launch failed: \(error.localizedDescription)")
            deliver { [weak self] in
                self?.onStdErr?("无法启动 dsh：\(error.localizedDescription)\n")
                self?.onFinish?(127, 0)
            }
            return
        }

        process = p
        isRunning = true
        startedAt = Date()
        Log.write("headless started: \(task.prefix(120))")
    }

    /// Sends SIGTERM; `dsh` treats it as an interrupt and exits cleanly.
    func cancel() {
        guard let process, isRunning else { return }
        Log.write("headless cancelled by user")
        process.terminate()
    }
}

/// Opens a visible Terminal window that runs the same one-shot turn.
///
/// A `.command` file is used instead of `osascript ... tell Terminal` so the app
/// never needs Automation (Apple Events) permission: launching a document with
/// Terminal.app is an ordinary `open`, not scripted control of another app.
enum TerminalLauncher {
    /// The exact shell script a Terminal window will run. Exposed separately so
    /// `--print-terminal-script` can show it without opening anything.
    static func scriptText(task: String, config: QuickAskConfig, patch: URL? = nil) -> String {
        // 只给路径和任务文本加引号，旗标保持原样，读起来才像一条真人会敲的命令。
        var parts = [shellQuote(config.nodePath), shellQuote(config.dshEntry), "--profile", "headless"]
        if let patch { parts += ["--patch", shellQuote(patch.path)] }
        parts.append(shellQuote(task))
        let argv = parts.joined(separator: " ")
        let model = config.selection.isEmpty
            ? "harness 默认"
            : "\(config.selection.model)（\(config.selection.effort ?? "默认档")）"

        return """
        #!/bin/bash
        cd \(shellQuote(config.workspace)) || exit 1
        clear
        printf '\\033[1mDSH Quick Ask\\033[0m\\n'
        printf '\\033[2m%s\\033[0m\\n' \(shellQuote(task))
        printf '\\033[2m模型: %s\\033[0m\\n\\n' \(shellQuote(model))
        printf '\\033[2m--- 开始执行 ---\\033[0m\\n\\n'
        \(argv)
        code=$?
        printf '\\n\\033[2m--- 结束（退出码 %d）· 按回车关闭窗口 ---\\033[0m\\n' "$code"
        read -r _
        """
    }

    static func launch(task: String, config: QuickAskConfig) {
        guard !config.nodePath.isEmpty, !config.dshEntry.isEmpty else {
            Log.write("terminal launch skipped: node/dsh paths are unresolved")
            return
        }

        let fm = FileManager.default
        let runs = Paths.runsDirectory
        try? fm.createDirectory(at: runs, withIntermediateDirectories: true)
        Paths.cleanKeyedRuns()

        let stamp = Int(Date().timeIntervalSince1970)
        let url = runs.appendingPathComponent("quickask-\(stamp).command")
        let patch = SettingsOverride.makePatch(selection: config.selection)

        do {
            try scriptText(task: task, config: config, patch: patch).write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            Log.write("cannot write run script: \(error.localizedDescription)")
            return
        }

        Log.write("terminal launch: \(url.path)")
        NSWorkspace.shared.open(url)
    }

    /// Keeps the runs directory from growing forever.
}
