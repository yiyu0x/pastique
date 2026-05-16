import AppKit
import Carbon.HIToolbox

// Small modal window that asks the user to press a key combination,
// then tries to register it. Used by AppDelegate when the user picks
// "Change Hotkey..." from the menubar / gear menu.

@MainActor
enum HotKeyFormatter {
    static func string(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += Self.keyLabel(for: keyCode)
        return s
    }

    private static func keyLabel(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Return:        return "↩"
        case kVK_Tab:            return "⇥"
        case kVK_Space:          return "Space"
        case kVK_Delete:         return "⌫"
        case kVK_Escape:         return "⎋"
        case kVK_LeftArrow:      return "←"
        case kVK_RightArrow:     return "→"
        case kVK_UpArrow:        return "↑"
        case kVK_DownArrow:      return "↓"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2"
        case kVK_F3:  return "F3";  case kVK_F4:  return "F4"
        case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8"
        case kVK_F9:  return "F9";  case kVK_F10: return "F10"
        case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default:
            // Map keyCode → character via the current keyboard layout.
            if let s = Self.character(for: keyCode) { return s.uppercased() }
            return "?"
        }
    }

    private static func character(for keyCode: UInt32) -> String? {
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layout = unsafeBitCast(layoutData, to: CFData.self)
        let bytes = CFDataGetBytePtr(layout)
        let keyLayout = UnsafeRawPointer(bytes!).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            keyLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

@MainActor
final class HotKeyRecorderController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onCommit: (UInt32, UInt32) -> Bool   // returns false → keep open & show error
    private var captureView: HotKeyCaptureView?

    init(onCommit: @escaping (UInt32, UInt32) -> Bool) {
        self.onCommit = onCommit
    }

    func show() {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Change Hotkey"
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        w.level = .floating

        let container = NSView(frame: w.contentView!.bounds)
        container.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "Press a key combination.")
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let capture = HotKeyCaptureView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        capture.translatesAutoresizingMaskIntoConstraints = false
        capture.currentDisplay = HotKeyFormatter.string(
            keyCode: Settings.hotKeyCode,
            modifiers: Settings.hotKeyModifiers
        )
        capture.onCapture = { [weak self] code, mods in
            self?.attempt(code: code, modifiers: mods)
        }
        container.addSubview(capture)

        let hint = NSTextField(labelWithString: "Modifier required (⌘/⌃/⌥). Esc to cancel.")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hint)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            capture.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 14),
            capture.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            capture.widthAnchor.constraint(equalToConstant: 240),
            capture.heightAnchor.constraint(equalToConstant: 36),

            hint.topAnchor.constraint(equalTo: capture.bottomAnchor, constant: 14),
            hint.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])

        w.contentView = container
        captureView = capture

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(capture)
        window = w
    }

    private func attempt(code: UInt32, modifiers: UInt32) {
        if onCommit(code, modifiers) {
            window?.close()
        } else {
            captureView?.flashError("Hotkey unavailable — try another.")
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        captureView = nil
    }
}

final class HotKeyCaptureView: NSView {
    var onCapture: ((UInt32, UInt32) -> Void)?
    var currentDisplay: String = "" {
        didSet { needsDisplay = true }
    }
    private var errorText: String? {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    func flashError(_ msg: String) {
        errorText = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.errorText = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        // Esc: just close without changes.
        if event.keyCode == 53 {
            window?.close()
            return
        }
        let mods = Self.carbonModifiers(from: event.modifierFlags)
        guard mods != 0 else {
            flashError("Add a modifier (⌘/⌃/⌥).")
            return
        }
        onCapture?(UInt32(event.keyCode), mods)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command)   { m |= UInt32(cmdKey) }
        if flags.contains(.shift)     { m |= UInt32(shiftKey) }
        if flags.contains(.option)    { m |= UInt32(optionKey) }
        if flags.contains(.control)   { m |= UInt32(controlKey) }
        return m
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 6
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        let focused = (window?.firstResponder === self)
        (focused ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = focused ? 2 : 1
        path.stroke()

        let text = errorText ?? currentDisplay
        let color: NSColor = errorText != nil ? .systemRed : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                             y: (bounds.height - size.height) / 2))
    }
}
