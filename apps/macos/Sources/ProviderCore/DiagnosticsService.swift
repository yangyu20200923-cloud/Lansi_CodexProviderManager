import Foundation
import SQLite3

public enum HistoryDiagnosticsIssue: String, Equatable, Sendable {
    case stateDatabaseMissing
    case stateDatabaseUnreadable
    case threadsUnavailable
}

public struct ActivityDiagnostics: Equatable, Sendable {
    public let threadCount: Int?
    public let sessionFileCount: Int
    public let skillCount: Int
    public let pluginCount: Int
    public let mcpServerCount: Int
    public let mcpFileCount: Int
    public let historyIssue: HistoryDiagnosticsIssue?
}

public struct DiagnosticsSnapshot: Equatable, Sendable {
    public let activeProvider: String?
    public let history: HistorySnapshot?
    public let activity: ActivityDiagnostics
    public let latestBackupDate: Date?
}

public final class DiagnosticsService: @unchecked Sendable {
    private let codexHome: URL

    public init(codexHome: URL) { self.codexHome = codexHome }

    /// A full preservation snapshot hashes every session and extension file. The status panel only
    /// needs lightweight activity counts, so callers opt in when that expensive evidence is needed.
    public func inspect(includePreservationSnapshot: Bool = false) throws -> DiagnosticsSnapshot {
        let configURL = codexHome.appendingPathComponent("config.toml")
        let provider = try? CodexConfigService().read(from: configURL).activeProvider
        let history = includePreservationSnapshot ? try? HistorySyncService(codexHome: codexHome).snapshot() : nil
        let activity = inspectActivity()
        let root = codexHome.appendingPathComponent("backups/CodexProviderManager")
        let latest = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
            .compactMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }.max()
        return DiagnosticsSnapshot(activeProvider: provider, history: history, activity: activity, latestBackupDate: latest ?? nil)
    }

    private func inspectActivity() -> ActivityDiagnostics {
        let history = threadCount()
        let configuration = codexHome.appendingPathComponent("config.toml")
        return ActivityDiagnostics(
            threadCount: history.count,
            sessionFileCount: fileCount(in: codexHome.appendingPathComponent("sessions"), withExtension: "jsonl"),
            skillCount: fileCount(in: codexHome.appendingPathComponent("skills"), named: "SKILL.md"),
            pluginCount: fileCount(in: codexHome.appendingPathComponent("plugins"), named: "plugin.json"),
            mcpServerCount: mcpServerCount(in: configuration),
            mcpFileCount: fileCount(in: codexHome.appendingPathComponent("mcp"), withExtension: "json"),
            historyIssue: history.issue
        )
    }

    private func threadCount() -> (count: Int?, issue: HistoryDiagnosticsIssue?) {
        let databaseURL = codexHome.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return (nil, .stateDatabaseMissing)
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            return (nil, .stateDatabaseUnreadable)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM threads", -1, &statement, nil) == SQLITE_OK, let statement else {
            return (nil, .threadsUnavailable)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return (nil, .threadsUnavailable)
        }
        return (Int(sqlite3_column_int64(statement, 0)), nil)
    }

    private func mcpServerCount(in configurationURL: URL) -> Int {
        guard let text = try? String(contentsOf: configurationURL, encoding: .utf8) else { return 0 }
        return Set(text.split(separator: "\n").compactMap { line -> String? in
            let table = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard table.hasPrefix("[mcp_servers."), table.hasSuffix("]") else { return nil }
            return String(table.dropFirst("[mcp_servers.".count).dropLast())
        }).count
    }

    private func fileCount(in root: URL, named fileName: String? = nil, withExtension pathExtension: String? = nil) -> Int {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        let rootPath = root.standardizedFileURL.path + "/"
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var count = 0
        while let candidate = enumerator.nextObject() as? URL {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(rootPath),
                  (try? resolved.resourceValues(forKeys: keys).isRegularFile) == true else { continue }
            if let fileName, candidate.lastPathComponent != fileName { continue }
            if let pathExtension, candidate.pathExtension.caseInsensitiveCompare(pathExtension) != .orderedSame { continue }
            count += 1
        }
        return count
    }
}
