import Foundation
import CSQLite

struct Entry {
    let key: String
    let file: String
    let bytes: Int64
    let expires: Double?
    let accessed: Double
}

final class Index {
    private var db: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = CacheError.database("open failed")
            sqlite3_close(db); db = nil; throw error
        }
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS entries (key TEXT PRIMARY KEY, file TEXT NOT NULL UNIQUE, bytes INTEGER NOT NULL CHECK(bytes >= 0), expires REAL, accessed REAL NOT NULL)")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CacheError.database(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }
    private func bind(_ value: String, _ position: Int32, _ statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, position, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CacheError.database(String(cString: sqlite3_errmsg(db)))
        }
    }
    func all() throws -> [Entry] {
        let s = try prepare("SELECT key,file,bytes,expires,accessed FROM entries ORDER BY accessed,key")
        defer { sqlite3_finalize(s) }
        var result: [Entry] = []
        var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            result.append(Entry(key: String(cString: sqlite3_column_text(s, 0)),
                                file: String(cString: sqlite3_column_text(s, 1)), bytes: sqlite3_column_int64(s, 2),
                                expires: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : sqlite3_column_double(s, 3),
                                accessed: sqlite3_column_double(s, 4)))
            status = sqlite3_step(s)
        }
        guard status == SQLITE_DONE else { throw CacheError.database("select failed") }
        return result
    }
    func find(_ key: String) throws -> Entry? {
        let s = try prepare("SELECT key,file,bytes,expires,accessed FROM entries WHERE key=?")
        defer { sqlite3_finalize(s) }
        bind(key, 1, s)
        let status = sqlite3_step(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw CacheError.database("lookup failed") }
        return Entry(key: String(cString: sqlite3_column_text(s, 0)),
                     file: String(cString: sqlite3_column_text(s, 1)), bytes: sqlite3_column_int64(s, 2),
                     expires: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : sqlite3_column_double(s, 3),
                     accessed: sqlite3_column_double(s, 4))
    }
    func upsert(_ entry: Entry) throws {
        let s = try prepare("INSERT INTO entries VALUES(?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET file=excluded.file,bytes=excluded.bytes,expires=excluded.expires,accessed=excluded.accessed")
        defer { sqlite3_finalize(s) }
        bind(entry.key, 1, s); bind(entry.file, 2, s); sqlite3_bind_int64(s, 3, entry.bytes)
        if let expires = entry.expires { sqlite3_bind_double(s, 4, expires) } else { sqlite3_bind_null(s, 4) }
        sqlite3_bind_double(s, 5, entry.accessed)
        guard sqlite3_step(s) == SQLITE_DONE else { throw CacheError.database("upsert failed") }
    }
    func remove(_ key: String) throws {
        let s = try prepare("DELETE FROM entries WHERE key=?"); defer { sqlite3_finalize(s) }
        bind(key, 1, s)
        guard sqlite3_step(s) == SQLITE_DONE else { throw CacheError.database("delete failed") }
    }
    func touch(_ values: [String: Double]) throws {
        guard !values.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for (key, time) in values {
                let s = try prepare("UPDATE entries SET accessed=? WHERE key=?")
                defer { sqlite3_finalize(s) }
                sqlite3_bind_double(s, 1, time); bind(key, 2, s)
                guard sqlite3_step(s) == SQLITE_DONE else { throw CacheError.database("touch failed") }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
}
