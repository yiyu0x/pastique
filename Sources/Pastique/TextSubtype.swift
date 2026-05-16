import AppKit
import Foundation

// A text-kind clip can be refined into a known shape (color code, URL, …)
// so the picker can render a specialized card instead of a generic text
// row. Detection happens once at insert time and the subtype is persisted
// on the clip row — render code just dispatches on the stored value.

enum TextSubtype: String, Codable {
    case color
    case url
    case phone
    case email
    case creditCard
    case ssn
    case address
    case command

    /// Return the subtype for `raw` if it matches one of the known shapes,
    /// otherwise nil. Detection is exact: the entire trimmed string must be
    /// the value — substring matches are ignored to avoid false positives
    /// (e.g. "see https://x" is not a URL clip; "#abc in code" is not color).
    /// Order matters:
    ///   - email / ssn / CC have rigid shapes — check first so they can't be
    ///     mis-classified as phone or address by the loose NSDataDetector
    ///   - command is checked before phone because shell commands can contain
    ///     digit-heavy args that the phone detector would chew on
    ///   - phone (NSDataDetector) before address — addresses can contain a
    ///     phone-shaped substring but never the reverse
    static func detect(_ raw: String) -> TextSubtype? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isColor(trimmed) { return .color }
        if isURL(trimmed) { return .url }
        if isEmail(trimmed) { return .email }
        if isSSN(trimmed) { return .ssn }
        if isCreditCard(trimmed) { return .creditCard }
        if isCommand(trimmed) { return .command }
        if isPhone(trimmed) { return .phone }
        if isAddress(trimmed) { return .address }
        return nil
    }

    // MARK: - Email shape

    static func isEmail(_ s: String) -> Bool {
        // Pragmatic shape — local@host.tld, where TLD is ≥2 letters. Not
        // RFC-perfect (no quoted locals, no IDN), but a clipboard clip
        // that doesn't fit this shape almost certainly isn't an email
        // someone is about to paste into an email field.
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - SSN shape (US: NNN-NN-NNNN)

    static func isSSN(_ s: String) -> Bool {
        return s.range(of: #"^\d{3}-\d{2}-\d{4}$"#, options: .regularExpression) != nil
    }

    // MARK: - Credit card shape (US-style, 13–19 digits, Luhn-validated)

    /// Accepts digits with optional space or hyphen separators. The Luhn
    /// check is what makes this trustworthy — without it any 16-digit order
    /// number or tracking ID would land in the "Personal" bucket and pollute
    /// the chip.
    static func isCreditCard(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: " ", with: "")
                        .replacingOccurrences(of: "-", with: "")
        guard stripped.count >= 13, stripped.count <= 19 else { return false }
        guard stripped.allSatisfy({ $0.isNumber }) else { return false }
        return luhn(stripped)
    }

    private static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard let d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }

    // MARK: - Phone / Address (NSDataDetector)

    /// NSDataDetector is what Mail, Notes, and Safari use to underline
    /// phone numbers and addresses. It handles NANP shapes, international
    /// shapes, and address segmentation (street / city / state / ZIP) far
    /// better than any regex we'd write by hand — and ships with the OS,
    /// no model files or network calls.
    static func isPhone(_ s: String) -> Bool {
        return dataDetectorMatchesEntireString(s, type: .phoneNumber)
    }

    static func isAddress(_ s: String) -> Bool {
        return dataDetectorMatchesEntireString(s, type: .address)
    }

    /// True only when NSDataDetector's first match spans the ENTIRE trimmed
    /// string. The detector by default returns substring hits — "call me at
    /// 415-555-1234 ok" would otherwise classify as phone. We treat the
    /// clipboard like a single semantic value: if the whole clip isn't the
    /// detected entity, it isn't one.
    private static func dataDetectorMatchesEntireString(
        _ s: String,
        type: NSTextCheckingResult.CheckingType
    ) -> Bool {
        guard let detector = try? NSDataDetector(types: type.rawValue) else { return false }
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = detector.firstMatch(in: s, options: [], range: full) else { return false }
        return NSEqualRanges(match.range, full)
    }

    // MARK: - Command shape

    /// Heuristic command detector: first line starts with a shell prompt
    /// glyph, a `./` invocation, or a known CLI verb. CJK rejection guards
    /// against Chinese / Japanese clipboard prose that may begin with an
    /// ASCII-looking glyph. Whitelist is intentionally finite — easier to
    /// add a tool name than to debug a regex matching natural language.
    static func isCommand(_ s: String) -> Bool {
        let firstLine = s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? s
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // Peel off a prompt-glyph prefix first — popular shells (fish,
        // Starship) use `❯` which isn't ASCII. After peeling, the rest of
        // the first line must be pure ASCII printable: shell commands don't
        // contain emoji, accented letters, or CJK. Catching all non-ASCII
        // at once kills the "git 是 ..." / "git 🚀 ..." false positives
        // without script-by-script reject lists.
        let body: String
        if let first = trimmed.first, "$%>❯→".contains(first) {
            body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            if body.isEmpty { return false }
        } else {
            body = trimmed
        }
        guard bodyIsASCIIPrintable(body) else { return false }
        if body.hasPrefix("./") || body.hasPrefix("../") ||
           body.hasPrefix("/usr/") || body.hasPrefix("/bin/") {
            return true
        }
        let firstToken = String(body.split(separator: " ", maxSplits: 1,
                                           omittingEmptySubsequences: true).first ?? "")
        return commandVerbs.contains(firstToken)
    }

    private static func bodyIsASCIIPrintable(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v == 0x09 { continue }
            if v < 0x20 || v > 0x7E { return false }
        }
        return true
    }

    private static let commandVerbs: Set<String> = [
        "git", "gh", "npm", "yarn", "pnpm", "bun", "deno", "node", "nvm",
        "python", "python3", "pip", "pip3", "pipenv", "poetry", "uv",
        "brew", "mas", "port",
        "docker", "docker-compose", "podman", "kubectl", "k9s", "helm", "minikube",
        "cargo", "rustc", "rustup", "go", "make", "cmake", "ninja", "bazel",
        "swift", "swiftc", "xcodebuild", "fastlane", "pod",
        "curl", "wget", "http", "httpie",
        "ssh", "scp", "sftp", "rsync",
        "tar", "gzip", "gunzip", "zip", "unzip",
        "chmod", "chown", "chgrp", "sudo", "su", "doas",
        "cd", "ls", "ll", "la", "tree", "pwd",
        "mkdir", "rmdir", "rm", "cp", "mv", "ln", "touch",
        "cat", "bat", "less", "more", "head", "tail",
        "grep", "rg", "ag", "ack",
        "sed", "awk", "cut", "tr", "sort", "uniq", "wc",
        "find", "fd", "locate", "xargs",
        "kill", "pkill", "killall", "ps", "top", "htop", "btop",
        "lsof", "netstat", "ss",
        "dig", "nslookup", "host", "ping", "traceroute", "mtr",
        "aws", "gcloud", "az", "doctl", "fly", "vercel", "netlify",
        "terraform", "tofu", "ansible", "vagrant", "packer", "pulumi",
        "composer", "gem", "bundle", "bundler", "rake",
        "mvn", "gradle", "lein",
        "flutter", "dart",
        "ruby", "php", "dotnet", "lua", "perl",
        "code", "vim", "nvim", "emacs",
        "tmux", "screen", "zellij",
        "open", "say", "defaults", "pmset", "launchctl", "diskutil", "sysctl",
        "systemctl", "service", "journalctl",
        "apt", "apt-get", "yum", "dnf", "pacman", "apk",
        "bash", "zsh", "sh", "fish",
        "export", "source",
        "psql", "mysql", "sqlite3", "redis-cli", "mongo", "mongosh",
        "ffmpeg", "magick", "convert"
    ]

    // MARK: - Color shape

    private static let hexColorRegex = try! NSRegularExpression(
        pattern: "^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"
    )
    private static let rgbRegex = try! NSRegularExpression(
        pattern: "^rgba?\\(\\s*\\d{1,3}\\s*,\\s*\\d{1,3}\\s*,\\s*\\d{1,3}(?:\\s*,\\s*(?:0|1|0?\\.\\d+))?\\s*\\)$"
    )
    private static let hslRegex = try! NSRegularExpression(
        pattern: "^hsla?\\(\\s*\\d{1,3}(?:deg)?\\s*,\\s*\\d{1,3}%\\s*,\\s*\\d{1,3}%(?:\\s*,\\s*(?:0|1|0?\\.\\d+))?\\s*\\)$"
    )

    static func isColor(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        for re in [hexColorRegex, rgbRegex, hslRegex] {
            if re.firstMatch(in: s, range: range) != nil { return true }
        }
        return false
    }

    // MARK: - URL shape

    static func isURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        if s.contains(where: { $0.isWhitespace }) { return false }
        guard let url = URL(string: s), let host = url.host, host.contains(".") else { return false }
        return true
    }
}

