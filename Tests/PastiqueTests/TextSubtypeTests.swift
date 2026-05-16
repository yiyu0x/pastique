import Testing
import AppKit
import Foundation
@testable import Pastique

@Suite("TextSubtype — detection")
struct TextSubtypeDetectionTests {
    // MARK: hex color

    @Test func detectsHex6() {
        #expect(TextSubtype.detect("#FF5733") == .color)
        #expect(TextSubtype.detect("#ff5733") == .color)
    }

    @Test func detectsHex3() {
        #expect(TextSubtype.detect("#F53") == .color)
    }

    @Test func detectsHex8WithAlpha() {
        #expect(TextSubtype.detect("#FF5733AA") == .color)
    }

    @Test func detectsHex4WithAlpha() {
        #expect(TextSubtype.detect("#F53A") == .color)
    }

    @Test func ignoresMalformedHex() {
        #expect(TextSubtype.detect("#FFFFG") == nil)         // bad chars
        #expect(TextSubtype.detect("#FF") == nil)            // 2 hex (no valid form)
        #expect(TextSubtype.detect("#FF55F") == nil)         // 5 hex (no valid form)
        #expect(TextSubtype.detect("FF5733") == nil)         // missing #
    }

    @Test func ignoresHexEmbeddedInText() {
        #expect(TextSubtype.detect("see #FF5733 in palette") == nil)
        #expect(TextSubtype.detect("#FF5733;") == nil)
    }

    // MARK: rgb / rgba

    @Test func detectsRGB() {
        #expect(TextSubtype.detect("rgb(255, 87, 51)") == .color)
        #expect(TextSubtype.detect("rgb(0,0,0)") == .color)
    }

    @Test func detectsRGBA() {
        #expect(TextSubtype.detect("rgba(255, 87, 51, 0.8)") == .color)
        #expect(TextSubtype.detect("rgba(0, 0, 0, 1)") == .color)
    }

    @Test func ignoresMalformedRGB() {
        #expect(TextSubtype.detect("rgb()") == nil)
        #expect(TextSubtype.detect("rgb(255, 87)") == nil)
    }

    // MARK: hsl / hsla

    @Test func detectsHSL() {
        #expect(TextSubtype.detect("hsl(11, 100%, 60%)") == .color)
        #expect(TextSubtype.detect("hsl(0deg, 0%, 0%)") == .color)
    }

    @Test func detectsHSLA() {
        #expect(TextSubtype.detect("hsla(11, 100%, 60%, 0.5)") == .color)
    }

    // MARK: url

    @Test func detectsHTTPS() {
        #expect(TextSubtype.detect("https://example.com") == .url)
        #expect(TextSubtype.detect("https://example.com/path?q=1") == .url)
    }

    @Test func detectsHTTP() {
        #expect(TextSubtype.detect("http://example.com") == .url)
    }

    @Test func ignoresBareHost() {
        #expect(TextSubtype.detect("example.com") == nil)
    }

    @Test func ignoresFTPAndOtherSchemes() {
        #expect(TextSubtype.detect("ftp://example.com") == nil)
        #expect(TextSubtype.detect("file:///tmp/foo") == nil)
    }

    @Test func ignoresURLEmbeddedInText() {
        #expect(TextSubtype.detect("visit https://example.com today") == nil)
    }

    @Test func ignoresURLWithoutHostDot() {
        #expect(TextSubtype.detect("https://localhost") == nil)
    }

    // MARK: surrounding whitespace tolerated

    @Test func tolratesLeadingTrailingWhitespace() {
        #expect(TextSubtype.detect("  #FF5733\n") == .color)
        #expect(TextSubtype.detect(" https://example.com ") == .url)
    }

    // MARK: plain text

    @Test func plainTextHasNoSubtype() {
        #expect(TextSubtype.detect("hello world") == nil)
        #expect(TextSubtype.detect("") == nil)
        #expect(TextSubtype.detect("   ") == nil)
    }
}

@Suite("TextSubtype — color parsing")
struct ColorParsingTests {
    @Test func parsesHex6ToRGB() throws {
        let p = try #require(parseColor("#FF5733"))
        #expect(p.r == 255)
        #expect(p.g == 87)
        #expect(p.b == 51)
        #expect(p.a == 1.0)
    }

    @Test func parsesHex3ToRGB() throws {
        let p = try #require(parseColor("#F53"))
        #expect(p.r == 255)
        #expect(p.g == 85)
        #expect(p.b == 51)
    }

    @Test func parsesHex8WithAlpha() throws {
        let p = try #require(parseColor("#FF573380"))
        #expect(p.r == 255)
        #expect(p.g == 87)
        #expect(p.b == 51)
        #expect(abs(p.a - 0x80 / 255.0) < 0.001)
    }

    @Test func parsesRGB() throws {
        let p = try #require(parseColor("rgb(255, 87, 51)"))
        #expect(p.r == 255 && p.g == 87 && p.b == 51)
        #expect(p.a == 1.0)
    }

