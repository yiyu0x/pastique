import Testing
import AppKit
import Foundation
@testable import Pastique

// MARK: - ClipStore

@Suite("ClipStore")
struct ClipStoreTests {
    let tempDir: URL
    let store: ClipStore

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastiqueTest-\(UUID().uuidString)")
        self.tempDir = dir
        self.store = try ClipStore(directory: dir, maxItems: 100)
    }

    // MARK: insertText

    @Test func insertText_storesContentAndPreview() throws {
        try store.insertText("hello world")

        let items = try store.fetch()
        #expect(items.count == 1)
        #expect(items[0].kind == .text)
        #expect(items[0].text == "hello world")
        #expect(items[0].preview == "hello world")
        #expect(items[0].useCount == 1)
    }

    @Test func insertText_previewTruncatesAndStripsNewlines() throws {
        let long = String(repeating: "A", count: 100) + "\nmore"
        try store.insertText(long)

        let items = try store.fetch()
        #expect(items[0].preview.count == 80)
        #expect(!items[0].preview.contains("\n"))
    }

    @Test func insertText_skipsWhitespaceOnlyClips() throws {
        try store.insertText("   ")
        try store.insertText("\n\n\n")
        try store.insertText("\t  \t")
        try store.insertText("")
        let items = try store.fetch()
        #expect(items.isEmpty, "whitespace-only text must not be saved")
    }

    // MARK: dedup + use_count

    @Test func insertText_dedupCarriesAndIncrementsUseCount() throws {
        try store.insertText("foo")
        try store.insertText("bar")
        try store.insertText("foo")     // re-copy

        let items = try store.fetch()
        #expect(items.count == 2, "duplicate text should collapse to one row")
        #expect(items[0].text == "foo", "re-copied item floats to top")
        #expect(items[0].useCount == 2, "use_count should increment on re-copy")
        #expect(items[1].text == "bar")
        #expect(items[1].useCount == 1)
    }

    @Test func insertText_dedupAcrossMultipleCopies() throws {
        for _ in 0..<5 { try store.insertText("repeated") }

        let items = try store.fetch()
        #expect(items.count == 1)
        #expect(items[0].useCount == 5)
    }

    // MARK: recordUse

    @Test func recordUse_incrementsCount() throws {
        try store.insertText("clip-a")
        let id = try store.fetch()[0].id

        store.recordUse(id: id)
        store.recordUse(id: id)

        let items = try store.fetch()
        #expect(items[0].useCount == 3, "1 (insert) + 2 (recordUse)")
    }

    @Test func recopying_AfterAnotherClip_BubblesToTop() throws {
        // User's exact scenario: copy a, copy b, copy a. The most recent
        // re-copy must end up at the top under recency sort.
        try store.insertText("a")
        Thread.sleep(forTimeInterval: 0.02)
        try store.insertText("b")
        Thread.sleep(forTimeInterval: 0.02)
        try store.insertText("a")

        let items = try store.fetch(sortBy: .recency)
        #expect(items.map(\.text) == ["a", "b"],
                "re-copied 'a' must sit above 'b' even though 'b' was inserted in between")
    }

    @Test func recordUse_doesNotPinClipAboveLaterInserts() throws {
        // Regression: an older recordUse() stored Date() as a TEXT string,
        // and TEXT sorts above REAL in SQLite — so a clip picked via Enter
        // would stick to the top forever, even if newer items were copied
        // afterwards. recordUse() must write a Double timestamp so it
        // sorts on the same axis as insertText.
        try store.insertText("a")
        Thread.sleep(forTimeInterval: 0.02)
        try store.insertText("b")
        let aID = try store.fetch().first(where: { $0.text == "a" })!.id

        // Simulate: user picks "a" via the picker.
        Thread.sleep(forTimeInterval: 0.02)
        store.recordUse(id: aID)

        // Then copies a brand-new "c" from somewhere.
        Thread.sleep(forTimeInterval: 0.02)
        try store.insertText("c")

        let items = try store.fetch(sortBy: .recency)
        #expect(items.map(\.text) == ["c", "a", "b"],
                "freshly-copied 'c' must rank above 'a' (last picked); 'b' is oldest")
    }

    @Test func recordUse_bubblesItemToTopUnderRecencySort() throws {
        try store.insertText("first")
        Thread.sleep(forTimeInterval: 0.02)
        try store.insertText("second")
        Thread.sleep(forTimeInterval: 0.02)
        try store.insertText("third")

        var items = try store.fetch(sortBy: .recency)
        #expect(items.map(\.text) == ["third", "second", "first"])

        // Pick the oldest — recordUse must refresh created_at so the
        // chosen item bubbles to the top under recency sort.
        let oldestID = items.last!.id
        Thread.sleep(forTimeInterval: 0.02)
        store.recordUse(id: oldestID)

        items = try store.fetch(sortBy: .recency)
        #expect(items.map(\.text) == ["first", "third", "second"])
    }

    // MARK: sort

    @Test func sort_recencyByDefault() throws {
        try store.insertText("oldest")
        try store.insertText("middle")
        try store.insertText("newest")

        let items = try store.fetch(sortBy: .recency)
        #expect(items.map(\.text) == ["newest", "middle", "oldest"])
    }

    @Test func sort_frequencyPutsMostUsedFirst() throws {
        try store.insertText("once")
        try store.insertText("twice")
        try store.insertText("twice")
        try store.insertText("thrice")
        try store.insertText("thrice")
        try store.insertText("thrice")

        let items = try store.fetch(sortBy: .frequency)
        #expect(items.map(\.text) == ["thrice", "twice", "once"])
        #expect(items.map(\.useCount) == [3, 2, 1])
    }

    @Test func sort_frequencyTieBreakerIsRecency() throws {
        try store.insertText("alpha")
        Thread.sleep(forTimeInterval: 0.01)
        try store.insertText("beta")
        Thread.sleep(forTimeInterval: 0.01)
        try store.insertText("gamma")

        let items = try store.fetch(sortBy: .frequency)
        #expect(items.map(\.text) == ["gamma", "beta", "alpha"])
    }

    // MARK: insertImage

    @Test func insertImage_writesFileAndThumbnailBlob() throws {
        let png = makeTestPNG(color: .red)
        try store.insertImage(pngData: png)

        let items = try store.fetch()
        #expect(items.count == 1)
        #expect(items[0].kind == .image)

        let imagePath = try #require(items[0].imagePath)
        let thumb = try #require(items[0].thumbnail)
        #expect(thumb.count > 0)

        let onDisk = store.imagesDir.appendingPathComponent(imagePath)
        #expect(FileManager.default.fileExists(atPath: onDisk.path))

        let reloaded = store.loadImage(imagePath)
        #expect(reloaded == png)
    }

    // MARK: insertFileURLs

    @Test func insertFileURLs_singleFile() throws {
        let url = URL(fileURLWithPath: "/tmp/example.pdf")
        try store.insertFileURLs([url])

        let items = try store.fetch()
        #expect(items[0].kind == .fileURL)
        #expect(items[0].preview == "example.pdf")
        #expect(items[0].fileURLs == [url.absoluteString])
    }

    @Test func insertFileURLs_multipleFiles() throws {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.txt"),
            URL(fileURLWithPath: "/tmp/b.txt"),
            URL(fileURLWithPath: "/tmp/c.txt"),
        ]
        try store.insertFileURLs(urls)

        let items = try store.fetch()
        #expect(items[0].fileURLs?.count == 3)
        #expect(items[0].preview.contains("3 files"))
    }

    @Test func insertFileURLs_dedupCarriesUseCount() throws {
        let url = URL(fileURLWithPath: "/tmp/dup.txt")
        try store.insertFileURLs([url])
        try store.insertFileURLs([url])
        try store.insertFileURLs([url])

        let items = try store.fetch()
        #expect(items.count == 1)
        #expect(items[0].useCount == 3)
    }

    // MARK: rich-text payloads

    @Test func richPayloads_storedAndFetched() throws {
        let rtf = Data("{\\rtf1 hello}".utf8)
        let html = Data("<b>hello</b>".utf8)

        try store.insertText("hello", extraPayloads: [
            (uti: "public.rtf",  data: rtf),
            (uti: "public.html", data: html),
        ])

        let id = try store.fetch()[0].id
        let payloads = store.payloads(for: id)
        let map = Dictionary(uniqueKeysWithValues: payloads.map { ($0.uti, $0.data) })

        #expect(map["public.rtf"] == rtf)
        #expect(map["public.html"] == html)
    }

    @Test func richPayloads_cascadeDeletedWhenClipDedupReplaced() throws {
        try store.insertText("greeting", extraPayloads: [
            (uti: "public.rtf",  data: Data("OLD".utf8)),
            (uti: "public.html", data: Data("<b>OLD</b>".utf8)),
        ])

        // Re-insert same text with different payloads — FK CASCADE wipes old.
        try store.insertText("greeting", extraPayloads: [
            (uti: "public.rtf", data: Data("NEW".utf8)),
        ])

        let id = try store.fetch()[0].id
        let payloads = store.payloads(for: id)
        #expect(payloads.count == 1, "old payloads must be cascade-deleted")
        #expect(payloads[0].uti == "public.rtf")
        #expect(payloads[0].data == Data("NEW".utf8))
    }

    @Test func richPayloads_emptyForPlainClip() throws {
        try store.insertText("plain text only")
        let id = try store.fetch()[0].id
        #expect(store.payloads(for: id).isEmpty)
    }

    // MARK: deleteAll

    @Test func deleteAll_clearsRowsAndImages() throws {
        try store.insertText("a")
        try store.insertImage(pngData: makeTestPNG(color: .red))
        try store.insertFileURLs([URL(fileURLWithPath: "/tmp/x")])
        #expect(try store.fetch().count == 3)

        try store.deleteAll()

        #expect(try store.fetch().count == 0)
        let contents = try FileManager.default.contentsOfDirectory(
            at: store.imagesDir, includingPropertiesForKeys: nil)
        #expect(contents.isEmpty, "image files must be wiped")
    }

    // MARK: purgeOrphans

    @Test func purgeOrphans_removesFilesNotReferencedByDB() throws {
        let orphan = store.imagesDir.appendingPathComponent("orphan.png")
        try Data([0xFF]).write(to: orphan)
        #expect(FileManager.default.fileExists(atPath: orphan.path))

        try store.purgeOrphanImages()

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }
}

