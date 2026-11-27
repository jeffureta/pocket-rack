import Foundation
import SQLite3

public enum RackStoreError: Error, Sendable, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case executionFailed(String)
    case invalidJSON
}

public struct RackDocument: Sendable, Codable, Equatable {
    public let collection: String
    public let id: String
    public let jsonString: String
    public let createdAt: Int64
    public let updatedAt: Int64
}

public struct RackKVEntry: Sendable, Codable, Equatable {
    public let key: String
    public let value: String
    public let expiresAt: Int64?
    public let updatedAt: Int64
}

public struct WebhookDelivery: Sendable, Codable, Equatable {
    public let id: Int64
    public let hook: String
    public let method: String
    public let headersJSON: String
    public let query: String
    public let body: String
    public let remoteAddress: String
    public let receivedAt: Int64
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteHandleBox: @unchecked Sendable {
    var pointer: OpaquePointer?
    init(_ pointer: OpaquePointer?) { self.pointer = pointer }
    deinit {
        if let pointer {
            sqlite3_close(pointer)
        }
    }
}

public actor RackStore {
    private let handleBox: SQLiteHandleBox
    private var db: OpaquePointer? { handleBox.pointer }
    private let maxWebhookEvents: Int

    public init(path: String, profile: CapacityProfile = .balancedM2) throws {
        self.maxWebhookEvents = max(1, profile.maxWebhookEvents)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
            sqlite3_close(handle)
            throw RackStoreError.openFailed(msg)
        }
        self.handleBox = SQLiteHandleBox(handle)
        try Self.configurePragmas(db: handle, path: path, profile: profile)
        try Self.migrate(db: handle)
    }

    private static func configurePragmas(db: OpaquePointer?, path: String, profile: CapacityProfile) throws {
        var pragmas = [
            "PRAGMA foreign_keys = ON;",
            "PRAGMA busy_timeout = 5000;",
            "PRAGMA cache_size = -\(profile.sqliteCacheKB);",
            "PRAGMA mmap_size = \(profile.sqliteMmapBytes);",
        ]
        if path != ":memory:" {
            pragmas.insert("PRAGMA journal_mode = WAL;", at: 0)
            pragmas.insert("PRAGMA synchronous = NORMAL;", at: 1)
        }
        for sql in pragmas {
            try exec(db: db, sql: sql)
        }
    }

    private static func migrate(db: OpaquePointer?) throws {
        try exec(db: db, sql: """
        CREATE TABLE IF NOT EXISTS collections (
            collection TEXT NOT NULL,
            id TEXT NOT NULL,
            json_body TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (collection, id)
        );
        CREATE INDEX IF NOT EXISTS idx_collections_col_updated ON collections(collection, updated_at DESC);

        CREATE TABLE IF NOT EXISTS kv_store (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            expires_at INTEGER,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS webhooks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            hook TEXT NOT NULL,
            method TEXT NOT NULL,
            headers_json TEXT NOT NULL,
            query TEXT NOT NULL,
            body TEXT NOT NULL,
            remote_address TEXT NOT NULL,
            received_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_webhooks_hook_id ON webhooks(hook, id DESC);
        """)
    }

