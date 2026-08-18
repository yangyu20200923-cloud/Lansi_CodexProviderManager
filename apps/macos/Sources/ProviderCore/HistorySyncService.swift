import Foundation
import SQLite3
import CryptoKit

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct HistorySnapshot: Equatable, Sendable {
    public let totalThreads: Int
    public let visibleThreads: Int
    public let activeThreadRoutingDigest: String
    public let archivedThreadRoutingDigest: String
    public let sessionFileCount: Int
    public let extensionPaths: Set<String>
    public let sessionHashes: [String: String]
    public let extensionHashes: [String: String]
    public let mcpConfigurationDigest: String
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
        let activeThreadRoutingDigest = try threadRoutingDigest(database: dbURL, archived: false)
        let archivedThreadRoutingDigest = try threadRoutingDigest(database: dbURL, archived: true)
        // Session metadata contains the provider routing that Codex uses when
        // resuming an existing conversation. Ignore that one managed field in
        // the preservation digest; all conversation/session content remains
        // covered by the normalized hash.
        let sessionHashes = try SessionMetadataSyncService(codexHome: codexHome).normalizedHashes()
        var extensionNames = ["skills", "plugins", "mcp"].filter {
            FileManager.default.fileExists(atPath: codexHome.appendingPathComponent($0).path)
        }
        if let config = try? String(contentsOf: codexHome.appendingPathComponent("config.toml")),
           config.contains("[mcp_servers") || config.contains("[mcp]") {
            extensionNames.append("mcp")
        }
        var extensionHashes: [String: String] = [:]
        for name in ["skills", "plugins", "mcp"] {
            for (path, hash) in try fileHashes(in: codexHome.appendingPathComponent(name)) {
                extensionHashes["\(name)/\(path)"] = hash
            }
        }
        return HistorySnapshot(
            totalThreads: total,
            visibleThreads: visible,
            activeThreadRoutingDigest: activeThreadRoutingDigest,
            archivedThreadRoutingDigest: archivedThreadRoutingDigest,
            sessionFileCount: sessionHashes.count,
            extensionPaths: Set(extensionNames),
            sessionHashes: sessionHashes,
            extensionHashes: extensionHashes,
            mcpConfigurationDigest: try mcpConfigurationDigest()
        )
    }

    /// Routes resumable conversations through the selected provider without changing their content or archive state.
    ///
    /// Current Codex runtimes persist per-thread model settings.  Those values override
    /// the root configuration for resumed conversations, so a provider transition must
    /// move them together with `model_provider`.
    @discardableResult
    public func synchronize(provider: String) throws -> Int {
        try synchronize(provider: provider, model: nil, reasoningEffort: nil, synchronizeRuntimeSettings: false)
    }

    /// Routes resumable conversations to one explicit runtime model configuration.
    @discardableResult
    public func synchronize(provider: String, model: String?, reasoningEffort: String?) throws -> Int {
        try synchronize(provider: provider, model: model, reasoningEffort: reasoningEffort, synchronizeRuntimeSettings: true)
    }

    /// Updates the SQLite route and rollout session metadata as one switch
    /// operation. Codex reads both surfaces while resuming a conversation.
    @discardableResult
    public func synchronizeConversationMetadata(provider: String, model: String?, reasoningEffort: String?) throws -> Int {
        let updatedThreads = try synchronize(
            provider: provider,
            model: model,
            reasoningEffort: reasoningEffort,
            synchronizeRuntimeSettings: true
        )
        _ = try SessionMetadataSyncService(codexHome: codexHome).synchronize(provider: provider)
        return updatedThreads
    }

    private func synchronize(
        provider: String,
        model: String?,
        reasoningEffort: String?,
        synchronizeRuntimeSettings: Bool
    ) throws -> Int {
        let dbURL = codexHome.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw HistorySyncError.openDatabase(dbURL.path)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw queryError(db) }
        do {
            let columns = try threadColumns(in: db)
            var assignments = ["model_provider = ?"]
            var bindings: [String?] = [provider]
            if synchronizeRuntimeSettings, columns.contains("model") {
                assignments.append("model = ?")
                bindings.append(model)
            }
            if synchronizeRuntimeSettings, columns.contains("reasoning_effort") {
                assignments.append("reasoning_effort = ?")
                bindings.append(reasoningEffort)
            }
            let providerPredicate = synchronizeRuntimeSettings ? "" : " AND model_provider IS NOT ?"
            if !synchronizeRuntimeSettings { bindings.append(provider) }
            let updated = try executeUpdate(
                "UPDATE threads SET \(assignments.joined(separator: ", ")) WHERE COALESCE(archived, 0) = 0\(providerPredicate)",
                bindings: bindings,
                db: db
            )
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw queryError(db) }
            return updated
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func verify(before: HistorySnapshot, after: HistorySnapshot) throws {
        guard before.totalThreads == after.totalThreads,
              before.visibleThreads == after.visibleThreads,
              before.activeThreadRoutingDigest == after.activeThreadRoutingDigest,
              before.archivedThreadRoutingDigest == after.archivedThreadRoutingDigest,
              before.sessionFileCount == after.sessionFileCount,
              before.extensionPaths == after.extensionPaths,
              before.sessionHashes == after.sessionHashes,
              before.extensionHashes == after.extensionHashes,
              before.mcpConfigurationDigest == after.mcpConfigurationDigest else {
            throw HistorySyncError.invariantChanged(before: before, after: after)
        }
    }

    public func verifySwitched(before: HistorySnapshot, after: HistorySnapshot, provider: String) throws {
        try verifySwitched(
            before: before,
            after: after,
            provider: provider,
            model: nil,
            reasoningEffort: nil,
            verifyRuntimeSettings: false
        )
    }

    public func verifySwitched(
        before: HistorySnapshot,
        after: HistorySnapshot,
        provider: String,
        model: String?,
        reasoningEffort: String?
    ) throws {
        try verifySwitched(
            before: before,
            after: after,
            provider: provider,
            model: model,
            reasoningEffort: reasoningEffort,
            verifyRuntimeSettings: true
        )
    }

    private func verifySwitched(
        before: HistorySnapshot,
        after: HistorySnapshot,
        provider: String,
        model: String?,
        reasoningEffort: String?,
        verifyRuntimeSettings: Bool
    ) throws {
        guard before.totalThreads == after.totalThreads,
              before.visibleThreads == after.visibleThreads,
              before.archivedThreadRoutingDigest == after.archivedThreadRoutingDigest,
              before.sessionFileCount == after.sessionFileCount,
              before.extensionPaths == after.extensionPaths,
              before.sessionHashes == after.sessionHashes,
              before.extensionHashes == after.extensionHashes,
              before.mcpConfigurationDigest == after.mcpConfigurationDigest,
              try activeThreadCount(
                notMatching: provider,
                model: model,
                reasoningEffort: reasoningEffort,
                verifyRuntimeSettings: verifyRuntimeSettings
              ) == 0 else {
            throw HistorySyncError.invariantChanged(before: before, after: after)
        }
    }

    private func threadRoutingDigest(database: URL, archived: Bool) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw HistorySyncError.openDatabase(database.path)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let availableColumns = try threadColumns(in: db)
        var selectedColumns = ["id", "model_provider"]
        if availableColumns.contains("model") { selectedColumns.append("model") }
        if availableColumns.contains("reasoning_effort") { selectedColumns.append("reasoning_effort") }
        let query = "SELECT \(selectedColumns.joined(separator: ", ")) FROM threads WHERE COALESCE(archived, 0) = ? ORDER BY id"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw queryError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, archived ? 1 : 0)
        var data = Data()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            for index in selectedColumns.indices {
                if let value = sqlite3_column_text(statement, Int32(index)) {
                    data.append(1)
                    data.append(Data(String(cString: value).utf8))
                } else {
                    data.append(0)
                }
                data.append(0)
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw queryError(db) }
        return digest(data)
    }

    private func mcpConfigurationDigest() throws -> String {
        let configuration = codexHome.appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: configuration.path) else { return digest(Data()) }
        let text = try String(contentsOf: configuration, encoding: .utf8)
        var captured: [String] = []
        var inMCPTable = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inMCPTable = trimmed == "[mcp]" || trimmed.hasPrefix("[mcp.") || trimmed.hasPrefix("[mcp_servers")
            }
            if inMCPTable && !trimmed.isEmpty {
                captured.append(String(line))
            }
        }
        return digest(Data(captured.joined(separator: "\n").utf8))
    }

    private func fileHashes(in root: URL, extension: String? = nil) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { url in
                guard isHashableFile(url, in: root) else { return false }
                return `extension`.map { url.pathExtension == $0 } ?? true
            } ?? []
        let rootPath = root.standardizedFileURL.path + "/"
        return try Dictionary(uniqueKeysWithValues: files.map { file in
            let relative = file.standardizedFileURL.path.replacingOccurrences(of: rootPath, with: "")
            let hash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            return (relative, hash)
        })
    }

    private func isHashableFile(_ url: URL, in root: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.standardizedFileURL.path + "/"
        guard resolved.path.hasPrefix(rootPath),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return false
        }
        return true
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    private func activeThreadCount(
        notMatching provider: String,
        model: String?,
        reasoningEffort: String?,
        verifyRuntimeSettings: Bool
    ) throws -> Int {
        let database = codexHome.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw HistorySyncError.openDatabase(database.path)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let columns = try threadColumns(in: db)
        var predicates = ["model_provider IS NOT ?"]
        var bindings: [String?] = [provider]
        if verifyRuntimeSettings, columns.contains("model") {
            predicates.append("model IS NOT ?")
            bindings.append(model)
        }
        if verifyRuntimeSettings, columns.contains("reasoning_effort") {
            predicates.append("reasoning_effort IS NOT ?")
            bindings.append(reasoningEffort)
        }
        let query = "SELECT COUNT(*) FROM threads WHERE COALESCE(archived, 0) = 0 AND (\(predicates.joined(separator: " OR ")))"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { throw queryError(db) }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw queryError(db) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func threadColumns(in db: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw queryError(db)
        }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { throw queryError(db) }
            columns.insert(String(cString: name))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw queryError(db) }
        return columns
    }

    private func execute(_ sql: String, bindings: [String?], db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw queryError(db) }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw queryError(db) }
    }

    private func bind(_ bindings: [String?], to statement: OpaquePointer) {
        for (index, value) in bindings.enumerated() {
            if let value {
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(statement, Int32(index + 1))
            }
        }
    }

    private func executeUpdate(_ sql: String, bindings: [String?], db: OpaquePointer) throws -> Int {
        try execute(sql, bindings: bindings, db: db)
        return Int(sqlite3_changes(db))
    }

    private func queryError(_ db: OpaquePointer) -> HistorySyncError {
        HistorySyncError.query(String(cString: sqlite3_errmsg(db)))
    }
}