// MARK: - Trim (needs custom maxItems, so separate Suite)

@Suite("ClipStore trim")
struct ClipStoreTrimTests {
    let tempDir: URL
    let store: ClipStore

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastiqueTest-\(UUID().uuidString)")
        self.tempDir = dir
        self.store = try ClipStore(directory: dir, maxItems: 5)
    }

    @Test func trim_keepsOnlyMaxItems() throws {
        for i in 0..<10 {
            try store.insertText("clip-\(i)")
        }
        let items = try store.fetch()
        #expect(items.count == 5)
        #expect(items.map(\.text) == ["clip-9", "clip-8", "clip-7", "clip-6", "clip-5"])
    }

    @Test func trim_unlinksImageFilesOfDroppedClips() throws {
        // maxItems is 5 here; insert 6 images so the oldest is trimmed.
        var firstURL: URL?
        for i in 0..<6 {
            try store.insertImage(pngData: makeTestPNG(color: i == 0 ? .red : .green))
            if i == 0 {
                let path = try #require(try store.fetch().first?.imagePath)
                firstURL = store.imagesDir.appendingPathComponent(path)
            }
        }
        let onDisk = try #require(firstURL)
        #expect(!FileManager.default.fileExists(atPath: onDisk.path),
                "oldest image file should have been unlinked by trim")
    }
}