// MARK: - Color parsing

/// Normalized color value with all three encodings precomputed for display.
struct ParsedColor: Equatable {
    let color: NSColor
    let r: Int
    let g: Int
    let b: Int
    let a: Double

    var hex: String {
        a < 1.0
            ? String(format: "#%02X%02X%02X%02X", r, g, b, Int((a * 255).rounded()))
            : String(format: "#%02X%02X%02X", r, g, b)
    }
    var rgb: String {
        a < 1.0
            ? "rgba(\(r), \(g), \(b), \(String(format: "%.2f", a)))"
            : "rgb(\(r), \(g), \(b))"
    }
    var hsl: String {
        let (h, s, l) = ColorMath.rgbToHSL(r: r, g: g, b: b)
        return a < 1.0
            ? "hsla(\(h), \(s)%, \(l)%, \(String(format: "%.2f", a)))"
            : "hsl(\(h), \(s)%, \(l)%)"
    }
}

func parseColor(_ raw: String) -> ParsedColor? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let p = parseHexColor(s) { return p }
    if let p = parseRGBColor(s) { return p }
    if let p = parseHSLColor(s) { return p }
    return nil
}

private func parseHexColor(_ s: String) -> ParsedColor? {
    guard s.hasPrefix("#") else { return nil }
    let hex = String(s.dropFirst())
    let chars = Array(hex)
    func hx1(_ c: Character) -> Int? { Int(String(c), radix: 16) }
    func hx2(_ a: Character, _ b: Character) -> Int? { Int("\(a)\(b)", radix: 16) }
    var r = 0, g = 0, b = 0, a = 1.0
    switch chars.count {
    case 3:
        guard let rr = hx1(chars[0]), let gg = hx1(chars[1]), let bb = hx1(chars[2]) else { return nil }
        r = rr * 17; g = gg * 17; b = bb * 17
    case 4:
        guard let rr = hx1(chars[0]), let gg = hx1(chars[1]),
              let bb = hx1(chars[2]), let aa = hx1(chars[3]) else { return nil }
        r = rr * 17; g = gg * 17; b = bb * 17; a = Double(aa * 17) / 255
    case 6:
        guard let rr = hx2(chars[0], chars[1]),
              let gg = hx2(chars[2], chars[3]),
              let bb = hx2(chars[4], chars[5]) else { return nil }
        r = rr; g = gg; b = bb
    case 8:
        guard let rr = hx2(chars[0], chars[1]),
              let gg = hx2(chars[2], chars[3]),
              let bb = hx2(chars[4], chars[5]),
              let aa = hx2(chars[6], chars[7]) else { return nil }
        r = rr; g = gg; b = bb; a = Double(aa) / 255
    default:
        return nil
    }
    return makeColor(r: r, g: g, b: b, a: a)
}

