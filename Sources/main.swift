import AppKit

// Top-level entry point. Everything that can be answered from a terminal is
// handled here, before AppKit is started, so `--ask` works over SSH and from
// scripts; anything else becomes the global-hotkey agent.

let arguments = Array(CommandLine.arguments.dropFirst())

let usage = """
DSH Quick Ask — 连按两下 Shift，弹出输入框，交给 DeepSeek Harness 执行

用法:
  DSHQuickAsk                    启动常驻代理（双击 Shift / 组合键 + 悬浮输入框）
  DSHQuickAsk --show-panel       启动并把输入框直接显示出来（调试用）
  DSHQuickAsk --demo             启动并填入示例结果，用于检查排版（不发请求）
  DSHQuickAsk --diagnose         打印配置、路径、模型目录后退出
  DSHQuickAsk --catalog          重新提取模型目录并打印 JSON
  DSHQuickAsk --selftest-trigger 自检「连按两下 Shift」的判定逻辑（不碰真实按键）
  DSHQuickAsk --watch-shift [秒] 实时打印 Shift 按键事件，用来判断权限有没有生效
  DSHQuickAsk --ask <任务...>     不弹窗，直接执行一次 headless 任务并打印结果
  DSHQuickAsk --ask-inline <任务> 走「面板按回车」那条完全相同的代码路径执行一次
  DSHQuickAsk --print-argv <任务> 打印面板会执行的完整 argv（不真的运行）
  DSHQuickAsk --selftest [任务]   跑一次端到端自检（默认任务「只回复两个字：成功」）
  DSHQuickAsk --print-terminal-script <任务>
                                 打印「终端模式」会执行的脚本，不真的运行
  DSHQuickAsk --help             显示本帮助
  DSHQuickAsk --version          显示版本
"""

if arguments.contains("-h") || arguments.contains("--help") {
    print(usage)
    exit(0)
}

if arguments.contains("--version") {
    print("dsh-quickask 2.0.0")
    exit(0)
}

if arguments.contains("--diagnose") {
    print(Diagnostics.report(config: QuickAskConfig.load()))
    exit(0)
}

if arguments.contains("--catalog") {
    guard let catalog = Diagnostics.extractCatalog(config: QuickAskConfig.load()),
          let data = try? JSONSerialization.data(
              withJSONObject: catalog,
              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
          ) else {
        FileHandle.standardError.write(Data("dsh-quickask: 模型目录提取失败\n".utf8))
        exit(1)
    }
    FileHandle.standardOutput.write(data)
    print("")
    exit(0)
}

if arguments.contains("--selftest-trigger") {
    exit(Diagnostics.triggerSelfTest())
}

if let index = arguments.firstIndex(of: "--watch-shift") {
    let raw = arguments.count > index + 1 ? arguments[index + 1] : ""
    let seconds = Double(raw) ?? 15
    exit(Diagnostics.watchShift(seconds: max(3, min(120, seconds))))
}

if let index = arguments.firstIndex(of: "--print-terminal-script") {
    let task = arguments[(index + 1)...].joined(separator: " ")
    let effective = task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "<任务文本>" : task
    print(TerminalLauncher.scriptText(task: effective, config: QuickAskConfig.load()))
    exit(0)
}

if let index = arguments.firstIndex(of: "--print-argv") {
    let task = arguments[(index + 1)...].joined(separator: " ")
    let config = QuickAskConfig.load()
    let patch = SettingsOverride.makePatch(selection: config.selection)
    let argv = [config.nodePath] + HeadlessInvocation.arguments(
        entry: config.dshEntry,
        task: task.isEmpty ? "<任务文本>" : task,
        patch: patch
    )
    print(argv.map { $0.contains(" ") ? "\($0)" : $0 }.joined(separator: "\n"))
    exit(0)
}

if let index = arguments.firstIndex(of: "--ask-inline") {
    let task = arguments[(index + 1)...].joined(separator: " ")
    guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        FileHandle.standardError.write(Data("dsh-quickask: --ask-inline 需要一个任务文本\n".utf8))
        exit(2)
    }
    exit(Diagnostics.runInline(task: task, config: QuickAskConfig.load()))
}

if let index = arguments.firstIndex(of: "--ask") {
    let task = arguments[(index + 1)...].joined(separator: " ")
    guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        FileHandle.standardError.write(Data("dsh-quickask: --ask 需要一个任务文本\n".utf8))
        exit(2)
    }
    exit(Diagnostics.runForeground(task: task, config: QuickAskConfig.load()))
}

if let index = arguments.firstIndex(of: "--selftest") {
    let supplied = arguments[(index + 1)...].joined(separator: " ")
    let task = supplied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "只回复两个字：成功"
        : supplied
    FileHandle.standardError.write(Data("dsh-quickask: selftest task = \(task)\n".utf8))
    exit(Diagnostics.runForeground(task: task, config: QuickAskConfig.load()))
}

// GUI agent.
var loaded = QuickAskConfig.load()
QuickAskConfig.writeDefaultIfMissing(
    workspace: loaded.workspace,
    node: loaded.nodePath,
    dsh: loaded.dshEntry,
    catalog: loaded.catalog
)

// 首次运行（或还没提取过）时顺手把模型目录补上，这样面板一打开就有选择器。
if let raw = try? Data(contentsOf: Paths.config),
   let parsed = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
   parsed["catalog"] == nil,
   !loaded.nodePath.isEmpty {
    if Diagnostics.refreshCatalog(config: loaded) > 0 {
        loaded = QuickAskConfig.load()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
delegate.showPanelOnLaunch = arguments.contains("--show-panel")
delegate.demoOnLaunch = arguments.contains("--demo")
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