    @Test func parsesRGBA() throws {
        let p = try #require(parseColor("rgba(10, 20, 30, 0.5)"))
        #expect(p.r == 10 && p.g == 20 && p.b == 30)
        #expect(p.a == 0.5)
    }

    @Test func parsesHSLToCorrectRGB() throws {
        // Pure red: hsl(0, 100%, 50%) → rgb(255, 0, 0)
        let p = try #require(parseColor("hsl(0, 100%, 50%)"))
        #expect(p.r == 255 && p.g == 0 && p.b == 0)
    }

    @Test func parsedHEXOutputUppercase() throws {
        let p = try #require(parseColor("#ff5733"))
        #expect(p.hex == "#FF5733")
    }

    @Test func parsedHEXIncludesAlphaWhenLessThan1() throws {
        let p = try #require(parseColor("#FF573380"))
        #expect(p.hex.count == 9)
    }

    @Test func rgbToHSLRoundTrips() {
        // Pure red round-trip — small rounding tolerance.
        let (h, s, l) = ColorMath.rgbToHSL(r: 255, g: 0, b: 0)
        #expect(h == 0)
        #expect(s == 100)
        #expect(l == 50)
        let (r, g, b) = ColorMath.hslToRGB(h: h, s: s, l: l)
        #expect(r == 255 && g == 0 && b == 0)
    }

    @Test func parserRejectsGarbage() {
        #expect(parseColor("not a color") == nil)
        #expect(parseColor("#GGGGGG") == nil)
        #expect(parseColor("rgb(300, 0, 0)") == nil)  // out of range
    }
}

@Suite("ClipStore — subtype persistence")
struct ClipStoreSubtypeTests {
    let tempDir: URL
    let store: ClipStore

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastiqueTest-\(UUID().uuidString)")
        self.tempDir = dir
        self.store = try ClipStore(directory: dir, maxItems: 100)
    }

    @Test func storesSubtypeForColorClip() throws {
        try store.insertText("#FF5733")
        let items = try store.fetch()
        #expect(items[0].subtype == .color)
        #expect(items[0].card == .color)
    }

    @Test func storesSubtypeForURLClip() throws {
        try store.insertText("https://example.com")
        let items = try store.fetch()
        #expect(items[0].subtype == .url)
        #expect(items[0].card == .url)
    }

    @Test func plainTextHasNilSubtype() throws {
        try store.insertText("just some text")
        let items = try store.fetch()
        #expect(items[0].subtype == nil)
        #expect(items[0].card == .text)
    }

    @Test func imageAndFileHaveNilSubtype() throws {
        try store.insertFileURLs([URL(fileURLWithPath: "/tmp/a.txt")])
        let items = try store.fetch()
        #expect(items[0].subtype == nil)
        #expect(items[0].card == .fileURL)
    }
}

@Suite("TextSubtype — personal info (US)")
struct TextSubtypePersonalTests {
    // MARK: phone (NSDataDetector)

    @Test func detectsUSPhoneShapes() {
        #expect(TextSubtype.detect("(415) 555-1234") == .phone)
        #expect(TextSubtype.detect("415-555-1234") == .phone)
        #expect(TextSubtype.detect("+1 415-555-1234") == .phone)
    }

    @Test func ignoresPhoneSubstring() {
        // NSDataDetector returns a substring match; our wrapper requires
        // the entire string to be the phone number, so prose with a phone
        // inside still classifies as plain text.
        #expect(TextSubtype.detect("call me at 415-555-1234 ok") == nil)
    }

    // MARK: email

    @Test func detectsEmail() {
        #expect(TextSubtype.detect("john@example.com") == .email)
        #expect(TextSubtype.detect("a.b+tag@sub.example.co") == .email)
    }

    @Test func ignoresMalformedEmail() {
        #expect(TextSubtype.detect("john@") == nil)
        #expect(TextSubtype.detect("@example.com") == nil)
        #expect(TextSubtype.detect("john at example.com") == nil)
        #expect(TextSubtype.detect("john@example") == nil)
    }

    // MARK: credit card (Luhn-validated)

    @Test func detectsValidCreditCards() {
        // Common Luhn-valid test PANs.
        #expect(TextSubtype.detect("4111111111111111") == .creditCard)     // Visa test
        #expect(TextSubtype.detect("4111 1111 1111 1111") == .creditCard)
        #expect(TextSubtype.detect("4111-1111-1111-1111") == .creditCard)
        #expect(TextSubtype.detect("5500000000000004") == .creditCard)     // Mastercard test
        #expect(TextSubtype.detect("371449635398431") == .creditCard)      // Amex test (15)
    }

