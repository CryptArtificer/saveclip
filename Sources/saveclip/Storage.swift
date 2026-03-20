import Compression
import Foundation
import SQLite3
import UniformTypeIdentifiers
import zlib

final class Storage {
    private var db: OpaquePointer?
    private let config: Config

    private let selectCols = "id, timestamp, type, hash, preview, file_path, source_app, pinned, branch, sensitive, total_size, copy_count"

    init(config: Config, dbPath: String? = nil) throws {
        self.config = config
        try config.ensureDirectories()

        let dbPath = dbPath ?? Config.defaultDir + "/index.db"
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw StorageError.cannotOpenDB(String(cString: sqlite3_errmsg(db)))
        }

        try execute("""
            CREATE TABLE IF NOT EXISTS clips (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                type TEXT NOT NULL,
                hash TEXT NOT NULL,
                preview TEXT NOT NULL,
                file_path TEXT NOT NULL,
                source_app TEXT,
                pinned INTEGER NOT NULL DEFAULT 0,
                branch TEXT NOT NULL DEFAULT 'main',
                sensitive INTEGER NOT NULL DEFAULT 0,
                total_size INTEGER NOT NULL DEFAULT 0,
                copy_count INTEGER NOT NULL DEFAULT 1
            )
        """)
        // Migrations for older schemas
        try? execute("ALTER TABLE clips ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0")
        try? execute("ALTER TABLE clips ADD COLUMN branch TEXT NOT NULL DEFAULT 'main'")
        try? execute("ALTER TABLE clips ADD COLUMN sensitive INTEGER NOT NULL DEFAULT 0")
        try? execute("ALTER TABLE clips ADD COLUMN total_size INTEGER NOT NULL DEFAULT 0")
        try? execute("ALTER TABLE clips ADD COLUMN copy_count INTEGER NOT NULL DEFAULT 1")
        try execute("CREATE INDEX IF NOT EXISTS idx_clips_hash ON clips(hash)")
        try execute("CREATE INDEX IF NOT EXISTS idx_clips_timestamp ON clips(timestamp DESC)")
        try execute("CREATE INDEX IF NOT EXISTS idx_clips_branch ON clips(branch)")

