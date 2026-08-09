import Foundation

public enum SwitchPhase: String, Sendable {
    case validating, backingUp, quitting, applying, verifying, launching, recovering, complete
}

public struct SwitchResult: Sendable {
    public let succeeded: Bool
    public let phase: SwitchPhase
    public let diagnostics: DiagnosticsSnapshot?
    public let backup: BackupManifest?
    public let message: String
}

public final class ProviderSwitchCoordinator: @unchecked Sendable {
    private let codexHome: URL
    private let keychain: KeychainService
    private let chatGPT: ChatGPTService
    private let backupService: BackupService

    public init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        keychain: KeychainService = KeychainService(),
        chatGPT: ChatGPTService = ChatGPTService(),
        backupService: BackupService = BackupService()
    ) {
        self.codexHome = codexHome
        self.keychain = keychain
        self.chatGPT = chatGPT
        self.backupService = backupService
    }

    public func apply(target profile: ProviderProfile) async -> SwitchResult {
        let issues = ProviderValidator.validate(profile)
        guard issues.isEmpty else {
            return SwitchResult(succeeded: false, phase: .validating, diagnostics: nil, backup: nil, message: issues.map(\.message).joined(separator: " "))
        }

        let history = HistorySyncService(codexHome: codexHome)
        var backup: BackupManifest?
        var previousKeyProvider: ProviderID = .openAI
        do {
            let lock = try SwitchLock.acquire(in: codexHome)
            defer { try? lock.release() }
            let before = try history.snapshot()
            if let raw = try CodexConfigService().read(from: codexHome.appendingPathComponent("config.toml")).activeProvider,
               let id = ProviderID(rawValue: raw) { previousKeyProvider = id }
            backup = try backupService.create(codexHome: codexHome)
            try await chatGPT.quit()
            try await chatGPT.waitUntilQuiescent()
            let key = profile.isBuiltIn ? nil : try keychain.read(provider: profile.id)
            if !profile.isBuiltIn && (key?.isEmpty != false) {
                throw KeychainError.invalidData
            }
            try CodexConfigService().apply(profile: profile, to: codexHome.appendingPathComponent("config.toml"))
            try history.synchronize(provider: profile.id)
            try chatGPT.setEnvironment(provider: profile.id, key: key)
            let after = try history.snapshot()
            try history.verify(before: before, after: after)
            try await chatGPT.launch()
            let diagnostics = try DiagnosticsService(codexHome: codexHome).inspect()
            return SwitchResult(succeeded: true, phase: .complete, diagnostics: diagnostics, backup: backup, message: "Provider switched successfully.")
        } catch {
            guard let backup else {
                return SwitchResult(succeeded: false, phase: .recovering, diagnostics: nil, backup: nil, message: String(describing: error))
            }
            do {
                try backupService.restore(backup, to: codexHome)
                try chatGPT.setEnvironment(provider: previousKeyProvider, key: previousKeyProvider == .openAI ? nil : try keychain.read(provider: previousKeyProvider))
                try await chatGPT.launch()
                return SwitchResult(succeeded: false, phase: .recovering, diagnostics: try? DiagnosticsService(codexHome: codexHome).inspect(), backup: backup, message: "Switch failed and the previous state was restored: \(error)")
            } catch let recoveryError {
                return SwitchResult(succeeded: false, phase: .recovering, diagnostics: nil, backup: backup, message: "Switch and automatic recovery failed. Backup: \(backup.backupID). Error: \(recoveryError)")
            }
        }
    }
}
