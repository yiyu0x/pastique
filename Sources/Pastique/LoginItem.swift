import AppKit
import ServiceManagement

// Wraps SMAppService.mainApp (macOS 13+). Registering the running .app
// bundle is enough — no separate helper login item or .plist needed.
//
// Status meanings we care about:
//   .enabled         → will launch at login
//   .notRegistered   → off
//   .notFound        → app isn't where it was when registered (moved)
//   .requiresApproval → user needs to approve in System Settings

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(enabled: Bool) throws {
        let svc = SMAppService.mainApp
        if enabled {
            guard svc.status != .enabled else { return }
            try svc.register()
        } else {
            guard svc.status == .enabled || svc.status == .requiresApproval else { return }
            try svc.unregister()
        }
    }

    /// Opens System Settings → General → Login Items for the user.
    static func openSystemSettings() {
        // macOS 13+ deep link to the Login Items pane.
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
