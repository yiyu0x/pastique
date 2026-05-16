import Foundation

enum ClipKind: String, Codable {
    case text
    case image
    case fileURL
}

struct ClipItem: Identifiable, Equatable, Hashable {
    let id: Int64
    let kind: ClipKind
    let preview: String
    let createdAt: Date
    let useCount: Int
    let text: String?
    let imagePath: String?        // basename inside ClipStore.imagesDir
    let thumbnail: Data?          // 128px PNG for picker rendering
    let fileURLs: [String]?       // absolute URL strings (file://...)
    /// Refinement of `.text` — color code, URL, etc. Nil for non-text or
    /// plain text. Used by the picker to pick a specialized card layout.
    let subtype: TextSubtype?
}

extension ClipItem {
    /// What kind of card the picker should render. Collapses (kind, subtype)
    /// into a single switchable value so the view doesn't have to redo the
    /// refinement logic in every branch.
    enum Card {
        case text, image, fileURL, color, url
        case phone, email, creditCard, ssn, address
        case command
    }

    var card: Card {
        switch kind {
        case .image:   return .image
        case .fileURL: return .fileURL
        case .text:
            switch subtype {
            case .color:      return .color
            case .url:        return .url
            case .phone:      return .phone
            case .email:      return .email
            case .creditCard: return .creditCard
            case .ssn:        return .ssn
            case .address:    return .address
            case .command:    return .command
            case .none:       return .text
            }
        }
    }

    /// True for card types that are personally identifiable / financial.
    /// Drives the `Personal` chip rollup and (for CC/SSN) preview masking.
    var isPersonal: Bool {
        switch card {
        case .phone, .email, .creditCard, .ssn, .address: return true
        default: return false
        }
    }
}

/// Display-side masking for sensitive numeric clips. The pasteboard write
/// path uses `item.text` directly and is unaffected — these helpers only
/// shape what the picker renders on screen so a shoulder-surfer can't read
/// a full SSN or PAN off the list. Last-4 is preserved so the user can
/// still tell two cards apart at a glance.
enum SensitiveMask {
    static func creditCard(_ s: String) -> String {
        let digits = s.filter { $0.isNumber }
        guard digits.count >= 4 else { return s }
        let last4 = String(digits.suffix(4))
        return "•••• •••• •••• \(last4)"
    }

    static func ssn(_ s: String) -> String {
        let digits = s.filter { $0.isNumber }
        guard digits.count == 9 else { return s }
        let last4 = String(digits.suffix(4))
        return "•••-••-\(last4)"
    }
}
