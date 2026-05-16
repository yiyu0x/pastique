import AppKit

@MainActor
final class PickerController {
    private let store: ClipStore
    private weak var watcher: ClipboardWatcher?
    private var panel: PickerPanel?

    init(store: ClipStore, watcher: ClipboardWatcher?) {
        self.store = store
        self.watcher = watcher
    }

    func toggle() {
        if let p = panel, p.isVisible {
            p.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            panel = PickerPanel(store: store, watcher: watcher)
        }
        panel?.showAtCursor()
    }

    /// If the panel is currently on screen, re-pull settings + items so a
    /// menubar/gear action made while it was visible is reflected immediately.
    func refreshIfVisible() {
        guard let p = panel, p.isVisible else { return }
        p.reloadFromSettings()
    }
}
