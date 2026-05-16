import Foundation
import Carbon.HIToolbox

enum SortOrder: String {
    case recency       // most recently copied first
    case frequency     // most used first, ties broken by recency
}

enum ViewStyle: String {
    case compact       // single-line preview, 22px row, smaller icon
    case detailed      // two-line preview + timestamp + use count, 48px row
}

enum Settings {
    private static let d = UserDefaults.standard

    /// Register first-launch defaults. Called once at app start.
    /// `register` does NOT overwrite a value the user has already set,
    /// it only fills in the missing keys.
    static func registerDefaults() {
        d.register(defaults: [
            "showMenubarIcon": true,
            "richMode": false,
            "sortOrder": SortOrder.recency.rawValue,
            "viewStyle": ViewStyle.compact.rawValue,
        ])
    }

    static var showMenubarIcon: Bool {
        get { d.bool(forKey: "showMenubarIcon") }
        set { d.set(newValue, forKey: "showMenubarIcon") }
    }

    static var richMode: Bool {
        get { d.bool(forKey: "richMode") }
        set { d.set(newValue, forKey: "richMode") }
    }

    static var sortOrder: SortOrder {
        get { SortOrder(rawValue: d.string(forKey: "sortOrder") ?? "") ?? .recency }
        set { d.set(newValue.rawValue, forKey: "sortOrder") }
    }

    static var viewStyle: ViewStyle {
        get { ViewStyle(rawValue: d.string(forKey: "viewStyle") ?? "") ?? .detailed }
        set { d.set(newValue.rawValue, forKey: "viewStyle") }
    }

    /// Carbon keyCode for the global hotkey. nil → use default ⌘⇧V.
    static var hotKeyCode: UInt32 {
        get {
            let v = d.integer(forKey: "hotKeyCode")
            return v > 0 ? UInt32(v) : UInt32(kVK_ANSI_V)
        }
        set { d.set(Int(newValue), forKey: "hotKeyCode") }
    }

    /// Carbon modifier mask (cmdKey | shiftKey | optionKey | controlKey).
    /// 0 → default ⌘⇧.
    static var hotKeyModifiers: UInt32 {
        get {
            let v = d.integer(forKey: "hotKeyModifiers")
            return v > 0 ? UInt32(v) : UInt32(cmdKey | shiftKey)
        }
        set { d.set(Int(newValue), forKey: "hotKeyModifiers") }
    }

    /// True once the user has been told that hiding the menubar icon is
    /// reversible via the picker's ⚙ menu. Prevents the recovery alert
    /// from nagging on every toggle.
    static var seenHideMenubarHint: Bool {
        get { d.bool(forKey: "seenHideMenubarHint") }
        set { d.set(newValue, forKey: "seenHideMenubarHint") }
    }

    /// Last user-positioned origin of the picker panel, in bottom-left screen
    /// coordinates. nil on first run → caller picks a sensible default.
    static var pickerOrigin: NSPoint? {
        get {
            guard let dict = d.dictionary(forKey: "pickerOrigin"),
                  let x = dict["x"] as? Double,
                  let y = dict["y"] as? Double else { return nil }
            return NSPoint(x: x, y: y)
        }
        set {
            if let p = newValue {
                d.set(["x": p.x, "y": p.y], forKey: "pickerOrigin")
            } else {
                d.removeObject(forKey: "pickerOrigin")
            }
        }
    }
}
