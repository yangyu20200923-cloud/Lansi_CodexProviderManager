import Foundation

public struct DiagnosticsSnapshot: Equatable, Sendable {
    public let activeProvider: String?
    public let history: HistorySnapshot?
    public let latestBackupDate: Date?
}

public final class DiagnosticsService: @unchecked Sendable {
    private let codexHome: URL

    public init(codexHome: URL) { self.codexHome = codexHome }

    public func inspect() throws -> DiagnosticsSnapshot {
        let configURL = codexHome.appendingPathComponent("config.toml")
        let provider = try? CodexConfigService().read(from: configURL).activeProvider
        let history = try? HistorySyncService(codexHome: codexHome).snapshot()
        let root = codexHome.appendingPathComponent("backups/CodexProviderManager")
        let latest = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
            .compactMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }.max()
        return DiagnosticsSnapshot(activeProvider: provider, history: history, latestBackupDate: latest ?? nil)
    }
}
