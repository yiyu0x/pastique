import AppKit
import Combine
import SwiftUI

// NSPanel hosting a SwiftUI PickerView. Borderless + nonactivating so
// the rest of the app's focus state isn't disturbed; we briefly call
// NSApp.activate(...) only when showing so keyboard input lands here.

final class PickerPanel: NSPanel {
    private let store: ClipStore
    private weak var watcher: ClipboardWatcher?
    private let viewModel: PickerViewModel
    private let hoverPreview = HoverPreviewPanel()
    private var hoverDebounce: DispatchWorkItem?
    private var selectionSub: AnyCancellable?
    // Local NSEvent monitor that fires *before* AppKit dispatches keyDown
    // to the field editor. Necessary for IME activation — the field editor
    // (NSTextView) handles keyDown directly and starts compose synchronously,
    // so a subclass-level keyDown override on NSSearchField doesn't run in
    // time. The monitor flips searchActive synchronously, letting the bar
    // expand before the IME candidate window is positioned.
    private var keyMonitor: Any?

    init(store: ClipStore, watcher: ClipboardWatcher?) {
        self.store = store
        self.watcher = watcher
        let vm = PickerViewModel(store: store)
        self.viewModel = vm

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 422),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.animationBehavior = .utilityWindow
        // Borderless panels have no title bar to grab — let the user drag
        // anywhere on the panel body. Saved on every move via
        // NSWindow.didMoveNotification below.
        self.isMovableByWindowBackground = true

        viewModel.onPick = { [weak self] item in
            self?.writeToPasteboard(item)
            self?.watcher?.acknowledgeOwnWrite()
            self?.hoverPreview.hide()
            self?.orderOut(nil)
        }
        viewModel.onCancel = { [weak self] in
            self?.hoverPreview.hide()
            self?.orderOut(nil)
        }

        // Container view = visual effect (blur + rounded corners) + SwiftUI host on top.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 422))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true

        let blur = NSVisualEffectView(frame: container.bounds)
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)

        let hosting = NSHostingView(rootView: PickerView(viewModel: viewModel))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        self.contentView = container

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didMove),
            name: NSWindow.didMoveNotification,
            object: self
        )

        // ViewModel fires this synchronously after items/selectedIndex are
        // committed — more reliable than `@Published` willSet, which would
        // require an async hop to read fresh state and still misses the
        // case where the index resets to 0 → 0 across a filter change.
        viewModel.onSelectionChanged = { [weak self] in self?.scheduleHoverPreview() }

        // Mouse-hover row selection bypasses the ViewModel's nav methods,
        // so we still need a Combine fallback for `selectedIndex` changes
        // driven directly from SwiftUI.
        selectionSub = viewModel.$selectedIndex
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleHoverPreview() }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  event.window === self,
                  self.isVisible,
                  Self.isPrintableInput(event),
                  !self.viewModel.searchActive
            else { return event }
            self.viewModel.activateSearch()
            return event
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    /// Printable text input — excludes pure modifiers, navigation keys
    /// (arrows / Esc / Return / Tab / Backspace), and the AppKit function
    /// key plane (0xF700–0xF8FF). Includes IME trigger keys (a/q/etc.)
    /// since the user is about to start composing.
    private static func isPrintableInput(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) { return false }
        guard let chars = event.characters, !chars.isEmpty else { return false }
        return chars.unicodeScalars.contains { sc in
            let v = sc.value
            if v < 0x20 || v == 0x7F { return false }
            if v >= 0xF700 && v <= 0xF8FF { return false }
            return true
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func showAtCursor() {
        viewModel.reload()

        let origin = resolveOrigin()
        setFrameOrigin(origin)

        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    /// Saved position from last session if it still fits on a connected screen;
    /// otherwise centered on the screen under the mouse (first run, or the
    /// monitor that hosted the old position is gone).
    private func resolveOrigin() -> NSPoint {
        let size = frame.size
        if let saved = Settings.pickerOrigin {
            let rect = NSRect(origin: saved, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                return saved
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
        guard let vis = screen?.visibleFrame else { return .zero }
        return NSPoint(
            x: vis.midX - size.width / 2,
            y: vis.midY - size.height / 2
        )
    }

    @objc private func didMove(_ note: Notification) {
        Settings.pickerOrigin = frame.origin
    }

    /// Re-pull settings and items. Called when a menu action toggled a
    /// setting while the panel is still on screen.
    func reloadFromSettings() {
        viewModel.reload()
    }

    override func resignKey() {
        super.resignKey()
        hoverPreview.hide()
        orderOut(nil)
    }

    private func scheduleHoverPreview() {
        hoverDebounce?.cancel()
        // Hide synchronously if the current selection has nothing to preview
        // (or no selection at all). Debouncing the hide leaves a stale image
        // or color swatch visible while the user arrow-keys between filters.
        //
        // We deliberately don't check `isVisible` here: showAtCursor() calls
        // `reload()` BEFORE `makeKeyAndOrderFront`, so the first scheduling
        // tick happens while the panel is still hidden. `presentHoverPreview`
        // re-checks `isVisible` after the 250ms debounce, by which time the
        // panel is on screen.
        let items = viewModel.items
        let idx = viewModel.selectedIndex
        guard items.indices.contains(idx) else {
            hoverPreview.hide()
            return
        }
        let item = items[idx]
        switch item.card {
        case .image, .fileURL, .color:
            let work = DispatchWorkItem { [weak self] in self?.presentHoverPreview() }
            hoverDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        case .text, .url, .phone, .email, .creditCard, .ssn, .address, .command:
            // Plain text / URL / personal cards have nothing extra to
            // show — the row already renders the full value (or masked
            // last-4 for CC/SSN). A hover panel would just duplicate.
            hoverPreview.hide()
        }
    }

    private func presentHoverPreview() {
        guard isVisible else { hoverPreview.hide(); return }
        let items = viewModel.items
        let idx = viewModel.selectedIndex
        guard items.indices.contains(idx) else { hoverPreview.hide(); return }
        let item = items[idx]
        switch item.card {
        case .image, .fileURL, .color:
            hoverPreview.show(for: item, store: store, anchor: frame)
        case .text, .url, .phone, .email, .creditCard, .ssn, .address, .command:
            hoverPreview.hide()
        }
    }

    private func writeToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            if let s = item.text {
                pb.setString(s, forType: .string)
            }
            // Replay any rich UTI payloads captured at copy time so the
            // target app (Notes, Pages, web mailers) sees the styled version.
            for payload in store.payloads(for: item.id) {
                pb.setData(payload.data, forType: NSPasteboard.PasteboardType(payload.uti))
            }
        case .image:
            if let path = item.imagePath, let data = store.loadImage(path) {
                pb.setData(data, forType: .png)
            }
        case .fileURL:
            if let strs = item.fileURLs {
                let urls = strs.compactMap { URL(string: $0) as NSURL? }
                if !urls.isEmpty {
                    pb.writeObjects(urls)
                }
            }
        }
    }
}