    @Test func rejectsNonLuhn16DigitNumbers() {
        // Order numbers, tracking IDs, random 16-digit strings — must
        // NOT classify as credit card. This is the whole point of Luhn.
        #expect(TextSubtype.detect("1234567890123456") == nil)
        #expect(TextSubtype.detect("9999888877776666") == nil)
    }

    @Test func rejectsOutOfRangeAsCreditCard() {
        // 12 and 20 digits are outside the CC length window — Luhn's job
        // is to gate the CC bucket. Whatever else they classify as (phone
        // for the 12-digit, plain text for the 20-digit) is the looser
        // detectors' call; we only assert the CC guarantee here.
        #expect(TextSubtype.detect("411111111111") != .creditCard)
        #expect(TextSubtype.detect("41111111111111111111") != .creditCard)
    }

    // MARK: SSN

    @Test func detectsSSN() {
        #expect(TextSubtype.detect("123-45-6789") == .ssn)
    }

    @Test func ignoresMalformedSSN() {
        // SSN's NNN-NN-NNNN shape is the only thing that should land in
        // the .ssn bucket. Off-shape strings may land elsewhere (phone,
        // text) but must NOT classify as SSN — we test the negative.
        #expect(TextSubtype.detect("123456789") != .ssn)
        #expect(TextSubtype.detect("123-45-678") != .ssn)
        #expect(TextSubtype.detect("12-345-6789") != .ssn)
    }

    // MARK: ordering — more specific wins

    @Test func emailDoesNotMatchAsPhoneOrCard() {
        #expect(TextSubtype.detect("a@b.co") == .email)
    }

    @Test func urlStillBeatsOthers() {
        // Pre-existing URL detection must remain dominant for URL-shaped
        // strings even after the new detectors are added.
        #expect(TextSubtype.detect("https://example.com") == .url)
    }

    // MARK: address (NSDataDetector)

    @Test func detectsUSAddress() {
        // NSDataDetector is locale-aware and ships address grammars for
        // US-style "street, city, ST ZIP" shapes. A solid v1 sample.
        #expect(TextSubtype.detect("1600 Amphitheatre Parkway, Mountain View, CA 94043") == .address)
    }

    @Test func ignoresAddressSubstringInProse() {
        // Substring rejection guard — the detector would otherwise return
        // a partial match on the address inside the sentence.
        #expect(TextSubtype.detect("their office at 1 Infinite Loop, Cupertino, CA 95014 is closed") == nil)
    }

    // MARK: command

    @Test func detectsKnownCLIVerbs() {
        #expect(TextSubtype.detect("git push origin main") == .command)
        #expect(TextSubtype.detect("npm install --save-dev typescript") == .command)
        #expect(TextSubtype.detect("docker run -it ubuntu bash") == .command)
        #expect(TextSubtype.detect("kubectl get pods -n production") == .command)
        #expect(TextSubtype.detect("brew install ripgrep") == .command)
    }

    @Test func detectsShellPromptPrefix() {
        #expect(TextSubtype.detect("$ ls -la") == .command)
        #expect(TextSubtype.detect("% rm -rf /tmp/foo") == .command)
        #expect(TextSubtype.detect("❯ swift build") == .command)
    }

    @Test func detectsScriptInvocation() {
        #expect(TextSubtype.detect("./build.sh") == .command)
        #expect(TextSubtype.detect("/usr/bin/env python3 main.py") == .command)
    }

    @Test func multilineCommandClassifiedByFirstLine() {
        let heredoc = """
        git commit -m "$(cat <<EOF
        feat: stuff
        EOF
        )"
        """
        #expect(TextSubtype.detect(heredoc) == .command)
    }

    @Test func rejectsProseEvenWithCommandWord() {
        // Plain English mentioning a verb shouldn't classify.
        #expect(TextSubtype.detect("I'll find a way to fix this") == nil)
        #expect(TextSubtype.detect("Make sure to commit before pushing.") == nil)
    }

    @Test func rejectsNonASCIIFirstLine() {
        // Shell commands are pure ASCII. Anything else — emoji, accented
        // letters, non-Latin scripts — means the clip is prose that just
        // happens to start with a whitelisted token. Guard once at the
        // detector boundary instead of script-by-script rejection lists.
        #expect(TextSubtype.detect("$ ¿qué pasa?") == nil)
        #expect(TextSubtype.detect("git 🚀 to the moon") == nil)
    }
}

@Suite("Sensitive masking helpers")
struct SensitiveMaskingTests {
    @Test func masksCreditCardKeepsLast4() {
        #expect(SensitiveMask.creditCard("4111 1111 1111 1234") == "•••• •••• •••• 1234")
        #expect(SensitiveMask.creditCard("4111111111111234") == "•••• •••• •••• 1234")
        #expect(SensitiveMask.creditCard("4111-1111-1111-1234") == "•••• •••• •••• 1234")
    }

    @Test func masksSSNKeepsLast4() {
        #expect(SensitiveMask.ssn("123-45-6789") == "•••-••-6789")
    }
}
