import Foundation
import AppKit
import GRDB

// Storage layout
// ~/Library/Application Support/Pastique/
//   clips.db                 SQLite (GRDB DatabasePool)
//   images/{uuid}.png        full-resolution image originals
//
// clips table holds metadata + text + thumbnail blob (~5KB each).
// Image originals live outside the DB so the file is cheap to read for
// the picker (thumbnails only) and only the chosen image is loaded.

final class ClipStore {
    let pool: DatabasePool
    let imagesDir: URL
    let maxItems: Int

    /// Production path: derives location from Application Support.
    /// Tests pass `directory:` to use a sandboxed temp dir, and may shrink
    /// `maxItems` to exercise trim logic without inserting 100+ rows.
    init(directory: URL? = nil, maxItems: Int = 500) throws {
        self.maxItems = maxItems
        let fm = FileManager.default

        let pastiqueDir: URL
        if let directory {
            pastiqueDir = directory
        } else {
            let appSupport = try fm.url(for: .applicationSupportDirectory,
                                        in: .userDomainMask,
                                        appropriateFor: nil, create: true)
            pastiqueDir = appSupport.appendingPathComponent("Pastique", isDirectory: true)
        }
        try fm.createDirectory(at: pastiqueDir, withIntermediateDirectories: true)
        self.imagesDir = pastiqueDir.appendingPathComponent("images", isDirectory: true)
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let dbURL = pastiqueDir.appendingPathComponent("clips.db")
        self.pool = try DatabasePool(path: dbURL.path)
        try migrate()
        try purgeOrphanImages()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_clips") { db in
            try db.execute(sql: """
                CREATE TABLE clips (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    preview TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    text_content TEXT,
                    image_path TEXT,
                    thumbnail BLOB,
                    file_urls TEXT
                );
            """)
            try db.execute(sql: "CREATE INDEX idx_clips_created_at ON clips(created_at DESC);")
        }
        // v2: track how often each clip is used (copied again or pasted via picker).
        // Feeds the "Frequency" sort order.
        migrator.registerMigration("v2_use_count") { db in
            try db.execute(sql: "ALTER TABLE clips ADD COLUMN use_count INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "CREATE INDEX idx_clips_use_count ON clips(use_count DESC, created_at DESC);")
        }
        // v3: extra UTI representations (RTF, HTML, etc.) for rich-text mode.
        // Rows are written only when Settings.richMode was on at copy time.
        // CASCADE so dedup-deletes of a clip wipe its payloads with it.
        migrator.registerMigration("v3_payloads") { db in
            try db.execute(sql: """
                CREATE TABLE clip_payloads (
                    clip_id INTEGER NOT NULL,
                    uti TEXT NOT NULL,
                    data BLOB NOT NULL,
                    PRIMARY KEY (clip_id, uti),
                    FOREIGN KEY (clip_id) REFERENCES clips(id) ON DELETE CASCADE
                );
            """)
        }
        // v4: refine .text clips into known shapes (color, url, …). New
        // copies set subtype at insert time; this migration backfills the
        // existing history so old rows render with the same specialized
        // cards as new ones.
        migrator.registerMigration("v4_subtype") { db in
            try db.execute(sql: "ALTER TABLE clips ADD COLUMN subtype TEXT")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, text_content FROM clips WHERE kind = ? AND text_content IS NOT NULL",
                arguments: [ClipKind.text.rawValue]
            )
            for row in rows {
                let id: Int64 = row["id"]
                guard let s: String = row["text_content"],
                      let sub = TextSubtype.detect(s) else { continue }
                try db.execute(
                    sql: "UPDATE clips SET subtype = ? WHERE id = ?",
                    arguments: [sub.rawValue, id]
                )
            }
        }
        // v5: heal a long-standing data corruption — earlier builds of
        // recordUse() passed a `Date` value directly to GRDB, which encoded
        // it as a TEXT string in SQLite. The created_at column was REAL,
        // but SQLite's dynamic typing stored it as TEXT anyway. Mixed
        // TEXT/REAL in the same column makes ORDER BY ... DESC weird:
        // TEXT-typed values sort *above* every REAL-typed value, regardless
        // of actual time. So a single Enter-pick would pin a clip to the
        // top forever, and re-copying other items couldn't displace it.
        // Convert any leftover TEXT rows back to Doubles via SQLite's
        // julianday conversion.
        migrator.registerMigration("v5_normalize_dates") { db in
            try db.execute(sql: """
                UPDATE clips
                SET created_at = (julianday(created_at) - 2440587.5) * 86400.0
                WHERE typeof(created_at) = 'text'
            """)
        }
        // v6: backfill personal-info subtypes (phone, email, credit card,
        // SSN) on existing text rows whose subtype is still NULL. Only
        // touches NULL rows — never overwrites an existing color/url
        // classification.
        migrator.registerMigration("v6_personal_subtypes") { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, text_content FROM clips WHERE kind = ? AND subtype IS NULL AND text_content IS NOT NULL",
                arguments: [ClipKind.text.rawValue]
            )
            for row in rows {
                let id: Int64 = row["id"]
                guard let s: String = row["text_content"],
                      let sub = TextSubtype.detect(s) else { continue }
                try db.execute(
                    sql: "UPDATE clips SET subtype = ? WHERE id = ?",
                    arguments: [sub.rawValue, id]
                )
            }
        }
        try migrator.migrate(pool)
    }

    // MARK: - Insert

    /// Insert (or dedup-refresh) a text clip. When `extraPayloads` is
    /// non-empty (rich-mode capture), the additional UTI representations
    /// are stored alongside the plain text and replayed on paste-back.
    func insertText(_ s: String, extraPayloads: [(uti: String, data: Data)] = []) throws {
        let preview = String(s.prefix(80))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        // Whitespace-only clips have nothing the user could ever want to
        // paste back — skip the insert entirely instead of saving an
        // "(empty)" row that just clutters the history.
        if preview.isEmpty { return }
        _ = try pool.write { db in
            // Dedup: copying the same snippet again should not create a new
            // row, it should surface the existing one with a freshened
            // timestamp and an incremented use_count.
            let priorCount = try Int.fetchOne(
                db,
                sql: "SELECT use_count FROM clips WHERE kind = ? AND text_content = ? ORDER BY use_count DESC LIMIT 1",
                arguments: [ClipKind.text.rawValue, s]
            ) ?? 0
            try db.execute(
                sql: "DELETE FROM clips WHERE kind = ? AND text_content = ?",
                arguments: [ClipKind.text.rawValue, s]
            )
            var row = ClipRow(
                id: nil,
                kind: ClipKind.text.rawValue,
                preview: preview,
                created_at: Date().timeIntervalSince1970,
                text_content: s,
                image_path: nil,
                thumbnail: nil,
                file_urls: nil,
                use_count: priorCount + 1,
                subtype: TextSubtype.detect(s)?.rawValue
            )
            try row.insert(db)
            if let newID = row.id {
                for p in extraPayloads {
                    var payload = ClipPayloadRow(clip_id: newID, uti: p.uti, data: p.data)
                    try payload.insert(db)
                }
            }
            try self.trim(db: db)
        }
    }

    /// Returns extra UTI payloads (RTF, HTML, etc.) attached to a clip,
    /// empty for clips captured without rich mode or for non-text kinds.
    func payloads(for clipID: Int64) -> [(uti: String, data: Data)] {
        (try? pool.read { db in
            try ClipPayloadRow
                .filter(Column("clip_id") == clipID)
                .fetchAll(db)
                .map { ($0.uti, $0.data) }
        }) ?? []
    }

    func insertImage(pngData: Data) throws {
        guard let image = NSImage(data: pngData) else { return }
        let thumbnail = image.pngThumbnail(maxDim: 128)
        let size = image.size

        let filename = "\(UUID().uuidString).png"
        let onDisk = imagesDir.appendingPathComponent(filename)
        try pngData.write(to: onDisk, options: .atomic)

        let preview = "📷 \(Int(size.width))×\(Int(size.height))"
        _ = try pool.write { db in
            var row = ClipRow(
                id: nil,
                kind: ClipKind.image.rawValue,
                preview: preview,
                created_at: Date().timeIntervalSince1970,
                text_content: nil,
                image_path: filename,
                thumbnail: thumbnail,
                file_urls: nil,
                use_count: 1,
                subtype: nil
            )
            try row.insert(db)
            try self.trim(db: db)
        }
    }

    func insertFileURLs(_ urls: [URL]) throws {
        let strings = urls.map { $0.absoluteString }
        let preview: String
        if urls.count == 1 {
            preview = urls[0].lastPathComponent
        } else {
            preview = "\(urls.count) files: \(urls[0].lastPathComponent), ..."
        }
        let jsonData = try JSONEncoder().encode(strings)
        let jsonStr = String(data: jsonData, encoding: .utf8)

        _ = try pool.write { db in
            // Dedup: same exact file selection floats to top, use_count bumps.
            var priorCount = 0
            if let jsonStr {
                priorCount = try Int.fetchOne(
                    db,
                    sql: "SELECT use_count FROM clips WHERE kind = ? AND file_urls = ? ORDER BY use_count DESC LIMIT 1",
                    arguments: [ClipKind.fileURL.rawValue, jsonStr]
                ) ?? 0
                try db.execute(
                    sql: "DELETE FROM clips WHERE kind = ? AND file_urls = ?",
                    arguments: [ClipKind.fileURL.rawValue, jsonStr]
                )
            }
            var row = ClipRow(
                id: nil,
                kind: ClipKind.fileURL.rawValue,
                preview: preview,
                created_at: Date().timeIntervalSince1970,
                text_content: nil,
                image_path: nil,
                thumbnail: nil,
                file_urls: jsonStr,
                use_count: priorCount + 1,
                subtype: nil
            )
            try row.insert(db)
            try self.trim(db: db)
        }
    }

    // MARK: - Use tracking

    /// Increment use_count for an existing clip. Called when the user
    /// picks an item from the picker, so frequency sort reflects real usage.
    /// Must pass `timeIntervalSince1970` (Double), NOT a bare `Date` — GRDB's
    /// default Date encoding is a TEXT-formatted string, and TEXT sorts
    /// above REAL in SQLite's ORDER BY, which would pin picked items to the
    /// top forever regardless of subsequent inserts.
    func recordUse(id: Int64) {
        _ = try? pool.write { db in
            try db.execute(
                sql: "UPDATE clips SET use_count = use_count + 1, created_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, id]
            )
        }
    }

    // MARK: - Trim & purge

    private func trim(db: Database) throws {
        let count = try ClipRow.fetchCount(db)
        guard count > maxItems else { return }
        let excess = count - maxItems
        let oldest = try ClipRow
            .order(Column("created_at").asc)
            .limit(excess)
            .fetchAll(db)
        for row in oldest {
            if let path = row.image_path {
                let url = imagesDir.appendingPathComponent(path)
                try? FileManager.default.removeItem(at: url)
            }
        }
        let ids = oldest.compactMap { $0.id }
        if !ids.isEmpty {
            try ClipRow.filter(ids.contains(Column("id"))).deleteAll(db)
        }
    }

    func purgeOrphanImages() throws {
        let referenced: Set<String> = try pool.read { db in
            let paths = try String.fetchAll(
                db,
                sql: "SELECT image_path FROM clips WHERE image_path IS NOT NULL"
            )
            return Set(paths)
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: imagesDir, includingPropertiesForKeys: nil
        )) ?? []
        for file in files {
            if !referenced.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func deleteAll() throws {
        _ = try pool.write { db in
            try ClipRow.deleteAll(db)
        }
        try? FileManager.default.removeItem(at: imagesDir)
        try FileManager.default.createDirectory(
            at: imagesDir, withIntermediateDirectories: true
        )
    }

    // MARK: - Read

    func fetch(sortBy: SortOrder = .recency) throws -> [ClipItem] {
        try pool.read { db in
            let rows: [ClipRow]
            switch sortBy {
            case .recency:
                rows = try ClipRow
                    .order(Column("created_at").desc)
                    .limit(self.maxItems)
                    .fetchAll(db)
            case .frequency:
                // Most-used first. Ties broken by recency so a 1-use
                // recent clip beats a 1-use ancient clip.
                rows = try ClipRow
                    .order(Column("use_count").desc, Column("created_at").desc)
                    .limit(self.maxItems)
                    .fetchAll(db)
            }
            return rows.map { $0.toClipItem() }
        }
    }

    func imageFileURL(_ relativePath: String) -> URL {
        imagesDir.appendingPathComponent(relativePath)
    }

    func loadImage(_ relativePath: String) -> Data? {
        let url = imagesDir.appendingPathComponent(relativePath)
        return try? Data(contentsOf: url)
    }
}