    private static func exec(db: OpaquePointer?, sql: String) throws {
        var errPtr: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errPtr)
        if rc != SQLITE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? "exec error"
            sqlite3_free(errPtr)
            throw RackStoreError.executionFailed(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "prepare error"
            throw RackStoreError.prepareFailed(msg)
        }
        return stmt
    }

    // MARK: - Collections

    public func createDocument(collection: String, id: String? = nil, jsonString: String, now: Date = Date()) throws -> RackDocument {
        try validateJSON(jsonString)
        let docId = (id?.isEmpty == false) ? id! : UUID().uuidString.lowercased()
        let ts = Int64(now.timeIntervalSince1970)
        let stmt = try prepare("INSERT INTO collections (collection, id, json_body, created_at, updated_at) VALUES (?, ?, ?, ?, ?);")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, collection, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, docId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, jsonString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, ts)
        sqlite3_bind_int64(stmt, 5, ts)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw RackStoreError.executionFailed(lastError())
        }
        return RackDocument(collection: collection, id: docId, jsonString: jsonString, createdAt: ts, updatedAt: ts)
    }

    public func upsertDocument(collection: String, id: String, jsonString: String, now: Date = Date()) throws -> RackDocument {
        try validateJSON(jsonString)
        let ts = Int64(now.timeIntervalSince1970)
        let stmt = try prepare("""
        INSERT INTO collections (collection, id, json_body, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(collection, id) DO UPDATE SET
            json_body = excluded.json_body,
            updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, collection, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, jsonString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, ts)
        sqlite3_bind_int64(stmt, 5, ts)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw RackStoreError.executionFailed(lastError())
        }
        return try getDocument(collection: collection, id: id) ?? RackDocument(collection: collection, id: id, jsonString: jsonString, createdAt: ts, updatedAt: ts)
    }

    public func getDocument(collection: String, id: String) throws -> RackDocument? {
        let stmt = try prepare("SELECT collection, id, json_body, created_at, updated_at FROM collections WHERE collection = ? AND id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, collection, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readDocument(stmt)
    }

    public func listDocuments(collection: String, limit: Int = 50, offset: Int = 0) throws -> [RackDocument] {
        let stmt = try prepare("SELECT collection, id, json_body, created_at, updated_at FROM collections WHERE collection = ? ORDER BY updated_at DESC, id ASC LIMIT ? OFFSET ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, collection, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(max(1, min(500, limit))))
        sqlite3_bind_int(stmt, 3, Int32(max(0, offset)))
        var docs: [RackDocument] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            docs.append(readDocument(stmt))
        }
        return docs
    }

    public func deleteDocument(collection: String, id: String) throws -> Bool {
        let stmt = try prepare("DELETE FROM collections WHERE collection = ? AND id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, collection, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw RackStoreError.executionFailed(lastError())
        }
        return sqlite3_changes(db) > 0
    }

    public func listCollections() throws -> [String] {
        let stmt = try prepare("SELECT DISTINCT collection FROM collections ORDER BY collection ASC;")
        defer { sqlite3_finalize(stmt) }
        var cols: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) {
                cols.append(String(cString: ptr))
            }
        }
        return cols
    }

    // MARK: - KV Store

    public func setValue(key: String, value: String, ttlSeconds: Int? = nil, now: Date = Date()) throws {
        let ts = Int64(now.timeIntervalSince1970)
        let expiresAt: Int64? = ttlSeconds.map { ts + Int64($0) }
        let stmt = try prepare("""
        INSERT INTO kv_store (key, value, expires_at, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            value = excluded.value,
            expires_at = excluded.expires_at,
            updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        if let expiresAt {
            sqlite3_bind_int64(stmt, 3, expiresAt)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_int64(stmt, 4, ts)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw RackStoreError.executionFailed(lastError())
        }
    }

    public func getValue(key: String, now: Date = Date()) throws -> RackKVEntry? {
        let nowTs = Int64(now.timeIntervalSince1970)
        let stmt = try prepare("SELECT key, value, expires_at, updated_at FROM kv_store WHERE key = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let expires = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2)
        if let expires, expires < nowTs {
            _ = try? deleteValue(key: key)
            return nil
        }
        return RackKVEntry(
            key: String(cString: sqlite3_column_text(stmt, 0)),
            value: String(cString: sqlite3_column_text(stmt, 1)),
            expiresAt: expires,
            updatedAt: sqlite3_column_int64(stmt, 3)
        )
    }

    public func listKeys(now: Date = Date()) throws -> [RackKVEntry] {
        let nowTs = Int64(now.timeIntervalSince1970)
        let stmt = try prepare("SELECT key, value, expires_at, updated_at FROM kv_store WHERE expires_at IS NULL OR expires_at >= ? ORDER BY key ASC;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, nowTs)
        var items: [RackKVEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let expires = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2)
            items.append(RackKVEntry(
                key: String(cString: sqlite3_column_text(stmt, 0)),
                value: String(cString: sqlite3_column_text(stmt, 1)),
                expiresAt: expires,
                updatedAt: sqlite3_column_int64(stmt, 3)
            ))
        }
        return items
    }

    public func deleteValue(key: String) throws -> Bool {
        let stmt = try prepare("DELETE FROM kv_store WHERE key = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw RackStoreError.executionFailed(lastError())
        }
        return sqlite3_changes(db) > 0
    }

    // MARK: - Webhooks

    public func recordWebhook(
        hook: String,
        method: String,
        headers: [String: String],
        query: String,
        body: String,
        remoteAddress: String,
        now: Date = Date()
    ) throws -> WebhookDelivery {
        let ts = Int64(now.timeIntervalSince1970)
        let headersData = (try? JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys])) ?? Data("{}".utf8)
        let headersJSON = String(data: headersData, encoding: .utf8) ?? "{}"

        let stmt = try prepare("""
        INSERT INTO webhooks (hook, method, headers_json, query, body, remote_address, received_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, hook, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, method, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, headersJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, body, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, remoteAddress, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 7, ts)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw RackStoreError.executionFailed(lastError())
        }
        let insertedId = sqlite3_last_insert_rowid(db)
        try pruneWebhooksIfNeeded()
        return WebhookDelivery(
            id: insertedId,
            hook: hook,
            method: method,
            headersJSON: headersJSON,
            query: query,
            body: body,
            remoteAddress: remoteAddress,
            receivedAt: ts
        )
    }

    public func listWebhooks(hook: String? = nil, limit: Int = 50) throws -> [WebhookDelivery] {
        let sql = hook == nil
            ? "SELECT id, hook, method, headers_json, query, body, remote_address, received_at FROM webhooks ORDER BY id DESC LIMIT ?;"
            : "SELECT id, hook, method, headers_json, query, body, remote_address, received_at FROM webhooks WHERE hook = ? ORDER BY id DESC LIMIT ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        if let hook {
            sqlite3_bind_text(stmt, 1, hook, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(max(1, min(500, limit))))
        } else {
            sqlite3_bind_int(stmt, 1, Int32(max(1, min(500, limit))))
        }
        var result: [WebhookDelivery] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(WebhookDelivery(
                id: sqlite3_column_int64(stmt, 0),
                hook: String(cString: sqlite3_column_text(stmt, 1)),
                method: String(cString: sqlite3_column_text(stmt, 2)),
                headersJSON: String(cString: sqlite3_column_text(stmt, 3)),
                query: String(cString: sqlite3_column_text(stmt, 4)),
                body: String(cString: sqlite3_column_text(stmt, 5)),
                remoteAddress: String(cString: sqlite3_column_text(stmt, 6)),
                receivedAt: sqlite3_column_int64(stmt, 7)
            ))
        }
        return result
    }

    public func clearWebhooks(hook: String? = nil) throws {
        if let hook {
            let stmt = try prepare("DELETE FROM webhooks WHERE hook = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, hook, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw RackStoreError.executionFailed(lastError())
            }
        } else {
            try Self.exec(db: db, sql: "DELETE FROM webhooks;")
        }
    }

    private func pruneWebhooksIfNeeded() throws {
        let stmt = try prepare("""
        DELETE FROM webhooks
        WHERE id NOT IN (
            SELECT id FROM webhooks ORDER BY id DESC LIMIT ?
        );
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(maxWebhookEvents))
        _ = sqlite3_step(stmt)
    }

    private func readDocument(_ stmt: OpaquePointer?) -> RackDocument {
        RackDocument(
            collection: String(cString: sqlite3_column_text(stmt, 0)),
            id: String(cString: sqlite3_column_text(stmt, 1)),
            jsonString: String(cString: sqlite3_column_text(stmt, 2)),
            createdAt: sqlite3_column_int64(stmt, 3),
            updatedAt: sqlite3_column_int64(stmt, 4)
        )
    }

    private func validateJSON(_ jsonString: String) throws {
        guard let data = jsonString.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw RackStoreError.invalidJSON
        }
    }

    private func lastError() -> String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error"
    }
}
