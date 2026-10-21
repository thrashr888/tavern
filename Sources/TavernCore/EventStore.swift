import Foundation
import SQLite3

public enum EventStoreError: Error, Equatable {
    case open(String)
    case sql(String)
}

/// SQLite event log plus one cursor per source.
///
/// Cursors only advance inside the same transaction that stores the events they cover, so a crash
/// can never leave a cursor ahead of the data (plan section 6: "cursors advance only after events persist").
public final class EventStore {
    private var db: OpaquePointer?

    /// Opens (or creates) the store at `path`. Pass `":memory:"` for tests.
    public init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            db = nil
            throw EventStoreError.open(message)
        }
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    /// Default on-disk location: ~/Library/Application Support/Tavern/tavern.sqlite
    public static func defaultURL() throws -> URL {
        guard let dir = TavernPaths.base else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tavern.sqlite")
    }

    // MARK: - Schema

    private func migrate() throws {
        try exec("PRAGMA journal_mode = WAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source TEXT NOT NULL,
                source_id TEXT NOT NULL,
                thread_key TEXT NOT NULL,
                author_agent TEXT,
                source_ts REAL NOT NULL,
                received_ts REAL NOT NULL,
                kind TEXT NOT NULL,
                payload BLOB NOT NULL,
                UNIQUE (source, source_id)
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS events_thread ON events (thread_key, source_ts, id);")
        try exec("""
            CREATE TABLE IF NOT EXISTS cursors (
                source TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_ts REAL NOT NULL
            );
            """)
        // Full-text index for ⌘K (plan 3f). rowid is the event's id; text comes from `SearchText`.
        let hadIndex = try tableExists("events_fts")
        try exec("CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(body, tokenize = 'porter unicode61');")
        if !hadIndex { try rebuildSearchIndex() }
    }

    private func tableExists(_ name: String) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM sqlite_master WHERE name = ?;")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, name)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Indexes every stored event. Runs once, when an older store first gains the index.
    public func rebuildSearchIndex() throws {
        let select = try prepare("""
            SELECT id, source, source_id, thread_key, author_agent, source_ts, received_ts, kind, payload FROM events;
            """)
        var rows: [(Int64, String)] = []
        while sqlite3_step(select) == SQLITE_ROW {
            let event = TavernEvent(
                source: string(select, 1) ?? "", sourceID: string(select, 2) ?? "", threadKey: string(select, 3) ?? "",
                authorAgent: string(select, 4), sourceTS: Date(timeIntervalSince1970: sqlite3_column_double(select, 5)),
                receivedTS: Date(timeIntervalSince1970: sqlite3_column_double(select, 6)),
                kind: string(select, 7) ?? "", payload: data(select, 8)
            )
            if let text = SearchText.text(for: event) { rows.append((sqlite3_column_int64(select, 0), text)) }
        }
        sqlite3_finalize(select)
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec("DELETE FROM events_fts;")
            for (id, text) in rows { try index(id: id, text: text) }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func index(id: Int64, text: String) throws {
        let stmt = try prepare("INSERT INTO events_fts (rowid, body) VALUES (?, ?);")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        bind(stmt, 2, text)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
    }

    // MARK: - Writes

    /// Stores `events`, skipping any whose `(source, sourceID)` is already stored, and optionally
    /// moves `cursor` for `source` in the same transaction. Returns how many events were new.
    @discardableResult
    public func append(_ events: [TavernEvent], cursor: (source: String, value: String)? = nil) throws -> Int {
        try exec("BEGIN IMMEDIATE;")
        do {
            var inserted = 0
            let insert = try prepare("""
                INSERT OR IGNORE INTO events
                    (source, source_id, thread_key, author_agent, source_ts, received_ts, kind, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(insert) }
            for event in events {
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                bind(insert, 1, event.source)
                bind(insert, 2, event.sourceID)
                bind(insert, 3, event.threadKey)
                bind(insert, 4, event.authorAgent)
                sqlite3_bind_double(insert, 5, event.sourceTS.timeIntervalSince1970)
                sqlite3_bind_double(insert, 6, event.receivedTS.timeIntervalSince1970)
                bind(insert, 7, event.kind)
                bind(insert, 8, event.payload)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw lastError() }
                let changed = Int(sqlite3_changes(db))
                inserted += changed
                if changed > 0, let text = SearchText.text(for: event) {
                    try index(id: sqlite3_last_insert_rowid(db), text: text)
                }
            }
            if let cursor {
                try setCursorInTransaction(source: cursor.source, value: cursor.value)
            }
            try exec("COMMIT;")
            return inserted
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Drops a source's cursor, for a full resync (Gmail history 404, Pi unknown entry id).
    public func resetCursor(source: String) throws {
        let stmt = try prepare("DELETE FROM cursors WHERE source = ?;")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, source)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
    }

    private func setCursorInTransaction(source: String, value: String) throws {
        let stmt = try prepare("""
            INSERT INTO cursors (source, value, updated_ts) VALUES (?, ?, ?)
            ON CONFLICT(source) DO UPDATE SET value = excluded.value, updated_ts = excluded.updated_ts;
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, source)
        bind(stmt, 2, value)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
    }

    // MARK: - Reads

    public func cursor(for source: String) throws -> String? {
        let stmt = try prepare("SELECT value FROM cursors WHERE source = ?;")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, source)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return string(stmt, 0)
    }

    /// Events for one thread, oldest first by source time.
    public func events(threadKey: String) throws -> [TavernEvent] {
        try events(where: "thread_key = ?", threadKey)
    }

    /// All events from one source (e.g. every stored Smithery mail), oldest first by source time.
    public func events(source: String) throws -> [TavernEvent] {
        try events(where: "source = ?", source)
    }

    /// Events from one source since a time, oldest first, for the Dashboard's stats.
    public func events(source: String, since: Date) throws -> [TavernEvent] {
        try events(where: "source = ? AND source_ts >= ?", source, since: since)
    }

    private func events(where condition: String, _ value: String, since: Date? = nil) throws -> [TavernEvent] {
        let stmt = try prepare("""
            SELECT source, source_id, thread_key, author_agent, source_ts, received_ts, kind, payload
            FROM events WHERE \(condition) ORDER BY source_ts, id;
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, value)
        if let since { sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970) }
        var result: [TavernEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(TavernEvent(
                source: string(stmt, 0) ?? "",
                sourceID: string(stmt, 1) ?? "",
                threadKey: string(stmt, 2) ?? "",
                authorAgent: string(stmt, 3),
                sourceTS: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                receivedTS: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                kind: string(stmt, 6) ?? "",
                payload: data(stmt, 7)
            ))
        }
        return result
    }

    /// Full-text search over Pi messages and mail, best match first.
    public func search(_ text: String, limit: Int = 50) throws -> [SearchHit] {
        guard let query = SearchText.ftsQuery(text) else { return [] }
        let stmt = try prepare("""
            SELECT e.source, e.source_id, e.thread_key, e.author_agent, e.source_ts, e.received_ts, e.kind, e.payload,
                   snippet(events_fts, 0, '', '', '…', 16)
            FROM events_fts JOIN events e ON e.id = events_fts.rowid
            WHERE events_fts MATCH ? ORDER BY rank LIMIT ?;
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, query)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var hits: [SearchHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let event = TavernEvent(
                source: string(stmt, 0) ?? "", sourceID: string(stmt, 1) ?? "", threadKey: string(stmt, 2) ?? "",
                authorAgent: string(stmt, 3), sourceTS: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                receivedTS: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                kind: string(stmt, 6) ?? "", payload: data(stmt, 7)
            )
            hits.append(SearchHit(event: event, snippet: string(stmt, 8) ?? ""))
        }
        return hits
    }

    /// Events per author, for Dashboard stats. `since` limits to recent events by source time.
    public func countsByAuthor(source: String, since: Date? = nil) throws -> [String: Int] {
        try counts(column: "author_agent", source: source, since: since)
    }

    /// Events per thread, for the Dashboard's busiest threads.
    public func countsByThread(source: String, since: Date? = nil) throws -> [String: Int] {
        try counts(column: "thread_key", source: source, since: since)
    }

    private func counts(column: String, source: String, since: Date?) throws -> [String: Int] {
        let stmt = try prepare("""
            SELECT \(column), COUNT(*) FROM events
            WHERE source = ? AND source_ts >= ? AND \(column) IS NOT NULL GROUP BY \(column);
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, source)
        sqlite3_bind_double(stmt, 2, since?.timeIntervalSince1970 ?? 0)
        var result: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let key = string(stmt, 0) { result[key] = Int(sqlite3_column_int64(stmt, 1)) }
        }
        return result
    }

    /// Events per local day and author (or thread), for the Dashboard's charts.
    public func dailyCounts(source: String, byThread: Bool = false, since: Date) throws -> [DailyCount] {
        let column = byThread ? "thread_key" : "author_agent"
        let stmt = try prepare("""
            SELECT date(source_ts, 'unixepoch', 'localtime') AS day, COALESCE(\(column), ''), COUNT(*) FROM events
            WHERE source = ? AND source_ts >= ? GROUP BY day, \(column) ORDER BY day;
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, source)
        sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        format.timeZone = .current
        var result: [DailyCount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dayText = string(stmt, 0), let day = format.date(from: dayText) else { continue }
            result.append(DailyCount(day: day, key: string(stmt, 1) ?? "", count: Int(sqlite3_column_int64(stmt, 2))))
        }
        return result
    }

    /// Replaces one stored event's payload and author (re-reading a mail Tavern stored badly).
    public func replace(_ event: TavernEvent) throws {
        let stmt = try prepare("UPDATE events SET payload = ?, author_agent = ? WHERE source = ? AND source_id = ?;")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, event.payload)
        if let author = event.authorAgent { bind(stmt, 2, author) } else { sqlite3_bind_null(stmt, 2) }
        bind(stmt, 3, event.source)
        bind(stmt, 4, event.sourceID)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw EventStoreError.sql(String(cString: sqlite3_errmsg(db))) }
    }

    /// Re-attributes one stored event (used when author detection improves).
    public func setAuthor(source: String, sourceID: String, author: String) throws {
        let stmt = try prepare("UPDATE events SET author_agent = ? WHERE source = ? AND source_id = ?;")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, author)
        bind(stmt, 2, source)
        bind(stmt, 3, sourceID)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw EventStoreError.sql(String(cString: sqlite3_errmsg(db))) }
    }

    public func eventCount(source: String? = nil) throws -> Int {
        let sql = source == nil
            ? "SELECT COUNT(*) FROM events;"
            : "SELECT COUNT(*) FROM events WHERE source = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        if let source { bind(stmt, 1, source) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Test hooks

    func beginExclusiveForTesting() throws { try exec("BEGIN EXCLUSIVE;") }
    func rollbackForTesting() throws { try exec("ROLLBACK;") }

    // MARK: - SQLite helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw EventStoreError.sql(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        return stmt
    }

    private func lastError() -> EventStoreError {
        .sql(db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Data) {
        value.withUnsafeBytes { buffer in
            // A zero-length blob still needs a non-null pointer, or SQLite stores NULL.
            let pointer = buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1)
            sqlite3_bind_blob(stmt, index, pointer, Int32(buffer.count), Self.transient)
        }
    }

    private func string(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: text)
    }

    private func data(_ stmt: OpaquePointer?, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard count > 0, let blob = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: blob, count: count)
    }
}

public struct DailyCount: Hashable, Sendable {
    public var day: Date
    public var key: String
    public var count: Int

    public init(day: Date, key: String, count: Int) {
        self.day = day
        self.key = key
        self.count = count
    }
}