// MARK: - Row mapping

private struct ClipPayloadRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "clip_payloads"
    var clip_id: Int64
    var uti: String
    var data: Data
}

private struct ClipRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "clips"
    var id: Int64?
    var kind: String
    var preview: String
    var created_at: Double
    var text_content: String?
    var image_path: String?
    var thumbnail: Data?
    var file_urls: String?
    var use_count: Int
    var subtype: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    func toClipItem() -> ClipItem {
        let kindEnum = ClipKind(rawValue: kind) ?? .text
        let urls: [String]?
        if let s = file_urls, let data = s.data(using: .utf8) {
            urls = (try? JSONDecoder().decode([String].self, from: data))
        } else {
            urls = nil
        }
        return ClipItem(
            id: id ?? 0,
            kind: kindEnum,
            preview: preview,
            createdAt: Date(timeIntervalSince1970: created_at),
            useCount: use_count,
            text: text_content,
            imagePath: image_path,
            thumbnail: thumbnail,
            fileURLs: urls,
            subtype: subtype.flatMap(TextSubtype.init(rawValue:))
        )
    }
}

// MARK: - Thumbnail helper

private extension NSImage {
    func pngThumbnail(maxDim: CGFloat) -> Data? {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0 else { return nil }
        let scale = max(w, h) > maxDim ? maxDim / max(w, h) : 1
        let newSize = NSSize(width: w * scale, height: h * scale)

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(newSize.width),
            pixelsHigh: Int(newSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        rep.size = newSize

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy,
             fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
