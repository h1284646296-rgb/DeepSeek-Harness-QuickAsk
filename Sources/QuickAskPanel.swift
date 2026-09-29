import AppKit

/// A borderless panel that can still take keyboard focus.
final class QuickAskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A text field that reports Escape instead of beeping.
final class QuickAskField: NSTextField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Root view with a top-left origin, so frame arithmetic reads top-down.
final class QuickAskRootView: NSView {
    override var isFlipped: Bool { true }
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// The floating "ask DeepSeek Harness" bar: one input line, a model picker, a
/// reasoning-effort picker, and an answer card that expands underneath.
final class QuickAskWindowController: NSObject, NSTextFieldDelegate {
    private enum Style {
        static let width: CGFloat = 720
        static let collapsedHeight: CGFloat = 88
        static let expandedHeight: CGFloat = 470
        static let padding: CGFloat = 18
        static let textLeft: CGFloat = 54
        static let corner: CGFloat = 20
        static let modelWidth: CGFloat = 250
        static let effortWidth: CGFloat = 122
    }

    private let panel: QuickAskPanel
    private let effect = NSVisualEffectView()
    private let scrim = NSView()
    private let rainbow = RainbowBorderView()
    private let field = QuickAskField()
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let modelPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effortPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scroll = NSScrollView()
    private let output = NSTextView()

    private let runner = HeadlessRunner()
    private var config: QuickAskConfig
    private var expanded = false
    private var busy = false
    private var wroteAnything = false
    private var keyMonitor: Any?
    /// Set while rebuilding the popups, so programmatic selection changes are
    /// not written back to disk as if the user had picked them.
    private var rebuildingMenus = false

    init(config: QuickAskConfig) {
        self.config = config
        self.panel = QuickAskPanel(
            contentRect: NSRect(x: 0, y: 0, width: Style.width, height: Style.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        configureSubviews()
        installKeyMonitor()
        rebuildModelMenu()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// Applies a freshly loaded configuration without restarting the app.
    func update(config: QuickAskConfig) {
        self.config = config
        rebuildModelMenu()
    }

    var hotkeyDisplay: String { config.hotkey.display }

    // MARK: - Visibility

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            present()
        }
    }

    func present() {
        reset()
        expanded = false
        position(animated: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)

        // 开场：一声 duang + 跑马灯转起来。
        SoundPlayer.play(config.sound)
        if config.rainbow {
            rainbow.isHidden = false
            rainbow.start()
        } else {
            rainbow.stop()
            rainbow.isHidden = true
        }
    }

    func hide() {
        if busy { runner.cancel() }
        rainbow.stop()
        panel.orderOut(nil)
    }

    /// Fills the panel with representative output so the expanded layout can be
    /// checked without spending a model call. Used by `--demo`.
    func presentDemo() {
        present()
        field.stringValue = "把桌面上的截图按日期归档"
        expanded = true
        position(animated: false)
        append("dsh: reasoning:\n", style: .reasoning)
        append("先看清楚桌面上有哪些截图，再按拍摄日期分组建文件夹……\n", style: .reasoning)
        append("Bash  ls -lt ~/Desktop/*.png\n", style: .reasoning)
        append("", style: .reasoning)
        append("已经整理好了：12 张截图按日期归入 4 个文件夹（03-11、03-18、04-02、04-15），"
               + "原文件已移动而非复制，因此桌面现在只剩下 4 个目录。\n", style: .answer)
        status.stringValue = "完成 · 用时 8.4s · 工作区 ~/Desktop/harness"
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        icon.isHidden = false
    }

    // MARK: - Setup

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        // 固定深色：彩虹环、白字和半透明底衬在任何系统外观下都保持一致。
        panel.appearance = NSAppearance(named: .darkAqua)

        let view = QuickAskRootView()
        view.onLayout = { [weak self] in self?.layoutContents() }
        panel.contentView = view
    }