private func parseRGBColor(_ s: String) -> ParsedColor? {
    let pattern = "^rgba?\\(\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})(?:\\s*,\\s*([01](?:\\.\\d+)?|\\.\\d+))?\\s*\\)$"
    guard let m = matchGroups(s, pattern: pattern), m.count >= 4 else { return nil }
    guard let r = Int(m[1]), let g = Int(m[2]), let b = Int(m[3]),
          r <= 255, g <= 255, b <= 255 else { return nil }
    var a = 1.0
    if m.count > 4, let av = Double(m[4]), av >= 0, av <= 1 { a = av }
    return makeColor(r: r, g: g, b: b, a: a)
}

private func parseHSLColor(_ s: String) -> ParsedColor? {
    let pattern = "^hsla?\\(\\s*(\\d{1,3})(?:deg)?\\s*,\\s*(\\d{1,3})%\\s*,\\s*(\\d{1,3})%(?:\\s*,\\s*([01](?:\\.\\d+)?|\\.\\d+))?\\s*\\)$"
    guard let m = matchGroups(s, pattern: pattern), m.count >= 4 else { return nil }
    guard let h = Int(m[1]), let sat = Int(m[2]), let light = Int(m[3]),
          h <= 360, sat <= 100, light <= 100 else { return nil }
    var a = 1.0
    if m.count > 4, let av = Double(m[4]), av >= 0, av <= 1 { a = av }
    let (r, g, b) = ColorMath.hslToRGB(h: h, s: sat, l: light)
    return makeColor(r: r, g: g, b: b, a: a)
}

