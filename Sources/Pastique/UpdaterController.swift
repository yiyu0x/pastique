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
    private var windowObserver: NSObjectProtocol?

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
            installWindowFloatingHook()
        }
    }

    deinit {
        if let obs = windowObserver {
            NotificationCenter.default.removeObserver(obs)
        }
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

    /// Sparkle's standard UI uses ordinary windows that obey the usual
    /// front-most-app rules — fine for a focused app, but as an LSUIElement
    /// agent we frequently *aren't* front, and the prompt slides behind
    /// whatever the user is working on. Detecting Sparkle-owned windows by
    /// class prefix (SPU* / SU*) and bumping them to floating level keeps
    /// the prompt on top across spaces and after focus changes.
    private func installWindowFloatingHook() {
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let win = note.object as? NSWindow else { return }
            let cls = String(describing: type(of: win))
            guard cls.hasPrefix("SPU") || cls.hasPrefix("SU") else { return }
            win.level = .floating
            win.hidesOnDeactivate = false
            win.collectionBehavior.insert(.canJoinAllSpaces)
        }
    }
}