    private func configureSubviews() {
        guard let container = panel.contentView else { return }

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Style.corner
        effect.layer?.masksToBounds = true
        container.addSubview(effect)

        // 彩虹跑马灯铺满整块面板；它可见的部分，就是内层没压住的那一圈。
        rainbow.cornerRadius = Style.corner
        container.addSubview(rainbow)

        // Vibrancy alone is hard to read over a bright or busy background: the
        // scrim keeps the input line legible while the material underneath
        // still frosts whatever is behind the panel. It is inset by the border
        // width so the gradient underneath shows through as a ring.
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.94).cgColor
        scrim.layer?.borderWidth = 1
        scrim.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        container.addSubview(scrim)

        icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "DeepSeek Harness")
        icon.contentTintColor = .controlAccentColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(icon)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        container.addSubview(spinner)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.textColor = .white
        field.placeholderString = "问点什么，回车交给 DeepSeek Harness"
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.onCancel = { [weak self] in self?.hide() }
        container.addSubview(field)

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        container.addSubview(status)

        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .tertiaryLabelColor
        hint.stringValue = "↩ 执行   ⌥↩ 终端   esc 关闭"
        container.addSubview(hint)

        for (popUp, action) in [(modelPopUp, #selector(modelChanged)), (effortPopUp, #selector(effortChanged))] {
            popUp.isBordered = true
            popUp.bezelStyle = .inline
            popUp.controlSize = .small
            popUp.font = .systemFont(ofSize: 11)
            popUp.target = self
            popUp.action = action
            container.addSubview(popUp)
        }
        modelPopUp.toolTip = "本次执行使用的模型"
        effortPopUp.toolTip = "本次执行的推理深度"

        output.isEditable = false
        output.isSelectable = true
        output.drawsBackground = false
        output.font = .systemFont(ofSize: 13)
        output.textColor = .white
        output.textContainerInset = NSSize(width: 6, height: 8)
        output.isVerticallyResizable = true
        output.isHorizontallyResizable = false
        output.autoresizingMask = [.width]
        output.minSize = NSSize(width: 0, height: 0)
        output.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        output.textContainer?.widthTracksTextView = true
        output.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scroll.documentView = output
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        container.addSubview(scroll)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, event.keyCode == 53 else { return event }
            self.hide()
            return nil
        }
    }

    // MARK: - Layout

    private func layoutContents() {
        guard let container = panel.contentView else { return }
        let width = container.bounds.width
        let height = container.bounds.height

        effect.frame = container.bounds
        rainbow.frame = container.bounds
        // 彩虹开着时内层缩进 3pt 让出边框；关掉时铺满并自己收圆角。
        let border: CGFloat = config.rainbow ? 4 : 0
        scrim.frame = container.bounds.insetBy(dx: border, dy: border)
        scrim.layer?.cornerRadius = Style.corner - border
        icon.frame = NSRect(x: Style.padding + 2, y: 24, width: 22, height: 22)
        spinner.frame = NSRect(x: Style.padding + 4, y: 27, width: 16, height: 16)

        let fieldWidth = width - Style.textLeft - Style.padding
        field.frame = NSRect(x: Style.textLeft, y: 16, width: fieldWidth, height: 36)

        let chipY = Style.collapsedHeight - 30
        let effortX = width - Style.padding - Style.effortWidth
        let modelX = effortX - 8 - Style.modelWidth
        modelPopUp.frame = NSRect(x: modelX, y: chipY, width: Style.modelWidth, height: 22)
        effortPopUp.frame = NSRect(x: effortX, y: chipY, width: Style.effortWidth, height: 22)
        modelPopUp.isHidden = config.catalog.isEmpty
        effortPopUp.isHidden = config.catalog.isEmpty
        hint.frame = NSRect(x: Style.textLeft, y: chipY + 2, width: max(60, modelX - Style.textLeft - 10), height: 16)

        if expanded {
            status.isHidden = false
            scroll.isHidden = false
            status.frame = NSRect(x: Style.textLeft, y: Style.collapsedHeight + 2, width: fieldWidth, height: 16)
            let top = Style.collapsedHeight + 24
            scroll.frame = NSRect(
                x: Style.padding,
                y: top,
                width: width - Style.padding * 2,
                height: max(40, height - top - Style.padding)
            )
        } else {
            status.isHidden = true
            scroll.isHidden = true
            status.frame = .zero
            scroll.frame = .zero
        }
    }

    /// Sizes the panel for the current state and pins its top edge so it grows
    /// downward instead of jumping.
    private func position(animated: Bool) {
        let screen = screenUnderPointer()
        let visible = screen.visibleFrame
        let height = expanded ? Style.expandedHeight : Style.collapsedHeight
        let top = visible.maxY - max(70, visible.height * 0.20)
        let frame = NSRect(
            x: visible.midX - Style.width / 2,
            y: top - height,
            width: Style.width,
            height: height
        )
        panel.setFrame(frame, display: true, animate: animated)
        panel.contentView?.needsLayout = true
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func screenUnderPointer() -> NSScreen {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: - Model / effort pickers

    private static func effortLabel(_ raw: String) -> String {
        switch raw {
        case "off": return "关闭"
        case "minimal": return "最小"
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh": return "极高"
        case "max": return "最大"
        default: return raw
        }
    }

    private var selectedModel: CatalogModel? {
        config.catalog.first { $0.key == config.selection.key } ?? config.catalog.first
    }

    private func rebuildModelMenu() {
        rebuildingMenus = true
        defer { rebuildingMenus = false }

        modelPopUp.removeAllItems()
        for entry in config.catalog {
            modelPopUp.addItem(withTitle: entry.name)
            modelPopUp.lastItem?.representedObject = entry.key
        }
        if let index = config.catalog.firstIndex(where: { $0.key == config.selection.key }) {
            modelPopUp.selectItem(at: index)
        } else if !config.catalog.isEmpty {
            modelPopUp.selectItem(at: 0)
        }
        modelPopUp.isHidden = config.catalog.isEmpty

        rebuildEffortMenu()
    }

    private func rebuildEffortMenu() {
        rebuildingMenus = true
        defer { rebuildingMenus = false }

        effortPopUp.removeAllItems()
        guard let model = selectedModel else {
            effortPopUp.isHidden = true
            return
        }
        let efforts = model.efforts ?? []
        if efforts.isEmpty {
            // 适配器没有声明阶梯：给一个「默认」占位，不发送该参数。
            effortPopUp.addItem(withTitle: "推理 默认")
            effortPopUp.isHidden = config.catalog.isEmpty
            return
        }
        for effort in efforts {
            effortPopUp.addItem(withTitle: "推理 " + Self.effortLabel(effort))
            effortPopUp.lastItem?.representedObject = effort
        }
        let wanted = config.selection.effort ?? ""
        if let index = efforts.firstIndex(of: wanted) {
            effortPopUp.selectItem(at: index)
        } else if let index = efforts.firstIndex(of: "low") {
            effortPopUp.selectItem(at: index)
            config.selection.effort = efforts[index]
        } else {
            effortPopUp.selectItem(at: 0)
            config.selection.effort = efforts[0]
        }
        effortPopUp.isHidden = config.catalog.isEmpty
    }

    @objc private func modelChanged() {
        guard !rebuildingMenus, selectedModel != nil else { return }
        let index = modelPopUp.indexOfSelectedItem
        guard index >= 0, index < config.catalog.count else { return }
        let picked = config.catalog[index]
        // 换模型时尽量沿用当前的推理档位；新模型不支持就退到 low，最后才用第一项。
        // 之前直接用 efforts.first，而列表第一项是「关闭」—— 换个模型就把推理关掉了。
        let efforts = picked.efforts ?? []
        let carried = config.selection.effort
        let chosen: String?
        if let carried, efforts.contains(carried) {
            chosen = carried
        } else if efforts.contains("low") {
            chosen = "low"
        } else {
            chosen = efforts.first
        }
        config.selection = ModelSelection(
            provider: picked.provider,
            model: picked.model,
            effort: chosen
        )
        rebuildEffortMenu()
        QuickAskConfig.persistSelection(config.selection)
        panel.makeFirstResponder(field)
    }

    @objc private func effortChanged() {
        guard !rebuildingMenus else { return }
        let effort = effortPopUp.selectedItem?.representedObject as? String
        config.selection.effort = effort
        QuickAskConfig.persistSelection(config.selection)
        panel.makeFirstResponder(field)
    }

    // MARK: - Run lifecycle

    private func reset() {
        field.stringValue = ""
        output.string = ""
        status.stringValue = ""
        wroteAnything = false
        busy = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        icon.isHidden = false
        rebuildModelMenu()
    }

    private func expand() {
        expanded = true
        position(animated: true)
    }

    /// Runs the prompt in the panel and streams the answer back into it.
    private func startInline(task: String) {
        guard !config.nodePath.isEmpty, !config.dshEntry.isEmpty else {
            expanded = true
            position(animated: true)
            append("无法执行：没有解析到 node 或 dsh 入口。请运行 `dsh-quickask --diagnose` 查看，或重新安装。\n", style: .failure)
            return
        }

        busy = true
        wroteAnything = false
        output.string = ""
        status.stringValue = "正在执行…（\(modelLabel())）"
        spinner.isHidden = false
        spinner.startAnimation(nil)
        icon.isHidden = true
        expand()

        // 每一次执行都用自己的临时 settings 文档来落模型与推理档位。
        let patch = SettingsOverride.makePatch(selection: config.selection)

        runner.onStdErr = { [weak self] text in self?.append(text, style: .reasoning) }
        runner.onStdOut = { [weak self] text in self?.append(text, style: .answer) }
        runner.onFinish = { [weak self] code, seconds in self?.finish(code: code, seconds: seconds) }

        runner.start(
            task: task,
            workspace: config.workspace,
            node: config.nodePath,
            dshEntry: config.dshEntry,
            patch: patch
        )
    }

    private func modelLabel() -> String {
        guard let model = selectedModel else { return "harness 默认模型" }
        let effort = config.selection.effort.map { " · 推理 \(Self.effortLabel($0))" } ?? ""
        return model.name + effort
    }

    private func finish(code: Int32, seconds: Double) {
        busy = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        icon.isHidden = false

        if code == 0 {
            status.stringValue = String(format: "完成 · 用时 %.1fs · %@", seconds, modelLabel())
        } else {
            status.stringValue = String(format: "退出码 %d · 用时 %.1fs · %@", code, seconds, modelLabel())
            append("\n[进程以退出码 \(code) 结束]\n", style: .failure)
        }
        if !wroteAnything {
            append("（没有输出）\n", style: .reasoning)
        }
    }

    private enum OutputStyle {
        case reasoning
        case answer
        case failure
    }

    private func append(_ text: String, style: OutputStyle) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any]
        switch style {
        case .reasoning:
            attributes = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        case .answer:
            attributes = [
                .font: NSFont.systemFont(ofSize: 13.5),
                .foregroundColor: NSColor.white,
            ]
        case .failure:
            attributes = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.systemRed,
            ]
        }
        output.textStorage?.append(NSAttributedString(string: text, attributes: attributes))
        output.scrollToEndOfDocument(nil)
        wroteAnything = true
    }

    // MARK: - Submission

    private func submit(forceTerminal: Bool) {
        let task = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            hide()
            return
        }
        guard !busy else { return }

        let mode: RunMode = forceTerminal ? .terminal : config.mode
        switch mode {
        case .terminal:
            TerminalLauncher.launch(task: task, config: config)
            hide()
        case .inline:
            startInline(task: task)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // 按住回车会自动重复，那会一秒里连开十几个 headless 进程。
            if NSApp.currentEvent?.isARepeat == true { return true }
            let optionHeld = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
            submit(forceTerminal: optionHeld)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        return false
    }
}
