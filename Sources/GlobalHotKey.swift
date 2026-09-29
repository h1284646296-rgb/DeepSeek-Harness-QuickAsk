import AppKit
import Carbon.HIToolbox

/// The process-wide Carbon callback target. `RegisterEventHotKey` handlers are
/// plain C function pointers, so the Swift closure they must reach lives in a
/// file-scope variable rather than being captured.
private var activeHotKeyHandler: (() -> Void)?

private func quickAskHotKeyCallback(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    activeHotKeyHandler?()
    return noErr
}

/// A system-wide hotkey registered through Carbon.
///
/// Carbon is deliberate: unlike `NSEvent.addGlobalMonitorForEvents` it needs no
/// Accessibility permission, and unlike a `CGEventTap` it needs no privileged
/// helper. It works for an ad-hoc signed, non-sandboxed app the moment it
/// launches.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void
    private let spec: HotKeySpec

    /// Registers `spec`. Returns `nil` when the combination is already owned by
    /// another process — macOS reports `eventHotKeyExistsErr` for that case.
    init?(spec: HotKeySpec, handler: @escaping () -> Void) {
        self.spec = spec
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        activeHotKeyHandler = { handler() }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            quickAskHotKeyCallback,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        guard installStatus == noErr else {
            Log.write("InstallEventHandler failed: \(installStatus)")
            activeHotKeyHandler = nil
            return nil
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4451_4B41), id: 1) // 'DQKA'
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            spec.keyCode,
            spec.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard registerStatus == noErr, let ref else {
            Log.write("RegisterEventHotKey(\(spec.display)) failed: \(registerStatus)")
            if let handlerRef { RemoveEventHandler(handlerRef) }
            self.handlerRef = nil
            activeHotKeyHandler = nil
            return nil
        }

        self.hotKeyRef = ref
        Log.write("registered hotkey \(spec.display) (keyCode \(spec.keyCode), mods \(spec.carbonModifiers))")
    }

    /// Removes both the hotkey and its handler. Safe to call more than once.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        if activeHotKeyHandler != nil {
            activeHotKeyHandler = nil
        }
    }

    deinit {
        // `deinit` cannot call the mutating teardown above safely on all paths,
        // but the Carbon calls themselves are fine here.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
