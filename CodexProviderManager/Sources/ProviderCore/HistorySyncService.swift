import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct HistorySnapshot: Equatable, Sendable {
    public let totalThreads: Int
    public let visibleThreads: Int
    public let sessionFileCount: Int
    public let extensionPaths: Set<String>
}

public enum HistorySyncError: Error, Equatable {
    case openDatabase(String)
    case query(String)
    case invariantChanged(before: HistorySnapshot, after: HistorySnapshot)
}

public final class HistorySyncService: @unchecked Sendable {
    public let codexHome: URL

    public init(codexHome: URL) { self.codexHome = codexHome }

    public func snapshot() throws -> HistorySnapshot {
        let dbURL = codexHome.appendingPathComponent("state_5.sqlite")
        let total = try scalar("SELECT COUNT(*) FROM threads", database: dbURL)
        let visible = try scalar("SELECT COUNT(*) FROM threads WHERE COALESCE(archived, 0) = 0 AND preview <> ''", database: dbURL, fallback: total)
        let sessionRoot = codexHome.appendingPathComponent("sessions")
        let sessions = FileManager.default.enumerator(at: sessionRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }.count ?? 0
        var extensionNames = ["skills", "plugins", "mcp"].filter {
            FileManager.default.fileExists(atPath: codexHome.appendingPathComponent($0).path)
        }
        if let config = try? String(contentsOf: codexHome.appendingPathComponent("config.toml")),
           config.contains("[mcp_servers.") || config.contains("[mcp]") {
            extensionNames.append("mcp")
        }
        return HistorySnapshot(totalThreads: total, visibleThreads: visible, sessionFileCount: sessions, extensionPaths: Set(extensionNames))
    }

    public func synchronize(provider: ProviderID) throws {
        let dbURL = codexHome.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw HistorySyncError.openDatabase(dbURL.path)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw queryError(db) }
        do {
            try execute("UPDATE threads SET model_provider = ? WHERE model_provider IS NULL OR model_provider <> ?", bindings: [provider.rawValue, provider.rawValue], db: db)
            try execute("UPDATE threads SET preview = title WHERE preview = '' AND title <> ''", bindings: [], db: db)
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw queryError(db) }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func verify(before: HistorySnapshot, after: HistorySnapshot) throws {
        guard before.totalThreads == after.totalThreads,
              after.visibleThreads >= before.visibleThreads,
              before.sessionFileCount == after.sessionFileCount,
              before.extensionPaths == after.extensionPaths else {
            throw HistorySyncError.invariantChanged(before: before, after: after)
        }
    }

    private func scalar(_ sql: String, database: URL, fallback: Int? = nil) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw HistorySyncError.openDatabase(database.path)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let fallback { return fallback }
            throw queryError(db)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            if let fallback { return fallback }
            throw queryError(db)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func execute(_ sql: String, bindings: [String], db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw queryError(db) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw queryError(db) }
    }

    private func queryError(_ db: OpaquePointer) -> HistorySyncError {
        HistorySyncError.query(String(cString: sqlite3_errmsg(db)))
    }
}
