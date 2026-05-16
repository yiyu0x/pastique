import Testing
import AppKit
import Foundation
@testable import Pastique

// PickerViewModel is @MainActor — the suite + tests must be too.

@MainActor
@Suite("PickerViewModel — search & sort")
struct PickerViewModelTests {
    let tempDir: URL
    let store: ClipStore
    let vm: PickerViewModel

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastiqueTest-\(UUID().uuidString)")
        self.tempDir = dir
        self.store = try ClipStore(directory: dir, maxItems: 100)
        self.vm = PickerViewModel(store: store)
    }

    // MARK: - Text filter

    @Test func filter_matchesTextSubstringCaseInsensitive() throws {
        try store.insertText("Hello World")
        try store.insertText("foobar")
        try store.insertText("hello swift")
        vm.reload()

        vm.setQuery("hello")
        #expect(vm.items.count == 2)
        let texts = vm.items.compactMap(\.text)
        #expect(texts.contains("Hello World"))
        #expect(texts.contains("hello swift"))
    }

    @Test func filter_emptyQueryReturnsAll() throws {
        try store.insertText("a")
        try store.insertText("b")
        vm.reload()

        vm.setQuery("")
        #expect(vm.items.count == 2)
    }

    @Test func filter_noMatchProducesEmptyList() throws {
        try store.insertText("foobar")
        vm.reload()

        vm.setQuery("xyz-not-present")
        #expect(vm.items.isEmpty)
    }

    // MARK: - File filter

    @Test func filter_matchesByFilename() throws {
        try store.insertFileURLs([URL(fileURLWithPath: "/tmp/report.pdf")])
        try store.insertFileURLs([URL(fileURLWithPath: "/tmp/other.txt")])
        vm.reload()

        vm.setQuery("report")
        #expect(vm.items.count == 1)
        #expect(vm.items[0].kind == .fileURL)
    }

    @Test func filter_matchesByParentPath() throws {
        try store.insertFileURLs([URL(fileURLWithPath: "/Users/test/Documents/a.pdf")])
        try store.insertFileURLs([URL(fileURLWithPath: "/Users/test/Downloads/b.pdf")])
        vm.reload()

        vm.setQuery("documents")
        #expect(vm.items.count == 1)
    }

    @Test func filter_matchesByAnyFileInMultiSelect() throws {
        try store.insertFileURLs([
            URL(fileURLWithPath: "/tmp/cat.png"),
            URL(fileURLWithPath: "/tmp/dog.png"),
        ])
        try store.insertFileURLs([URL(fileURLWithPath: "/tmp/bird.png")])
        vm.reload()

        vm.setQuery("dog")
        #expect(vm.items.count == 1, "match should hit the second file in a multi-file clip")
    }

    // MARK: - Image filter

    @Test func filter_imagesAreNeverMatched() throws {
        try store.insertImage(pngData: makeTestPNG())
        try store.insertText("any text")
        vm.reload()

        vm.setQuery("any")
        #expect(vm.items.count == 1)
        #expect(vm.items[0].kind == .text)
    }

    // MARK: - Ordering & selection

    @Test func filter_preservesSortOrder() throws {
        try store.insertText("alpha match")
        Thread.sleep(forTimeInterval: 0.01)
        try store.insertText("beta match")
        Thread.sleep(forTimeInterval: 0.01)
        try store.insertText("gamma other")
        vm.reload()

        vm.setQuery("match")
        // Recency: newer first → beta before alpha.
        #expect(vm.items.map(\.text) == ["beta match", "alpha match"])
    }

    @Test func filter_resetsSelectedIndex() throws {
        try store.insertText("a")
        try store.insertText("b")
        try store.insertText("c")
        vm.reload()

        vm.moveDown(); vm.moveDown()
        #expect(vm.selectedIndex == 2)

        vm.setQuery("a")
        #expect(vm.selectedIndex == 0)
    }

    // MARK: - searchActive lifecycle

    @Test func searchActive_falseOnInitialReload() throws {
        try store.insertText("a")
        vm.reload()
        #expect(vm.searchActive == false)
        #expect(vm.query == "")
    }

    @Test func searchActive_setQueryWithCharsActivates() throws {
        vm.reload()
        vm.setQuery("a")
        #expect(vm.searchActive == true)
    }

    @Test func searchActive_activateSearchTurnsOnWithoutText() throws {
        vm.reload()
        vm.activateSearch()
        #expect(vm.searchActive == true)
        #expect(vm.query == "")
    }

    @Test func searchActive_clearQueryDeactivates() throws {
        vm.reload()
        vm.setQuery("abc")
        #expect(vm.searchActive == true)

        vm.clearQuery()
        #expect(vm.query == "")
        #expect(vm.searchActive == false)
    }

    @Test func searchActive_reloadResetsBoth() throws {
        vm.reload()
        vm.setQuery("hello")
        vm.reload()
        #expect(vm.query == "")
        #expect(vm.searchActive == false)
    }

    // MARK: - Sort toggle

    @Test func toggleSortOrder_flipsBetweenModes() throws {
        vm.reload()
        let initial = vm.sortOrder
        vm.toggleSortOrder()
        #expect(vm.sortOrder != initial)
        vm.toggleSortOrder()
        #expect(vm.sortOrder == initial)
    }

    @Test func toggleSortOrder_persistsToSettings() throws {
        vm.reload()
        vm.setSortOrder(.recency)
        vm.toggleSortOrder()
        #expect(Settings.sortOrder == .frequency)
        // Restore so other tests aren't disturbed (Settings uses UserDefaults).
        vm.setSortOrder(.recency)
    }

    // MARK: - KindFilter

    @Test func kindFilter_defaultsToAll() throws {
        try store.insertText("a")
        vm.reload()
        #expect(vm.kindFilter == .all)
    }

    @Test func kindFilter_narrowsToSingleCard() throws {
        try store.insertText("plain text")
        try store.insertText("https://example.com")
        try store.insertFileURLs([URL(fileURLWithPath: "/tmp/a.pdf")])
        vm.reload()

        vm.setKindFilter(.link)
        #expect(vm.items.count == 1)
        #expect(vm.items[0].card == .url)

        vm.setKindFilter(.file)
        #expect(vm.items.count == 1)
        #expect(vm.items[0].card == .fileURL)

        vm.setKindFilter(.text)
        #expect(vm.items.count == 1)
        #expect(vm.items[0].card == .text)
    }

    @Test func kindFilter_combinesWithTextQuery() throws {
        try store.insertText("https://hello.com")
        try store.insertText("https://other.com")
        try store.insertText("hello world plain")
        vm.reload()

        vm.setKindFilter(.link)
        vm.setQuery("hello")
        #expect(vm.items.count == 1)
        #expect(vm.items[0].card == .url)
        #expect(vm.items[0].text == "https://hello.com")
    }

    @Test func availableFilters_excludesEmptyBuckets() throws {
        try store.insertText("plain text")
        try store.insertFileURLs([URL(fileURLWithPath: "/tmp/a.pdf")])
        vm.reload()

        // .all is always present; text + file are present; link/image/color are not.
        #expect(vm.availableFilters.contains(.all))
        #expect(vm.availableFilters.contains(.text))
        #expect(vm.availableFilters.contains(.file))
        #expect(!vm.availableFilters.contains(.image))
        #expect(!vm.availableFilters.contains(.link))
        #expect(!vm.availableFilters.contains(.color))
        #expect(!vm.availableFilters.contains(.personal))
    }

    // MARK: - Personal (PII) rollup

    @Test func personalFilter_rollsUpAllDetectedKinds() throws {
        try store.insertText("(415) 555-1234")            // phone
        try store.insertText("john@example.com")          // email
        try store.insertText("4111 1111 1111 1111")       // credit card
        try store.insertText("123-45-6789")               // ssn
        try store.insertText("plain text")                // not personal
        vm.reload()

        // One chip covers all four — chip row stays bounded.
        #expect(vm.availableFilters.contains(.personal))
        vm.setKindFilter(.personal)
        #expect(vm.items.count == 4)
        let cards = Set(vm.items.map { $0.card })
        #expect(cards == [.phone, .email, .creditCard, .ssn])
    }

    @Test func personalFilter_absentWhenNoPersonalClips() throws {
        try store.insertText("plain text")
        try store.insertText("https://example.com")
        vm.reload()
        #expect(!vm.availableFilters.contains(.personal),
                "Empty Personal bucket must be hidden — empty chips clutter the row")
    }

    @Test func personalFilter_combinesWithSearch() throws {
        try store.insertText("alice@example.com")
        try store.insertText("bob@example.com")
        try store.insertText("(415) 555-1234")
        vm.reload()
        vm.setKindFilter(.personal)
        vm.setQuery("alice")
        #expect(vm.items.count == 1)
        #expect(vm.items[0].text == "alice@example.com")
    }

    @Test func commandFilter_isSeparateFromPersonal() throws {
        try store.insertText("git push origin main")
        try store.insertText("docker run -it ubuntu bash")
        try store.insertText("john@example.com")
        vm.reload()
        // Command is its OWN chip, not lumped under Personal — devs don't
        // want phone numbers and shell commands sharing a filter.
        #expect(vm.availableFilters.contains(.command))
        #expect(vm.availableFilters.contains(.personal))
        vm.setKindFilter(.command)
        #expect(vm.items.count == 2)
        #expect(vm.items.allSatisfy { $0.card == .command })
    }

    @Test func personalFilter_includesAddress() throws {
        try store.insertText("1600 Amphitheatre Parkway, Mountain View, CA 94043")
        try store.insertText("john@example.com")
        vm.reload()
        vm.setKindFilter(.personal)
        // Address rolls up under Personal alongside email/phone/CC/SSN.
        #expect(vm.items.count == 2)
        let cards = Set(vm.items.map { $0.card })
        #expect(cards.contains(.address))
        #expect(cards.contains(.email))
    }

    @Test func availableFilters_preservesCanonicalOrder() throws {
        try store.insertFileURLs([URL(fileURLWithPath: "/tmp/a.pdf")])
        try store.insertText("https://example.com")
        try store.insertText("plain")
        vm.reload()

        // Canonical order: all, text, link, image, file, color — regardless
        // of insertion order. Drives chip layout stability.
        #expect(vm.availableFilters == [.all, .text, .link, .file])
    }

    @Test func cycleKindFilter_skipsEmptyBuckets() throws {
        try store.insertText("plain")
        try store.insertFileURLs([URL(fileURLWithPath: "/tmp/a.pdf")])
        vm.reload()

        // available = [.all, .text, .file]
        #expect(vm.kindFilter == .all)
        vm.cycleKindFilter(forward: true)
        #expect(vm.kindFilter == .text)
        vm.cycleKindFilter(forward: true)
        #expect(vm.kindFilter == .file)
        vm.cycleKindFilter(forward: true)
        #expect(vm.kindFilter == .all, "wraps back to the first available")
    }

    @Test func cycleKindFilter_backwardWraps() throws {
        try store.insertText("plain")
        try store.insertFileURLs([URL(fileURLWithPath: "/tmp/a.pdf")])
        vm.reload()

        vm.cycleKindFilter(forward: false)
        #expect(vm.kindFilter == .file, "backward from .all wraps to last available")
    }

    @Test func cycleKindFilter_noOpWhenOnlyAllAvailable() throws {
        vm.reload() // empty store → availableFilters = [.all]
        vm.cycleKindFilter(forward: true)
        #expect(vm.kindFilter == .all)
        vm.cycleKindFilter(forward: false)
        #expect(vm.kindFilter == .all)
    }

    @Test func kindFilter_reloadResetsToAll() throws {
        try store.insertText("plain")
        try store.insertText("https://example.com")
        vm.reload()

        vm.setKindFilter(.link)
        #expect(vm.kindFilter == .link)

        vm.reload()
        #expect(vm.kindFilter == .all, "filter is a session intent, not a setting")
    }

    @Test func kindFilter_resetsSelectedIndex() throws {
        try store.insertText("plain a")
        try store.insertText("plain b")
        try store.insertText("https://example.com")
        vm.reload()

        vm.moveDown(); vm.moveDown()
        #expect(vm.selectedIndex == 2)

        vm.setKindFilter(.link)
        #expect(vm.selectedIndex == 0)
    }

    // MARK: - Arrow-key routing

    @Test func arrowKey_emptyQuery_cyclesForward() throws {
        try store.insertText("plain")
        try store.insertFileURLs([URL(fileURLWithPath: "/tmp/a.pdf")])
        vm.reload()
        // available = [.all, .text, .file]
        #expect(vm.handleArrowKey(left: false) == true)
        #expect(vm.kindFilter == .text)
        #expect(vm.handleArrowKey(left: false) == true)
        #expect(vm.kindFilter == .file)
    }

    @Test func arrowKey_emptyQuery_cyclesBackward() throws {
        try store.insertText("plain")
        try store.insertFileURLs([URL(fileURLWithPath: "/tmp/a.pdf")])
        vm.reload()
        #expect(vm.handleArrowKey(left: true) == true)
        #expect(vm.kindFilter == .file, "left from .all wraps to last available")
    }

    @Test func arrowKey_withQuery_yieldsToTextEditing() throws {
        try store.insertText("plain")
        try store.insertFileURLs([URL(fileURLWithPath: "/tmp/a.pdf")])
        vm.reload()
        vm.setQuery("p")
        let filterBefore = vm.kindFilter
        #expect(vm.handleArrowKey(left: false) == false, "must yield so caret moves")
        #expect(vm.handleArrowKey(left: true)  == false)
        #expect(vm.kindFilter == filterBefore, "filter must not change while editing")
    }

    @Test func arrowKey_consumesEvenWhenNoOp() throws {
        // Only .all available — cycle is a no-op, but we still consume the
        // key so AppKit doesn't bell or scroll some hidden caret.
        vm.reload()
        #expect(vm.handleArrowKey(left: false) == true)
        #expect(vm.kindFilter == .all)
    }

    @Test func toggleSortOrder_actuallyReorders() throws {
        try store.insertText("once")
        try store.insertText("many"); store.recordUse(id: try store.fetch()[0].id)
        store.recordUse(id: try store.fetch()[0].id)
        vm.setSortOrder(.recency)

        // Recency order shouldn't put "many" on top necessarily — it depends
        // on whether recordUse refreshed created_at. We just verify the toggle
        // changes the order (or at least the sortOrder).
        let recencyOrder = vm.items.map(\.id)
        vm.toggleSortOrder()
        #expect(vm.sortOrder == .frequency)
        let frequencyOrder = vm.items.map(\.id)
        // "many" has use_count > "once" → must be first under frequency.
        let manyID = try #require(vm.items.first { $0.text == "many" }?.id)
        #expect(frequencyOrder.first == manyID)
        // Don't compare element-wise to recencyOrder since recordUse also
        // bumps created_at; just sanity-check both arrays contain same set.
        #expect(Set(recencyOrder) == Set(frequencyOrder))
    }
}

// MARK: - Helpers (duplicated from ClipStoreTests to keep the suites independent)

private func makeTestPNG(width: Int = 32, height: Int = 32, color: NSColor = .red) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
