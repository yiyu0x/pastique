import AppKit
import Carbon.HIToolbox

// Thin Swift wrapper around Carbon's RegisterEventHotKey.
// Carbon hotkeys do NOT require Accessibility permission — that is why
// we use them instead of NSEvent.addGlobalMonitorForEvents.
//
// One instance can register one hotkey. Create more instances for more
// hotkeys (we only need one for ⌘⇧V).

final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var callback: (() -> Void)?
    private let id: UInt32

    private static var nextID: UInt32 = 1
    private static var instances: [UInt32: HotKeyManager] = [:]
    private static var globalHandlerInstalled = false
    private static let signature: OSType = 0x44495454  // 'DITT'

    init() {
        self.id = Self.nextID
        Self.nextID += 1
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        unregister()
        self.callback = action
        Self.instances[id] = self

        Self.installGlobalHandlerIfNeeded()

        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr { hotKeyRef = nil }
        return status == noErr
    }

    /// Re-register with a new key combo, keeping the existing callback.
    /// Returns false if the new combo is unavailable (in use by another app).
    @discardableResult
    func reregister(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard let cb = callback else { return false }
        return register(keyCode: keyCode, modifiers: modifiers, action: cb)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    }

    private static func installGlobalHandlerIfNeeded() {
        guard !globalHandlerInstalled else { return }
        globalHandlerInstalled = true

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        var ref: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ -> OSStatus in
                var hkID = EventHotKeyID()
                let getStatus = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if getStatus == noErr, let mgr = HotKeyManager.instances[hkID.id] {
                    DispatchQueue.main.async { mgr.callback?() }
                }
                return noErr
            },
            1,
            &eventSpec,
            nil,
            &ref
        )
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        Self.instances.removeValue(forKey: id)
    }
}