        // FTS5 full-text search on preview
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts USING fts5(preview, content='clips', content_rowid='id')")
        // Triggers to keep FTS in sync
        try? execute("""
            CREATE TRIGGER IF NOT EXISTS clips_ai AFTER INSERT ON clips BEGIN
                INSERT INTO clips_fts(rowid, preview) VALUES (new.id, new.preview);
            END
        """)
        try? execute("""
            CREATE TRIGGER IF NOT EXISTS clips_ad AFTER DELETE ON clips BEGIN
                INSERT INTO clips_fts(clips_fts, rowid, preview) VALUES ('delete', old.id, old.preview);
            END
        """)
        try? execute("""
            CREATE TRIGGER IF NOT EXISTS clips_au AFTER UPDATE ON clips BEGIN
                INSERT INTO clips_fts(clips_fts, rowid, preview) VALUES ('delete', old.id, old.preview);
                INSERT INTO clips_fts(rowid, preview) VALUES (new.id, new.preview);
            END
        """)
        // One-time FTS rebuild for pre-trigger data, then skip
        if userVersion() < 2 {
            try? execute("INSERT INTO clips_fts(clips_fts) VALUES ('rebuild')")
            try? execute("PRAGMA user_version = 2")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Write

    /// Check if this hash was recently saved. If so, bump its copy_count and timestamp.
    func isDuplicate(hash: String, lookback: Int = 20) -> Bool {
        let query = "SELECT id FROM (SELECT id, hash FROM clips ORDER BY timestamp DESC LIMIT ?) WHERE hash = ? LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int(stmt, 1, Int32(lookback))
        sqlite3_bind_text(stmt, 2, (hash as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            // Bump copy count and refresh timestamp
            try? executeById("UPDATE clips SET copy_count = copy_count + 1, timestamp = \(Date().timeIntervalSince1970) WHERE id = ?", id: id)
            return true
        }
        return false
    }

    @discardableResult
    func save(content: ClipContent, preview: String, sourceApp: String?, branch: String, sensitive: Bool = false) throws -> ClipEntry {
        let timestamp = Date()
        let hash = content.combinedHash

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let bundleName = "\(formatter.string(from: timestamp))_\(String(hash.prefix(8)))"
        let bundlePath = (config.storageDir as NSString).appendingPathComponent(bundleName)

        let fm = FileManager.default
        try fm.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)

        // Write each representation
        var manifest: [[String: String]] = []
        for rep in content.representations {
            let filePath = (bundlePath as NSString).appendingPathComponent(rep.filename)
            try rep.data.write(to: URL(fileURLWithPath: filePath))
            manifest.append(["uti": rep.uti, "file": rep.filename, "size": String(rep.data.count)])
        }

        // Write manifest
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try manifestData.write(to: URL(fileURLWithPath: (bundlePath as NSString).appendingPathComponent("manifest.json")))

        let totalSize = content.totalSize

        let query = "INSERT INTO clips (timestamp, type, hash, preview, file_path, source_app, branch, sensitive, total_size) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_double(stmt, 1, timestamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, (content.primaryType.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (hash as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (preview as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (bundlePath as NSString).utf8String, -1, nil)
        if let app = sourceApp {
            sqlite3_bind_text(stmt, 6, (app as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_text(stmt, 7, (branch as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 8, sensitive ? 1 : 0)
        sqlite3_bind_int64(stmt, 9, Int64(totalSize))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StorageError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }

        let id = sqlite3_last_insert_rowid(db)
        try enforceStorageBudget()

        return ClipEntry(
            id: id, timestamp: timestamp, type: content.primaryType, hash: hash,
            preview: preview, filePath: bundlePath, sourceApp: sourceApp,
            pinned: false, branch: branch, sensitive: sensitive, totalSize: totalSize, copyCount: 1
        )
    }

    // MARK: - Read

    func latestTimestamp() -> Double? {
        let sql = "SELECT MAX(timestamp) FROM clips"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(stmt, 0)
    }

    func list(limit: Int = 20, branch: String? = nil) -> [ClipEntry] {
        // Deduplicate by hash — keep the entry with the latest timestamp per unique content
        let dedup = "(SELECT id FROM clips c2 WHERE c2.hash = clips.hash ORDER BY c2.timestamp DESC LIMIT 1)"
        let sql: String
        if branch != nil {
            sql = "SELECT \(selectCols) FROM clips WHERE branch = ? AND id = \(dedup) ORDER BY timestamp DESC LIMIT ?"
        } else {
            sql = "SELECT \(selectCols) FROM clips WHERE id = \(dedup) ORDER BY timestamp DESC LIMIT ?"
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        if let branch = branch {
            sqlite3_bind_text(stmt, 1, (branch as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        } else {
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }

        var entries: [ClipEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let entry = readRow(stmt) {
                entries.append(entry)
            }
        }
        return entries
    }

    func get(id: Int64) -> ClipEntry? {
        let sql = "SELECT \(selectCols) FROM clips WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(stmt, 1, id)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return readRow(stmt)
        }
        return nil
    }

    func search(query searchTerm: String, limit: Int = 200, branch: String? = nil) -> [ClipEntry] {
        // Escape FTS5 special chars and add prefix matching
        let escaped = searchTerm
            .replacingOccurrences(of: "\"", with: "\"\"")
        let ftsQuery = "\"\(escaped)\"*"

        let cols = selectCols.split(separator: ",").map { "clips." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        let sql: String
        if branch != nil {
            sql = "SELECT \(cols) FROM clips JOIN clips_fts ON clips.id = clips_fts.rowid WHERE clips_fts MATCH ? AND clips.branch = ? ORDER BY clips.timestamp DESC LIMIT ?"
        } else {
            sql = "SELECT \(cols) FROM clips JOIN clips_fts ON clips.id = clips_fts.rowid WHERE clips_fts MATCH ? ORDER BY clips.timestamp DESC LIMIT ?"
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return searchFallback(searchTerm: searchTerm, limit: limit, branch: branch)
        }
        sqlite3_bind_text(stmt, 1, (ftsQuery as NSString).utf8String, -1, nil)
        if let branch = branch {
            sqlite3_bind_text(stmt, 2, (branch as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(limit))
        } else {
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }

        var entries: [ClipEntry] = []
        var seenHashes = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let entry = readRow(stmt) {
                if seenHashes.insert(entry.hash).inserted {
                    entries.append(entry)
                }
            }
        }
        return entries
    }

    private func searchFallback(searchTerm: String, limit: Int, branch: String?) -> [ClipEntry] {
        let sql: String
        if branch != nil {
            sql = "SELECT \(selectCols) FROM clips WHERE preview LIKE ? AND branch = ? ORDER BY timestamp DESC LIMIT ?"
        } else {
            sql = "SELECT \(selectCols) FROM clips WHERE preview LIKE ? ORDER BY timestamp DESC LIMIT ?"
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        let pattern = "%\(searchTerm)%"
        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)
        if let branch = branch {
            sqlite3_bind_text(stmt, 2, (branch as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(limit))
        } else {
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }

        var entries: [ClipEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let entry = readRow(stmt) {
                entries.append(entry)
            }
        }
        return entries
    }

    func fuzzyFallback(query: String, limit: Int = 200, branch: String? = nil) -> [ClipEntry] {
        let entries = list(limit: limit, branch: branch)
        let q = query.lowercased()
        let maxDist = max(2, q.count / 3)

        var scored: [(entry: ClipEntry, dist: Int)] = []
        for entry in entries {
            let words = entry.preview.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            var best = Int.max
            for word in words {
                let d = Self.levenshtein(String(word), q)
                best = min(best, d)
                if best == 0 { break }
            }
            if best <= maxDist {
                scored.append((entry, best))
            }
        }
        scored.sort { $0.dist < $1.dist }
        return scored.map(\.entry)
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                curr[j] = a[i-1] == b[j-1]
                    ? prev[j-1]
                    : 1 + min(prev[j-1], prev[j], curr[j-1])
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    func entryCount(branch: String? = nil) -> Int {
        let sql: String
        if branch != nil {
            sql = "SELECT COUNT(*) FROM clips WHERE branch = ?"
        } else {
            sql = "SELECT COUNT(*) FROM clips"
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        if let branch = branch {
            sqlite3_bind_text(stmt, 1, (branch as NSString).utf8String, -1, nil)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    // MARK: - Branches

    struct BranchInfo {
        let name: String
        let count: Int
        let lastActivity: Date?
    }

    func listBranches() -> [BranchInfo] {
        let sql = "SELECT branch, COUNT(*), MAX(timestamp) FROM clips GROUP BY branch ORDER BY MAX(timestamp) DESC"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        var branches: [BranchInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            let ts = sqlite3_column_double(stmt, 2)
            let lastActivity = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
            branches.append(BranchInfo(name: name, count: count, lastActivity: lastActivity))
        }
        return branches
    }

    struct FrequentEntry {
        let entry: ClipEntry
        let copyCount: Int
    }

    func mostFrequent(limit: Int = 10) -> [FrequentEntry] {
        let sql = "SELECT \(selectCols) FROM clips WHERE copy_count > 1 ORDER BY copy_count DESC, id DESC LIMIT ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [FrequentEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let entry = readRow(stmt) {
                results.append(FrequentEntry(entry: entry, copyCount: entry.copyCount))
            }
        }
        return results
    }

    func moveToBranch(id: Int64, branch: String) throws {
        let sql = "UPDATE clips SET branch = ? WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, (branch as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Modify

    func markSensitive(id: Int64) throws {
        try executeById("UPDATE clips SET sensitive = 1 WHERE id = ?", id: id)
    }

    func pin(id: Int64) throws {
        try executeById("UPDATE clips SET pinned = 1 WHERE id = ?", id: id)
    }

    func unpin(id: Int64) throws {
        try executeById("UPDATE clips SET pinned = 0 WHERE id = ?", id: id)
    }

    func bumpToFront(id: Int64) throws {
        let sql = "UPDATE clips SET copy_count = copy_count + 1, timestamp = ? WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func delete(id: Int64) throws {
        if let entry = get(id: id) {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: entry.filePath, isDirectory: &isDir) {
                try? fm.removeItem(atPath: entry.filePath)
            }
        }
        try executeById("DELETE FROM clips WHERE id = ?", id: id)
    }

    func clearAll() throws {
        let query = "SELECT file_path FROM clips"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            let fm = FileManager.default
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = String(cString: sqlite3_column_text(stmt, 0))
                try? fm.removeItem(atPath: path)
            }
        }
        try execute("DELETE FROM clips")
    }

    // MARK: - File I/O

    /// Read the primary clip data from a bundle or legacy single file
    func readClipData(entry: ClipEntry) -> Data? {
        let path = entry.filePath
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }

        if isDir.boolValue {
            // Bundle: read the primary representation
            return readPrimaryFromBundle(path: path, type: entry.type)
        }

        // Legacy single file
        guard let data = fm.contents(atPath: path) else { return nil }
        if path.hasSuffix(".gz") {
            return gzipDecompress(data)
        }
        return data
    }

    /// Read all representations from a bundle for restoring to pasteboard
    func readBundleRepresentations(entry: ClipEntry) -> [(uti: String, data: Data)]? {
        let path = entry.filePath
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            // Legacy single file — return as single representation
            guard let data = readClipData(entry: entry) else { return nil }
            let uti: String
            switch entry.type {
            case .text: uti = "public.utf8-plain-text"
            case .image: uti = "public.png"
            case .filePath: uti = "public.file-url"
            }
            return [(uti: uti, data: data)]
        }

        let manifestPath = (path as NSString).appendingPathComponent("manifest.json")
        guard let manifestData = fm.contents(atPath: manifestPath),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [[String: String]] else {
            return nil
        }

        var reps: [(uti: String, data: Data)] = []
        for item in manifest {
            guard let uti = item["uti"], let filename = item["file"] else { continue }
            let filePath = (path as NSString).appendingPathComponent(filename)
            guard let data = fm.contents(atPath: filePath) else { continue }
            reps.append((uti: uti, data: data))
        }
        return reps.isEmpty ? nil : reps
    }

    private func readPrimaryFromBundle(path: String, type: ClipType) -> Data? {
        let fm = FileManager.default
        let manifestPath = (path as NSString).appendingPathComponent("manifest.json")
        guard let manifestData = fm.contents(atPath: manifestPath),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [[String: String]] else {
            return nil
        }

        // Find the best representation by UTI conformance
        let target: [String: String]?
        switch type {
        case .text:
            target = manifest.first { $0["uti"] == "public.utf8-plain-text" }
                  ?? manifest.first { $0["uti"].flatMap({ UTType($0) })?.conforms(to: .text) == true }
        case .image:
            target = manifest.first { $0["uti"].flatMap({ UTType($0) })?.conforms(to: .image) == true }
        case .filePath:
            target = manifest.first { $0["uti"] == "public.file-url" }
        }
        let resolved = target ?? manifest.first
        guard let filename = resolved?["file"] else { return nil }
        let filePath = (path as NSString).appendingPathComponent(filename)
        return fm.contents(atPath: filePath)
    }

    // MARK: - Maintenance

    func runMaintenance() {
        compressOldEntries()
        expireOldEntries()
    }

    private func compressOldEntries() {
        guard config.compressAfterDays > 0 else { return }
        let cutoff = Date().timeIntervalSince1970 - Double(config.compressAfterDays * 86400)

        // Only compress legacy single-file entries (not bundles)
        let query = "SELECT id, file_path FROM clips WHERE timestamp < ? AND file_path NOT LIKE '%.gz' AND file_path LIKE '%.%'"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, cutoff)

        let fm = FileManager.default
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let path = String(cString: sqlite3_column_text(stmt, 1))

            // Skip bundle directories
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { continue }

            guard fm.fileExists(atPath: path),
                  let data = fm.contents(atPath: path) else { continue }

            let compressedPath = path + ".gz"
            if let compressed = gzipCompress(data) {
                do {
                    try compressed.write(to: URL(fileURLWithPath: compressedPath))
                    try fm.removeItem(atPath: path)
                    try executeUpdate("UPDATE clips SET file_path = ? WHERE id = ?", text: compressedPath, id: id)
                } catch {
                    try? fm.removeItem(atPath: compressedPath)
                }
            }
        }
    }

    private func expireOldEntries() {
        guard config.ttlDays > 0 else { return }
        let cutoff = Date().timeIntervalSince1970 - Double(config.ttlDays * 86400)

        let query = "SELECT id, file_path FROM clips WHERE timestamp < ? AND pinned = 0"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, cutoff)

        var ids: [Int64] = []
        let fm = FileManager.default
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let path = String(cString: sqlite3_column_text(stmt, 1))
            try? fm.removeItem(atPath: path)
            ids.append(id)
        }

        if !ids.isEmpty {
            let idList = ids.map { String($0) }.joined(separator: ",")
            try? execute("DELETE FROM clips WHERE id IN (\(idList))")
        }
    }

    /// Budget-based eviction: when total storage exceeds maxStorageMB,
    /// evict unpinned entries scored by size * age (largest old media first)
    private func enforceStorageBudget() throws {
        let budgetBytes = Int64(config.maxStorageMB) * 1024 * 1024
        guard budgetBytes > 0 else { return }

        var totalBytes = totalStorageBytes()
        guard totalBytes > budgetBytes else { return }

        // Select unpinned entries ordered by eviction score (size * age) descending
        // This evicts large old entries first, effectively never touching small text
        let query = """
            SELECT id, file_path, total_size FROM clips
            WHERE pinned = 0
            ORDER BY (total_size * (strftime('%s','now') - timestamp)) DESC
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }

        var idsToDelete: [Int64] = []
        let fm = FileManager.default
        while sqlite3_step(stmt) == SQLITE_ROW && totalBytes > budgetBytes {
            let id = sqlite3_column_int64(stmt, 0)
            let path = String(cString: sqlite3_column_text(stmt, 1))
            let size = sqlite3_column_int64(stmt, 2)
            try? fm.removeItem(atPath: path)
            idsToDelete.append(id)
            totalBytes -= size
        }

        if !idsToDelete.isEmpty {
            let idList = idsToDelete.map { String($0) }.joined(separator: ",")
            try execute("DELETE FROM clips WHERE id IN (\(idList))")
            Daemon.log("Budget eviction: removed \(idsToDelete.count) entries to stay under \(config.maxStorageMB)MB")
        }
    }

    func totalStorageBytes() -> Int64 {
        let sql = "SELECT COALESCE(SUM(total_size), 0) FROM clips"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return 0
    }

    // MARK: - Private

    private func readRow(_ stmt: OpaquePointer?) -> ClipEntry? {
        guard let stmt = stmt else { return nil }
        let id = sqlite3_column_int64(stmt, 0)
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let typeStr = String(cString: sqlite3_column_text(stmt, 2))
        let hash = String(cString: sqlite3_column_text(stmt, 3))
        let preview = String(cString: sqlite3_column_text(stmt, 4))
        let filePath = String(cString: sqlite3_column_text(stmt, 5))
        let sourceApp: String? = sqlite3_column_type(stmt, 6) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 6))
            : nil
        let pinned = sqlite3_column_int(stmt, 7) != 0
        let branch: String = sqlite3_column_type(stmt, 8) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 8))
            : "main"
        let sensitive = sqlite3_column_int(stmt, 9) != 0
        let totalSize = Int(sqlite3_column_int64(stmt, 10))
        let copyCount = Int(sqlite3_column_int(stmt, 11))

        guard let type = ClipType(rawValue: typeStr) else { return nil }
        return ClipEntry(id: id, timestamp: timestamp, type: type, hash: hash, preview: preview, filePath: filePath, sourceApp: sourceApp, pinned: pinned, branch: branch, sensitive: sensitive, totalSize: totalSize, copyCount: copyCount)
    }

    private func gzipCompress(_ data: Data) -> Data? {
        var stream = z_stream()
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: (data as NSData).bytes.bindMemory(to: Bytef.self, capacity: data.count))
        stream.avail_in = uInt(data.count)

        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }

        var output = Data(count: data.count + 128)
        stream.next_out = output.withUnsafeMutableBytes { $0.bindMemory(to: Bytef.self).baseAddress! }
        stream.avail_out = uInt(output.count)

        let result = deflate(&stream, Z_FINISH)
        deflateEnd(&stream)

        guard result == Z_STREAM_END else { return nil }
        output.count = Int(stream.total_out)
        return output
    }

    private func gzipDecompress(_ data: Data) -> Data? {
        var stream = z_stream()
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: (data as NSData).bytes.bindMemory(to: Bytef.self, capacity: data.count))
        stream.avail_in = uInt(data.count)

        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }

        var output = Data(count: data.count * 4)
        var result: Int32
        repeat {
            if stream.total_out >= output.count {
                output.count += data.count * 2
            }
            stream.next_out = output.withUnsafeMutableBytes {
                $0.bindMemory(to: Bytef.self).baseAddress!.advanced(by: Int(stream.total_out))
            }
            stream.avail_out = uInt(output.count - Int(stream.total_out))
            result = inflate(&stream, Z_NO_FLUSH)
        } while result == Z_OK

        inflateEnd(&stream)
        guard result == Z_STREAM_END else { return nil }
        output.count = Int(stream.total_out)
        return output
    }

    private func userVersion() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func execute(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw StorageError.queryFailed(msg)
        }
    }

    private func executeById(_ sql: String, id: Int64) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func executeUpdate(_ sql: String, text: String, id: Int64) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, (text as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }
}

enum StorageError: Error, CustomStringConvertible {
    case cannotOpenDB(String)
    case insertFailed(String)
    case queryFailed(String)

    var description: String {
        switch self {
        case .cannotOpenDB(let msg): return "Cannot open database: \(msg)"
        case .insertFailed(let msg): return "Insert failed: \(msg)"
        case .queryFailed(let msg): return "Query failed: \(msg)"
        }
    }
}
