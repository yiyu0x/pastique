import AppKit
import Sparkle

// Thin wrapper around Sparkle's SPUStandardUpdaterController.
//
// Sparkle requires SUPublicEDKey in Info.plist to start. On a dev build
// that hasn't gone through tools/setup-sparkle.sh, that key is empty
// and Sparkle would pop a "The updater failed to start." alert at every
// launch. So we check first: configured → real updater, unconfigured →
// no-op object that just tells the user when they click "Check for Updates".

@MainActor
final class UpdaterController {
    private let controller: SPUStandardUpdaterController?
    private var openObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    /// Count of Sparkle-owned windows currently on screen. Sparkle opens
    /// several windows in sequence (initial prompt → download progress →
    /// install-and-relaunch), so we transform back to `.accessory` only
    /// when the *last* one goes away, not after every individual close.
    private var sparkleWindowCount = 0
    /// Pending "demote back to accessory" work. Cancelled if another
    /// Sparkle window opens during the post-close grace window, so the
    /// Dock icon doesn't flicker off and immediately back on between
    /// dialog steps.
    private var pendingDemote: DispatchWorkItem?

    init() {
        let key = (Bundle.main.infoDictionary?["SUPublicEDKey"] as? String) ?? ""
        if key.trimmingCharacters(in: .whitespaces).isEmpty {
            self.controller = nil
        } else {
            self.controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            installSparkleActivationHooks()
        }
    }

    deinit {
        let nc = NotificationCenter.default
        if let o = openObserver { nc.removeObserver(o) }
        if let o = closeObserver { nc.removeObserver(o) }
    }

    func checkForUpdates() {
        if let c = controller {
            // LSUIElement apps don't auto-foreground when a window appears;
            // without this the Sparkle alert can come up behind the active app.
            NSApp.activate(ignoringOtherApps: true)
            c.checkForUpdates(nil)
        } else {
            let alert = NSAlert()
            alert.messageText = "Auto-update is not configured for this build"
            alert.informativeText = "This Pastique build wasn't published through the signed-release pipeline, so it can't check for updates. Visit https://github.com/yiyu0x/pastique/releases to get the latest version."
            alert.alertStyle = .informational
            alert.runModal()
        }
    }

    /// Detect Sparkle-owned windows by class prefix (SPU* / SU*) and, while
    /// any are on screen, temporarily promote the app from LSUIElement
    /// (`.accessory`) to a regular Dock app (`.regular`). Effects:
    ///   - Sparkle's window gets standard macOS chrome (proper shadow,
    ///     normal titlebar) instead of looking like a floating utility
    ///     panel — the previous workaround bumped level to `.floating`
    ///     just to keep the dialog on top, but that styling is what made
    ///     the prompt feel non-native.
    ///   - The window has a Dock owner, so Cmd-Tab and Mission Control
    ///     treat it like any other app dialog instead of an orphan.
    ///   - `NSApp.activate` actually brings the dialog forward without the
    ///     window-level hack.
    /// We demote back to `.accessory` after the last Sparkle window
    /// disappears, with a short grace period so multi-step flows
    /// (prompt → progress → relaunch) don't flash the Dock icon between
    /// steps.
    private func installSparkleActivationHooks() {
        let nc = NotificationCenter.default
        openObserver = nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let win = note.object as? NSWindow,
                  Self.isSparkleWindow(win) else { return }
            MainActor.assumeIsolated { self?.handleSparkleWindowOpened() }
        }
        closeObserver = nc.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let win = note.object as? NSWindow,
                  Self.isSparkleWindow(win) else { return }
            MainActor.assumeIsolated { self?.handleSparkleWindowClosed() }
        }
    }

    nonisolated private static func isSparkleWindow(_ win: NSWindow) -> Bool {
        let cls = String(describing: type(of: win))
        return cls.hasPrefix("SPU") || cls.hasPrefix("SU")
    }

    private func handleSparkleWindowOpened() {
        pendingDemote?.cancel()
        pendingDemote = nil
        if sparkleWindowCount == 0 {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        sparkleWindowCount += 1
    }

    private func handleSparkleWindowClosed() {
        sparkleWindowCount = max(0, sparkleWindowCount - 1)
        guard sparkleWindowCount == 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDemote = nil
            // Re-check the counter — a new Sparkle window may have raced
            // open since the close fired but before this work runs.
            if self.sparkleWindowCount == 0 {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        pendingDemote = work
        // 0.8s covers Sparkle's typical inter-window gap (prompt → download
        // → install) without leaving a stale Dock icon around long after
        // the user dismissed the dialog.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}