private func makeColor(r: Int, g: Int, b: Int, a: Double) -> ParsedColor {
    let ns = NSColor(srgbRed: CGFloat(r) / 255,
                     green: CGFloat(g) / 255,
                     blue: CGFloat(b) / 255,
                     alpha: CGFloat(a))
    return ParsedColor(color: ns, r: r, g: g, b: b, a: a)
}

/// Return capture group values in order (group 0 is the whole match), or
/// nil if the pattern didn't match. Missing optional groups come back as
/// empty strings so the caller can do bounds checks without crashing.
private func matchGroups(_ s: String, pattern: String) -> [String]? {
    let re = try? NSRegularExpression(pattern: pattern)
    let range = NSRange(s.startIndex..., in: s)
    guard let m = re?.firstMatch(in: s, range: range) else { return nil }
    var out: [String] = []
    for i in 0..<m.numberOfRanges {
        let r = m.range(at: i)
        if r.location == NSNotFound {
            out.append("")
        } else {
            out.append((s as NSString).substring(with: r))
        }
    }
    return out
}

enum ColorMath {
    /// RGB(0..255) → HSL(0..360, 0..100, 0..100).
    static func rgbToHSL(r: Int, g: Int, b: Int) -> (Int, Int, Int) {
        let R = Double(r) / 255, G = Double(g) / 255, B = Double(b) / 255
        let mx = max(R, G, B), mn = min(R, G, B)
        let l = (mx + mn) / 2
        var h = 0.0, s = 0.0
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            switch mx {
            case R: h = (G - B) / d + (G < B ? 6 : 0)
            case G: h = (B - R) / d + 2
            default: h = (R - G) / d + 4
            }
            h *= 60
        }
        return (Int(h.rounded()), Int((s * 100).rounded()), Int((l * 100).rounded()))
    }

    /// HSL(0..360, 0..100, 0..100) → RGB(0..255).
    static func hslToRGB(h: Int, s: Int, l: Int) -> (Int, Int, Int) {
        let H = Double(h) / 360, S = Double(s) / 100, L = Double(l) / 100
        if S == 0 {
            let v = Int((L * 255).rounded())
            return (v, v, v)
        }
        func channel(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let q = L < 0.5 ? L * (1 + S) : L + S - L * S
        let p = 2 * L - q
        return (
            Int((channel(p, q, H + 1.0 / 3) * 255).rounded()),
            Int((channel(p, q, H) * 255).rounded()),
            Int((channel(p, q, H - 1.0 / 3) * 255).rounded())
        )
    }
}
