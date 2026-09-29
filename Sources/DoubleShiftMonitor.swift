import AppKit
import ApplicationServices
import CoreGraphics

/// 引导用户完成「辅助功能 / 输入监视」授权。
///
/// 连按两下 Shift 属于时序手势，Carbon 的 `RegisterEventHotKey` 表达不了
/// （它只能绑定「一个键 + 一组修饰键」），所以只能用 CGEventTap 旁听键盘。
/// 代价就是这里。
enum AccessibilityGate {
    /// 进程当前是否已被信任（「辅助功能」）。
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 「输入监视」是否已授予。这才是 listen-only 事件 tap 真正需要的权限：
    /// 只有辅助功能、没有输入监视时，`CGEvent.tapCreate` 未必失败，但按键
    /// 可能根本不会送过来 —— 所以这个值要和「tap 建没建成」一起看。
    static var hasListenAccess: Bool { CGPreflightListenEventAccess() }

    /// 弹出「输入监视」授权请求（会把本 App 加进对应列表）。
    static func requestListenAccess() {
        _ = CGRequestListenEventAccess()
    }

    /// 弹出系统授权对话框（会把本 App 加进「辅助功能」列表）。
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」。
    static func openAccessibilityPane() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// 打开「系统设置 → 隐私与安全性 → 输入监视」。
    static func openInputMonitoringPane() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ text: String) {
        if let url = URL(string: text) { NSWorkspace.shared.open(url) }
    }
}

/// 「连按两下 Shift」的判定状态机。
///
/// 抽出来是为了能测：事件 tap 本身没法在自动化里模拟按键，但「两次按下算不算
/// 一次双击」这段时序逻辑可以，而且它恰恰是最容易写错的部分。
struct DoubleShiftDetector {
    /// 两次按下之间的最大间隔。
    var window: TimeInterval
    /// 触发后的静默期：连按三下、四下只算一次。
    var cooldown: TimeInterval = 0.5

    private var shiftHeld = false
    private var lastPress: TimeInterval = 0
    private var lastFired: TimeInterval = -.greatestFiniteMagnitude

    /// 左 Shift / 右 Shift 的虚拟键码。
    static let shiftKeyCodes: Set<Int64> = [56, 60]

    init(window: TimeInterval) {
        self.window = window
    }

    /// 喂一个事件，返回「这次是否应该唤出面板」。
    /// - Parameters:
    ///   - keyCode: 虚拟键码，非 Shift 会被忽略。
    ///   - shiftDown: 该事件之后 Shift 是否处于按下状态。
    ///   - now: 事件时间戳（秒，单调即可）。
    mutating func feed(keyCode: Int64, shiftDown: Bool, at now: TimeInterval) -> Bool {
        guard Self.shiftKeyCodes.contains(keyCode) else { return false }

        guard shiftDown else {
            shiftHeld = false
            return false
        }
        // 长按会产生重复的 flagsChanged，只认第一个按下沿。
        guard !shiftHeld else { return false }
        shiftHeld = true

        let gap = now - lastPress
        guard gap > 0, gap <= window else {
            lastPress = now
            return false
        }

        lastPress = 0
        guard now - lastFired > cooldown else { return false }
        lastFired = now
        return true
    }
}

/// 备选：把 Shift 键**本身**注册成 Carbon 热键，按两下算一次双击。
///
/// 好处是**完全不需要任何系统权限** —— Carbon 热键走 WindowServer 的热键表，
/// 和 ⌥Space 那条路一样免授权。
///
/// 坏处是 Carbon 热键可能把这个键「吃掉」，导致 Shift 打不出大写。这一点必须在
/// 真机上实测，所以它是显式选项（配置 `trigger: "double-shift-carbon"`），
/// 不是默认值；一旦发现大写失灵，改回 `double-shift` 并授予权限即可。
final class CarbonDoubleShift {
    private var hotKey: GlobalHotKey?
    private var detector: DoubleShiftDetector
    private let onTrigger: () -> Void

    private(set) var isArmed = false

    /// 左 Shift 的虚拟键码。
    static let shiftKeyCode: UInt32 = 56

    init(window: TimeInterval, onTrigger: @escaping () -> Void) {
        self.detector = DoubleShiftDetector(window: window)
        self.onTrigger = onTrigger
    }

