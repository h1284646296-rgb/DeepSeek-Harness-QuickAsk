import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = QuickAskConfig.load()
    private var hotKey: GlobalHotKey?
    private var doubleShift: DoubleShiftMonitor?
    private var carbonDoubleShift: CarbonDoubleShift?
    private var panel: QuickAskWindowController?
    private var statusItem: NSStatusItem?
    private var triggerWarning: String?
    private var permissionTimer: Timer?

    var showPanelOnLaunch = false
    var demoOnLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildEditMenu()
        panel = QuickAskWindowController(config: config)
        armTriggers()
        installStatusItem()
        let hotkeyNote = config.hotkeyEnabled ? config.hotkey.display : "无(已关闭)"
        Log.write("launched; trigger=\(config.trigger.rawValue) hotkey=\(hotkeyNote) workspace=\(config.workspace)")

        if demoOnLaunch {
            panel?.presentDemo()
        } else if showPanelOnLaunch {
            panel?.present()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
        doubleShift?.disarm()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        Log.write("terminated")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Triggers

    /// 按配置装配触发器。
    ///
    /// 「连按两下 Shift」靠 CGEventTap，需要辅助功能 / 输入监视授权；拿不到授权时
    /// 这里会自动退回组合键，并把这个事实写进日志和菜单，而不是让 App 变成哑巴。
    private func armTriggers() {
        hotKey?.unregister()
        hotKey = nil
        doubleShift?.disarm()
        doubleShift = nil
        carbonDoubleShift?.disarm()
        carbonDoubleShift = nil
        triggerWarning = nil

        if config.trigger == .doubleShiftCarbon {
            // 免授权路线：把 Shift 本身注册成 Carbon 热键。
            let carbon = CarbonDoubleShift(window: config.doubleShiftWindow) { [weak self] in
                self?.panel?.toggle()
            }
            if carbon.arm() {
                carbonDoubleShift = carbon
            } else {
                triggerWarning = "无法把 Shift 注册成 Carbon 热键（可能被别的应用占用）"
            }
        } else if config.trigger.wantsDoubleShift {
            let monitor = DoubleShiftMonitor(window: config.doubleShiftWindow) { [weak self] in
                self?.panel?.toggle()
            }
            monitor.debugLogging = config.debugShiftEvents
            if monitor.arm(), monitor.canReceiveKeys {
                doubleShift = monitor
            } else {
                // 两种失败：tap 建不起来（没授权），或者建起来了但收不到事件
                // （macOS 允许建 tap 却一个都不投递）。两种都要引导授权。
                doubleShift = monitor.isArmed ? monitor : nil
                triggerWarning = "双击 Shift 收不到按键：请在「系统设置 → 隐私与安全性」里给 DSH Quick Ask 打开「辅助功能」或「输入监视」"
                requestListenAccessOnce()
                startPermissionWatch()
            }
        }

        // 只要双击 Shift 不能真正收键，就把组合键挂上兜底 —— 否则用户会一个触发器都没有。
        let doubleShiftUsable = (doubleShift?.canReceiveKeys ?? false) || (carbonDoubleShift?.isArmed ?? false)
        // 组合键只在配置允许时兜底；配置里写 "hotkey": "" 就是彻底不用组合键。
        let needsHotKey = config.hotkeyEnabled
            && (config.trigger.wantsHotKey || (config.trigger.wantsDoubleShift && !doubleShiftUsable))
        if needsHotKey {
            if let registered = GlobalHotKey(spec: config.hotkey, handler: { [weak self] in
                self?.panel?.toggle()
            }) {
                hotKey = registered
            } else {
                let message = "快捷键 \(config.hotkey.display) 注册失败（可能已被其它应用占用）"
                triggerWarning = triggerWarning.map { $0 + "；" + message } ?? message
                Log.write("hotkey registration failed for \(config.hotkey.display)")
            }
        }

        if let triggerWarning { Log.write(triggerWarning) }
    }

    /// 只自动申请一次；之后由菜单里的「授予「输入监视」权限…」触发。
    private func requestListenAccessOnce() {
        let key = "quickask.askedListenAccess"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Log.write("向系统申请「输入监视」授权")
        AccessibilityGate.requestListenAccess()
    }

    /// 授权是异步的：用户去系统设置勾选后，这里能自己发现并重新装配，
    /// 不必手动重启（macOS 有时确实需要重启，那时菜单里也有重启项）。
    private func startPermissionWatch() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            guard let self else { return }
            guard AccessibilityGate.hasListenAccess || AccessibilityGate.isTrusted else { return }
            timer.invalidate()
            self.permissionTimer = nil
            Log.write("检测到「输入监视」授权已生效，重新装配触发器")
            self.armTriggers()
            self.installStatusItem()
            QuickAlert.show(title: "权限已生效", body: "现在连按两下 Shift 就能唤出输入框了。")
        }
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "DSH Quick Ask")
            button.image?.isTemplate = true
            button.toolTip = "DSH Quick Ask — \(triggerSummary())"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "打开输入框（\(triggerSummary())）", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(withTitle: "当前模型：\(config.selection.model.isEmpty ? "未选" : config.selection.model)"
                       + (config.selection.effort.map { " · 推理 \($0)" } ?? ""),
                     action: nil, keyEquivalent: "")
        menu.items.last?.isEnabled = false

        if carbonDoubleShift?.isArmed == true {
            menu.addItem(.separator())
            menu.addItem(withTitle: "切回标准模式（CGEventTap）", action: #selector(useStandardMode), keyEquivalent: "")
        }
        if config.trigger.wantsDoubleShift, doubleShift?.canReceiveKeys != true, carbonDoubleShift?.isArmed != true {
            menu.addItem(.separator())
            let warning = NSMenuItem(title: triggerWarning ?? "双击 Shift 未生效", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(withTitle: "授予「输入监视」权限…", action: #selector(grantInputMonitoring), keyEquivalent: "")
            menu.addItem(withTitle: "打开「输入监视」设置…", action: #selector(openInputMonitoring), keyEquivalent: "")
            menu.addItem(withTitle: "授予「辅助功能」权限…", action: #selector(grantAccessibility), keyEquivalent: "")
            menu.addItem(withTitle: "改用免授权的 Carbon 模式", action: #selector(useCarbonMode), keyEquivalent: "")
            menu.addItem(withTitle: "重新检测权限", action: #selector(recheckPermissions), keyEquivalent: "")
            menu.addItem(withTitle: "重启 DSH Quick Ask", action: #selector(restartApp), keyEquivalent: "")
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "刷新模型列表", action: #selector(refreshCatalog), keyEquivalent: "")
        menu.addItem(withTitle: "重新载入配置", action: #selector(reloadConfig), keyEquivalent: "")
        menu.addItem(withTitle: "打开配置文件", action: #selector(openConfigFile), keyEquivalent: "")
        menu.addItem(withTitle: "打开日志", action: #selector(openLogFile), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 DSH Quick Ask",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        for entry in menu.items where entry.action != nil && entry.action != #selector(NSApplication.terminate(_:)) {
            entry.target = self
        }
        item.menu = menu
        statusItem = item
    }

    private func triggerSummary() -> String {
        var parts: [String] = []
        if carbonDoubleShift?.isArmed == true {
            parts.append("连按两下 Shift(Carbon)")
        } else if doubleShift?.canReceiveKeys == true {
            parts.append("连按两下 Shift")
        } else if config.trigger.wantsDoubleShift {
            parts.append("连按两下 Shift(待授权)")
        }
        if hotKey != nil { parts.append(config.hotkey.display) }
        return parts.isEmpty ? "未启用" : parts.joined(separator: " / ")
    }

    @objc private func openPanel() {
        panel?.present()
    }

    @objc private func grantAccessibility() {
        AccessibilityGate.request()
    }

    @objc private func grantInputMonitoring() {
        AccessibilityGate.requestListenAccess()
    }

    /// 一键切到免授权路线：把 Shift 本身注册成 Carbon 热键。
    @objc private func useCarbonMode() {
        QuickAskConfig.persist(["trigger": TriggerMode.doubleShiftCarbon.rawValue])
        config = QuickAskConfig.load()
        armTriggers()
        installStatusItem()
        QuickAlert.show(
            title: "已切到免授权模式",
            body: "现在连按两下 Shift 不需要任何系统权限。\n\n"
                + "请试打几个大写字母：如果 Shift 打不出大写，说明 Carbon 热键把 Shift 吃掉了，"
                + "点菜单栏 ✨ →「切回标准模式」即可还原。"
        )
    }

    @objc private func useStandardMode() {
        QuickAskConfig.persist(["trigger": TriggerMode.doubleShift.rawValue])
        config = QuickAskConfig.load()
        armTriggers()
        installStatusItem()
    }

    @objc private func recheckPermissions() {
        Log.write("手动重新检测权限：输入监视=\(AccessibilityGate.hasListenAccess) 辅助功能=\(AccessibilityGate.isTrusted)")
        if AccessibilityGate.hasListenAccess || AccessibilityGate.isTrusted {
            armTriggers()
            installStatusItem()
            QuickAlert.show(title: "权限已检测到", body: "已重新装配触发器：\(triggerSummary())")
        } else {
            QuickAlert.show(
                title: "还没检测到权限",
                body: "请在「系统设置 → 隐私与安全性 → 输入监视」里勾选 DSH Quick Ask，"
                    + "然后点「重启 DSH Quick Ask」让它重新读取权限。"
            )
        }
    }

    @objc private func restartApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "gui/\(getuid())/local.dsh.quickask"]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            Log.write("重启失败：\(error.localizedDescription)")
        }
        if task.terminationStatus != 0 {
            Log.write("launchctl kickstart 返回 \(task.terminationStatus)，改为自行重启")
            let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunch.arguments = ["-n", Bundle.main.bundlePath]
            try? relaunch.run()
            _ = path
        }
        NSApp.terminate(nil)
    }

    @objc private func openInputMonitoring() {
        AccessibilityGate.openInputMonitoringPane()
    }

    @objc private func refreshCatalog() {
        let count = Diagnostics.refreshCatalog(config: config)
        config = QuickAskConfig.load()
        panel?.update(config: config)
        if count > 0 {
            QuickAlert.show(title: "模型列表已刷新", body: "共 \(count) 个可选模型")
        }
        installStatusItem()
    }

    @objc private func reloadConfig() {
        config = QuickAskConfig.load()
        panel?.update(config: config)
        armTriggers()
        installStatusItem()
        Log.write("config reloaded")
    }

    @objc private func openConfigFile() {
        if !FileManager.default.fileExists(atPath: Paths.config.path) {
            QuickAskConfig.writeDefaultIfMissing(
                workspace: config.workspace,
                node: config.nodePath,
                dsh: config.dshEntry,
                catalog: config.catalog
            )
        }
        NSWorkspace.shared.open(Paths.config)
    }

    @objc private func openLogFile() {
        NSWorkspace.shared.open(Paths.log)
    }

    // MARK: - Edit menu
    //
    // Without a main menu, ⌘C/⌘V/⌘A never reach the panel's text field: AppKit
    // dispatches those key equivalents through the menu bar, not the responder
    // chain. This menu exists purely so the input box accepts paste.
    private func buildEditMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隐藏", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DSH Quick Ask",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}

/// 一个简单的模态提示。`NSUserNotification` 已废弃，`UNUserNotificationCenter`
/// 又要授权；刷新完模型列表给个确认，用 NSAlert 最省事。
private enum QuickAlert {
    static func show(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
