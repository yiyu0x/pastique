import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ClipStore!
    private var watcher: ClipboardWatcher!
    private var hotKey: HotKeyManager!
    private var picker: PickerController!
    private var statusItem: NSStatusItem?
    private let updater = UpdaterController()
    private var hotKeyRecorder: HotKeyRecorderController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        installEditMenu()

        // First-run: opt the user into Launch-at-Login. SMAppService may
        // throw or require approval depending on bundle location; we
        // silently ignore — user can fix via Menubar → Launch at Login.
        let ud = UserDefaults.standard
        if !ud.bool(forKey: "loginItemInitialized") {
            try? LoginItem.set(enabled: true)
            ud.set(true, forKey: "loginItemInitialized")
        }

        do {
            store = try ClipStore()
        } catch {
            fatalAlert("Failed to open clip store", detail: "\(error)")
        }

        watcher = ClipboardWatcher(store: store)
        watcher.start()

        picker = PickerController(store: store, watcher: watcher)

        hotKey = HotKeyManager()
        let registered = hotKey.register(
            keyCode: Settings.hotKeyCode,
            modifiers: Settings.hotKeyModifiers
        ) { [weak self] in
            self?.picker.toggle()
        }

        if !registered {
            let alert = NSAlert()
            alert.messageText = "Pastique could not register the hotkey"
            alert.informativeText = "\(HotKeyFormatter.string(keyCode: Settings.hotKeyCode, modifiers: Settings.hotKeyModifiers)) is already in use by another application. Pick a different combination from the menubar → Change Hotkey…"
            alert.alertStyle = .warning
            alert.runModal()
        }

        if Settings.showMenubarIcon {
            installStatusItem()
        }
    }

    // LSUIElement apps have no visible menu bar, but NSApp.mainMenu is still
    // consulted to resolve ⌘-key equivalents like ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z
    // inside text fields. Without an Edit menu these shortcuts silently do
    // nothing — actions target nil so they route through the responder chain
    // to the focused NSTextField / field editor.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        // First slot is conventionally the app menu — empty is fine, but it
        // must exist or AppKit won't process the rest correctly.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Pastique")
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo",
                              action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSResponder.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                   accessibilityDescription: "Pastique")
        }
        item.menu = buildSharedMenu()
        statusItem = item
    }

    /// Single source of truth for the settings menu. Both the menubar status
    /// item and the picker's ⚙ button pop up this menu. Rebuilt fresh on every
    /// call so check-marks always reflect current Settings.
    func buildSharedMenu() -> NSMenu {
        let menu = NSMenu()

        let combo = HotKeyFormatter.string(keyCode: Settings.hotKeyCode,
                                           modifiers: Settings.hotKeyModifiers)
        let openItem = NSMenuItem(title: "Open Pastique  (\(combo))",
                                  action: #selector(openPicker), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        // Sort By submenu
        let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        let current = Settings.sortOrder
        let recencyItem = NSMenuItem(title: "Recency (newest first)",
                                     action: #selector(setSortRecency), keyEquivalent: "")
        recencyItem.target = self
        recencyItem.state = (current == .recency) ? .on : .off
        sortMenu.addItem(recencyItem)
        let freqItem = NSMenuItem(title: "Frequency (most used first)",
                                  action: #selector(setSortFrequency), keyEquivalent: "")
        freqItem.target = self
        freqItem.state = (current == .frequency) ? .on : .off
        sortMenu.addItem(freqItem)
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)

        // Appearance submenu
        let styleItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        let currentStyle = Settings.viewStyle
        let compactItem = NSMenuItem(title: "Compact",
                                     action: #selector(setStyleCompact), keyEquivalent: "")
        compactItem.target = self
        compactItem.state = (currentStyle == .compact) ? .on : .off
        styleMenu.addItem(compactItem)
        let detailedItem = NSMenuItem(title: "Detailed",
                                      action: #selector(setStyleDetailed), keyEquivalent: "")
        detailedItem.target = self
        detailedItem.state = (currentStyle == .detailed) ? .on : .off
        styleMenu.addItem(detailedItem)
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let richItem = NSMenuItem(title: "Keep Original Formatting",
                                  action: #selector(toggleRichMode), keyEquivalent: "")
        richItem.target = self
        richItem.state = Settings.richMode ? .on : .off
        menu.addItem(richItem)

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "Clear All History...",
                                   action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: "Check for Updates...",
                                    action: #selector(checkForUpdates),
                                    keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let hotkeyItem = NSMenuItem(title: "Change Hotkey…",
                                    action: #selector(changeHotkey),
                                    keyEquivalent: "")
        hotkeyItem.target = self
        menu.addItem(hotkeyItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)

        // Symmetric toggle so the same menu (shared between the status item
        // and the picker's ⚙) is usable from either side. With a checkmark
        // the user can always tell which state they're in and toggle back.
        let toggleItem = NSMenuItem(title: "Show Menu Bar Icon",
                                    action: #selector(toggleMenubarIcon),
                                    keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = Settings.showMenubarIcon ? .on : .off
        menu.addItem(toggleItem)

        // Subtle version footer just above Quit — disabled, small font.
        // Matches the convention in CleanShot X / Bartender / Rectangle:
        // it's there if you look for it, invisible if you're not.
        let versionItem = NSMenuItem(title: Self.versionString,
                                     action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        versionItem.attributedTitle = NSAttributedString(
            string: Self.versionString,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        )
        menu.addItem(versionItem)

        let quitItem = NSMenuItem(title: "Quit Pastique",
                                  action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    /// Called after any settings change so check-marks stay current.
    /// Also nudges the picker panel (if visible) to re-read settings so a
    /// menu action taken while the picker is open re-sorts the list etc.
    func refreshMenubarMenu() {
        statusItem?.menu = buildSharedMenu()
        picker?.refreshIfVisible()
    }

    func setMenubarIconVisible(_ visible: Bool) {
        Settings.showMenubarIcon = visible
        if visible {
            if statusItem == nil { installStatusItem() }
        } else {
            if let s = statusItem {
                NSStatusBar.system.removeStatusItem(s)
                statusItem = nil
            }
        }
    }

    // MARK: - Menu actions

    @objc private func openPicker() { picker.show() }

    @objc private func setSortRecency() {
        Settings.sortOrder = .recency
        refreshMenubarMenu()
    }

    @objc private func setSortFrequency() {
        Settings.sortOrder = .frequency
        refreshMenubarMenu()
    }

    @objc private func setStyleCompact() {
        Settings.viewStyle = .compact
        refreshMenubarMenu()
    }

    @objc private func setStyleDetailed() {
        Settings.viewStyle = .detailed
        refreshMenubarMenu()
    }

    @objc private func toggleRichMode() {
        Settings.richMode = !Settings.richMode
        refreshMenubarMenu()
    }

    /// Public hook for the picker's gear menu.
    func toggleLoginItemPublic() { toggleLoginItem() }

    @objc private func toggleLoginItem() {
        let nowEnabled = LoginItem.isEnabled
        do {
            try LoginItem.set(enabled: !nowEnabled)
        } catch {
            let alert = NSAlert()
            if LoginItem.requiresApproval {
                alert.messageText = "Pastique needs your approval"
                alert.informativeText = "Open System Settings → General → Login Items and turn Pastique on. Opening Settings now."
                alert.alertStyle = .informational
                alert.runModal()
                LoginItem.openSystemSettings()
            } else {
                alert.messageText = "Could not change Launch at Login"
                alert.informativeText = "\(error)\n\nTip: this works best when Pastique.app lives in /Applications."
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
        refreshMenubarMenu()
    }

    @objc func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "All saved clips and their image files will be deleted. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try store.deleteAll()
            } catch {
                NSLog("Pastique: clearHistory failed: %@", "\(error)")
            }
        }
    }

    @objc private func toggleMenubarIcon() {
        let nowVisible = Settings.showMenubarIcon
        if nowVisible, !Settings.seenHideMenubarHint {
            let alert = NSAlert()
            alert.messageText = "Hide the menubar icon?"
            alert.informativeText = "You can still open Pastique with \(HotKeyFormatter.string(keyCode: Settings.hotKeyCode, modifiers: Settings.hotKeyModifiers)). To bring the icon back, open Pastique and use the ⚙ menu → Show Menu Bar Icon."
            alert.addButton(withTitle: "Hide")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .informational
            let res = alert.runModal()
            if res != .alertFirstButtonReturn { return }
            Settings.seenHideMenubarHint = true
        }
        setMenubarIconVisible(!nowVisible)
        refreshMenubarMenu()
    }

    @objc func changeHotkey() {
        if hotKeyRecorder == nil {
            hotKeyRecorder = HotKeyRecorderController { [weak self] code, mods in
                guard let self else { return false }
                let prevCode = Settings.hotKeyCode
                let prevMods = Settings.hotKeyModifiers
                Settings.hotKeyCode = code
                Settings.hotKeyModifiers = mods
                if self.hotKey.reregister(keyCode: code, modifiers: mods) {
                    self.refreshMenubarMenu()
                    return true
                }
                Settings.hotKeyCode = prevCode
                Settings.hotKeyModifiers = prevMods
                _ = self.hotKey.reregister(keyCode: prevCode, modifiers: prevMods)
                return false
            }
        }
        hotKeyRecorder?.show()
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// Hook for the picker's gear menu.
    func checkForUpdatesPublic() { checkForUpdates() }

    @objc private func quit() { NSApp.terminate(nil) }

    /// "Pastique 0.1.0 (build 7)" pulled from Info.plist at runtime. Used as
    /// the disabled header item in the menubar dropdown and picker gear menu.
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Pastique \(version) (build \(build))"
    }
}

private func fatalAlert(_ message: String, detail: String) -> Never {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = detail
    alert.alertStyle = .critical
    alert.runModal()
    exit(1)
}