// MARK: - Concealed-type filter

@Suite("ClipboardWatcher privacy filter")
struct ClipboardWatcherFilterTests {
    @Test func skipsConcealedType() {
        #expect(ClipboardWatcher.shouldSkip(pasteboardTypes: [
            "org.nspasteboard.ConcealedType",
            "public.utf8-plain-text",
        ]))
    }

    @Test func skipsTransient() {
        #expect(ClipboardWatcher.shouldSkip(pasteboardTypes: [
            "org.nspasteboard.TransientType",
        ]))
    }

    @Test func skipsAutoGenerated() {
        #expect(ClipboardWatcher.shouldSkip(pasteboardTypes: [
            "org.nspasteboard.AutoGeneratedType",
        ]))
    }

    @Test func skipsOnePasswordType() {
        #expect(ClipboardWatcher.shouldSkip(pasteboardTypes: [
            "com.agilebits.onepassword",
        ]))
    }

    @Test func doesNotSkipPlainText() {
        #expect(!ClipboardWatcher.shouldSkip(pasteboardTypes: [
            "public.utf8-plain-text",
        ]))
    }

    @Test func doesNotSkipRichTextWithoutConcealedMarker() {
        #expect(!ClipboardWatcher.shouldSkip(pasteboardTypes: [
            "public.utf8-plain-text", "public.rtf", "public.html",
        ]))
    }

    @Test func doesNotSkipEmpty() {
        #expect(!ClipboardWatcher.shouldSkip(pasteboardTypes: []))
    }
}

// MARK: - Enums

@Suite("Settings enums")
struct SettingsTests {
    @Test func sortOrderRawValues() {
        #expect(SortOrder.recency.rawValue == "recency")
        #expect(SortOrder.frequency.rawValue == "frequency")
        #expect(SortOrder(rawValue: "recency") == .recency)
        #expect(SortOrder(rawValue: "frequency") == .frequency)
        #expect(SortOrder(rawValue: "garbage") == nil)
    }

    @Test func viewStyleRawValues() {
        #expect(ViewStyle.compact.rawValue == "compact")
        #expect(ViewStyle.detailed.rawValue == "detailed")
        #expect(ViewStyle(rawValue: "compact") == .compact)
        #expect(ViewStyle(rawValue: "detailed") == .detailed)
        #expect(ViewStyle(rawValue: "garbage") == nil)
    }

    @Test func clipKindRawValues() {
        #expect(ClipKind.text.rawValue == "text")
        #expect(ClipKind.image.rawValue == "image")
        #expect(ClipKind.fileURL.rawValue == "fileURL")
    }
}

// MARK: - Helpers

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