    @discardableResult
    func arm() -> Bool {
        let spec = HotKeySpec(keyCode: Self.shiftKeyCode, carbonModifiers: 0, display: "\u{21E7}\u{21E7}")
        guard let registered = GlobalHotKey(spec: spec, handler: { [weak self] in
            guard let self else { return }
            // Carbon 只给「按下」，所以喂完按下立刻补一个松开，让状态机回到初始。
            let now = Date().timeIntervalSince1970
            let fired = self.detector.feed(keyCode: Int64(Self.shiftKeyCode), shiftDown: true, at: now)
            _ = self.detector.feed(keyCode: Int64(Self.shiftKeyCode), shiftDown: false, at: now + 0.001)
            guard fired else { return }
            Log.write("双击 Shift 命中（Carbon 模式）")
            DispatchQueue.main.async { self.onTrigger() }
        }) else {
            Log.write("无法把 Shift 注册成 Carbon 热键")
            return false
        }
        hotKey = registered
        isArmed = true
        return true
    }

    func disarm() {
        hotKey?.unregister()
        hotKey = nil
        isArmed = false
    }

    /// 试探：能不能把 Shift 注册成 Carbon 热键（注册后立刻撤销）。
    static func probe() -> Bool {
        let spec = HotKeySpec(keyCode: shiftKeyCode, carbonModifiers: 0, display: "\u{21E7}\u{21E7}")
        guard let probe = GlobalHotKey(spec: spec, handler: {}) else { return false }
        probe.unregister()
        return true
    }
}

/// 连按两下 Shift 触发。
///
/// 用 `.listenOnly` 的事件 tap：只旁听、不消费，所以 Shift 的正常功能
/// （大写、连选、输入法切换）完全不受影响。tap 被系统因超时/用户输入临时关掉时，
/// 回调里会收到 `tapDisabledByTimeout` / `tapDisabledByUserInput`，这里自动重开。
final class DoubleShiftMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector: DoubleShiftDetector
    private let onTrigger: () -> Void

    /// tap 是否建立成功。注意：**建立成功不等于能收到按键** —— 缺授权时
    /// macOS 会允许建 tap，但一个事件都不投递，所以还要看 `hasListenAccess`。
    private(set) var isArmed = false

    /// 能否指望真的收到按键。菜单与兜底逻辑都以此为准。
    ///
    /// 注意两个 TCC 服务都能让键盘监听生效：纯旁听走「输入监视」，
    /// 而「辅助功能」是上位权限，给了它同样能收键。所以两个都要认，
    /// 否则会出现「明明能用，App 却说自己没权限」。
    var canReceiveKeys: Bool {
        isArmed && (AccessibilityGate.hasListenAccess || AccessibilityGate.isTrusted)
    }

    /// 诊断用：每收到一个 flagsChanged 就回调一次。
    var onEvent: ((Int64, Bool) -> Void)?
    /// 诊断开关：把每个 Shift 按下沿写进日志（由配置 debugShiftEvents 控制）。
    var debugLogging = false

    init(window: TimeInterval, onTrigger: @escaping () -> Void = {}) {
        self.detector = DoubleShiftDetector(window: window)
        self.onTrigger = onTrigger
    }

    deinit { disarm() }

    @discardableResult
    func arm() -> Bool {
        disarm()

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let monitor = Unmanaged<DoubleShiftMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        monitor.reenable()
                    } else if type == .flagsChanged {
                        monitor.handle(event)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("双击 Shift 监听建立失败：没有辅助功能 / 输入监视授权")
            isArmed = false
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        isArmed = true
        Log.write("双击 Shift 监听已启用（窗口 \(Int(detector.window * 1000))ms，输入监视授权=\(AccessibilityGate.hasListenAccess)）")
        return true
    }

    func disarm() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        source = nil
        isArmed = false
    }

    fileprivate func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("事件 tap 被系统临时关闭，已重开")
    }

    /// 把事件喂给判定状态机，命中就唤出面板。
    fileprivate func handle(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let shiftDown = event.flags.contains(.maskShift)
        onEvent?(keyCode, shiftDown)
        if debugLogging, shiftDown, DoubleShiftDetector.shiftKeyCodes.contains(keyCode) {
            Log.write("收到 Shift 按下（keyCode \(keyCode)）")
        }
        let now = Date().timeIntervalSince1970
        guard detector.feed(keyCode: keyCode, shiftDown: shiftDown, at: now) else { return }
        Log.write("双击 Shift 命中")
        DispatchQueue.main.async { [onTrigger] in onTrigger() }
    }
}
