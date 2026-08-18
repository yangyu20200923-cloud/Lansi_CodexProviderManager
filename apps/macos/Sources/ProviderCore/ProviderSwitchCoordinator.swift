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

/// Abstracts the upstream `/models` fetch so switches remain testable offline.
public protocol ModelListFetching: Sendable {
    func fetch(baseURL: String, apiKey: String) async throws -> [String]
}

extension ModelCatalogService: ModelListFetching {}

public final class ProviderSwitchCoordinator: @unchecked Sendable {
    private let codexHome: URL
    private let keychain: any ProviderCredentialStoring
    private let chatGPT: any ProviderRuntimeControlling
    private let backupService: BackupService
    private let openAIBaselineStore: OpenAIConfigurationBaselineStore
    private let modelFetcher: any ModelListFetching
    private let logSink: (String) -> Void

    public init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        keychain: any ProviderCredentialStoring = ProviderCredentialStores.production(),
        chatGPT: any ProviderRuntimeControlling = ProviderRuntimeControllers.production(),
        backupService: BackupService = BackupService(),
        openAIBaselineStore: OpenAIConfigurationBaselineStore = OpenAIConfigurationBaselineStore(),
        modelFetcher: any ModelListFetching = ModelCatalogService(),
        logSink: ((String) -> Void)? = nil
    ) {
        self.codexHome = codexHome
        self.keychain = keychain
        self.chatGPT = chatGPT
        self.backupService = backupService
        self.openAIBaselineStore = openAIBaselineStore
        self.modelFetcher = modelFetcher
        self.logSink = logSink ?? { ProviderSwitchCoordinator.appendLog($0, codexHome: codexHome) }
    }

    /// Appends one timestamped line to `state/switch.log` under the managed
    /// Codex home so a failed real-machine switch can be diagnosed from the
    /// log instead of requiring a live reproduction.
    private static func appendLog(_ message: String, codexHome: URL) {
        let url = codexHome.appendingPathComponent("state/switch.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
            return
        }
        try? data.write(to: url)
    }

    private func logSwitch(_ message: String) {
        logSink(message)
    }

    public func apply(
        target profile: ProviderProfile,
        availableProfiles: [ProviderProfile] = ProviderDefaults.all,
        onPhase: ((SwitchPhase, String) -> Void)? = nil
    ) async -> SwitchResult {
        let issues = ProviderValidator.validate(profile)
        guard issues.isEmpty else {
            logSwitch("switch rejected during validation: \(issues.map(\.message).joined(separator: " "))")
            return SwitchResult(succeeded: false, phase: .validating, diagnostics: nil, backup: nil, message: issues.map(\.message).joined(separator: " "))
        }

        let history = HistorySyncService(codexHome: codexHome)
        var backup: BackupManifest?
        var previousProfile = ProviderDefaults.profile(for: .openAI)
        var launchedTargetRuntime = false
        do {
            logSwitch("switch start: target=\(profile.configProviderID) display=\(profile.displayName)")
            onPhase?(.quitting, "正在关闭 ChatGPT/Codex 运行环境…")
            let lock = try SwitchLock.acquire(in: codexHome)
            defer { try? lock.release() }
            try await chatGPT.quit()
            try await chatGPT.waitUntilQuiescent(timeout: 15)
            logSwitch("runtime quit and quiescent")
            // Third-party responses sources may have stored plaintext reasoning
            // content in rollout logs; strict Providers reject it on replay.
            // Normalize it before snapshotting and backing up so the repair is
            // part of the managed switch state: existing conversations keep
            // working after the switch without deleting any conversation
            // content, and preservation verification stays strict.
            let compat = try SessionCompatService(codexHome: codexHome).normalizeReasoningContent()
            logSwitch("normalized \(compat.normalizedItems) reasoning entries across \(compat.normalizedFiles) of \(compat.filesScanned) session files")
            onPhase?(.backingUp, "正在备份 Codex 环境（\(compat.filesScanned) 个会话文件，快照复制仅需数秒）…")
            let before = try history.snapshot()
            let configURL = codexHome.appendingPathComponent("config.toml")
            let currentConfig = try CodexConfigService().read(from: configURL)
            if let raw = currentConfig.activeProvider,
               let profile = availableProfiles.first(where: { $0.configProviderID == raw }) {
                previousProfile = profile
            }
            backup = try backupService.create(codexHome: codexHome)
            logSwitch("backup created: \(backup?.backupID ?? "unknown")")
            if currentConfig.activeProvider == ProviderID.openAI.rawValue, profile.id != .openAI {
                try openAIBaselineStore.save(CodexConfigService().openAIConfigurationBaseline(from: currentConfig))
                logSwitch("openai baseline saved")
            }
            let key = profile.requiresAPIKey ? try keychain.read(provider: profile.id) : nil
            if profile.requiresAPIKey && (key?.isEmpty != false) {
                throw KeychainError.invalidData
            }
            let catalogSlugs = await Self.resolveModelCatalog(
                profile: profile,
                key: key,
                fetcher: modelFetcher
            )
            let openAIBaseline = profile.id == .openAI
                ? ((try? openAIBaselineStore.load()) ?? backupService.latestOpenAIConfigurationBaseline(codexHome: codexHome))
                : nil
            try CodexConfigService().apply(
                profile: profile,
                to: configURL,
                openAIBaseline: openAIBaseline,
                managesModelCatalog: true,
                modelCatalogSlugs: catalogSlugs
            )
            logSwitch("config applied: model_provider=\(profile.configProviderID)")
            let appliedConfiguration = try CodexConfigService().read(from: configURL)
            let threadSettings = CodexConfigService().openAIConfigurationBaseline(from: appliedConfiguration)
            try history.synchronizeConversationMetadata(
                provider: profile.configProviderID,
                model: threadSettings.model,
                reasoningEffort: threadSettings.reasoningEffort
            )
            try SessionMetadataSyncService(codexHome: codexHome).verify(provider: profile.configProviderID)
            try chatGPT.setEnvironment(profile: profile, key: key)
            logSwitch("environment set for \(profile.configProviderID)")
            onPhase?(.verifying, "正在校验目标 Provider 配置…")
            try chatGPT.verifyConfiguration(codexHome: codexHome, profile: profile, key: key)
            logSwitch("configuration verified for \(profile.configProviderID)")
            let after = try history.snapshot()
            try history.verifySwitched(
                before: before,
                after: after,
                provider: profile.configProviderID,
                model: threadSettings.model,
                reasoningEffort: threadSettings.reasoningEffort
            )
            try await chatGPT.launch()
            launchedTargetRuntime = true
            logSwitch("runtime launch requested")
            onPhase?(.launching, "正在重启 ChatGPT/Codex…")
            try await chatGPT.verifyLaunchedRuntime(profile: profile)
            logSwitch("runtime launch verified")
            let diagnostics = try DiagnosticsService(codexHome: codexHome).inspect()
            let compatNote = compat.normalizedItems > 0
                ? " \(compat.normalizedItems) reasoning entries across \(compat.normalizedFiles) session files were normalized for cross-Provider compatibility."
                : ""
            let message: String
            if profile.id == .openAI {
                message = "Provider switched successfully." + compatNote
            } else {
                message = "Provider switched successfully. The managed model list stays active; use Fetch Models to choose more. Existing conversations were routed to the selected Provider and model; you can continue asking in the original conversation." + compatNote
            }
            logSwitch("switch complete: target=\(profile.configProviderID)")
            return SwitchResult(succeeded: true, phase: .complete, diagnostics: diagnostics, backup: backup, message: message)
        } catch {
            logSwitch("switch failed: \(error.localizedDescription)")
            guard let backup else {
                return SwitchResult(succeeded: false, phase: .recovering, diagnostics: nil, backup: nil, message: String(describing: error))
            }
            do {
                // A failed post-launch verification means a process may still have the target
                // configuration open. Quiesce it before replacing files with the backup.
                if launchedTargetRuntime {
                    try? await chatGPT.quit()
                    try? await chatGPT.waitUntilQuiescent(timeout: 15)
                }
                try backupService.restore(backup, to: codexHome)
                logSwitch("recovery restored backup \(backup.backupID)")
                try ModelCatalogRenderer.synchronize(for: previousProfile, codexHome: codexHome)
                let previousKey = previousProfile.requiresAPIKey ? try keychain.read(provider: previousProfile.id) : nil
                try chatGPT.setEnvironment(profile: previousProfile, key: previousKey)
                try chatGPT.verifyConfiguration(codexHome: codexHome, profile: previousProfile, key: previousKey)
                try await chatGPT.launch()
                try await chatGPT.verifyLaunchedRuntime(profile: previousProfile)
                logSwitch("recovery complete: restored \(previousProfile.configProviderID)")
                return SwitchResult(succeeded: false, phase: .recovering, diagnostics: try? DiagnosticsService(codexHome: codexHome).inspect(), backup: backup, message: "Switch failed and the previous state was restored: \(error.localizedDescription)")
            } catch let recoveryError {
                logSwitch("recovery failed: \(recoveryError.localizedDescription)")
                return SwitchResult(succeeded: false, phase: .recovering, diagnostics: nil, backup: backup, message: "Switch and automatic recovery failed. Backup: \(backup.backupID). Error: \(recoveryError)")
            }
        }
    }

    private static func resolveModelCatalog(
        profile: ProviderProfile,
        key: String?,
        fetcher: any ModelListFetching
    ) async -> [String] {
        guard profile.id != .openAI else { return [] }
        let configured = ModelCatalogRenderer.slugs(profile: profile)
        // The upstream catalog is fetched only through the UI's "Fetch models"
        // action and is never injected into the managed model list
        // automatically. A switch keeps exactly the models the user chose;
        // guessing which upstream models are usable would flood Codex's
        // bounded on-device model list.
        _ = key
        _ = fetcher
        return configured
    }

    /// Restores the latest verified backup and rolls back to the current state if restoration cannot complete.
    public func restoreLatest(
        availableProfiles: [ProviderProfile] = ProviderDefaults.all,
        onPhase: ((SwitchPhase, String) -> Void)? = nil
    ) async -> SwitchResult {
        var recoveryBackup: BackupManifest?
        var currentProfile = ProviderDefaults.profile(for: .openAI)
        var launchedRestoredRuntime = false
        do {
            let lock = try SwitchLock.acquire(in: codexHome)
            defer { try? lock.release() }
            guard let targetBackup = try backupService.latestBackup(codexHome: codexHome) else {
                return SwitchResult(succeeded: false, phase: .recovering, diagnostics: nil, backup: nil, message: "No backup is available to restore.")
            }
            if let raw = try CodexConfigService().read(from: codexHome.appendingPathComponent("config.toml")).activeProvider,
               let profile = availableProfiles.first(where: { $0.configProviderID == raw }) {
                currentProfile = profile
            }
            recoveryBackup = try backupService.create(codexHome: codexHome)
            onPhase?(.recovering, "正在恢复上次切换前的 Codex 环境…")
            try await chatGPT.quit()
            try await chatGPT.waitUntilQuiescent(timeout: 15)
            try backupService.restore(targetBackup, to: codexHome)
            guard let restoredID = try CodexConfigService().read(from: codexHome.appendingPathComponent("config.toml")).activeProvider,
                  let restoredProfile = availableProfiles.first(where: { $0.configProviderID == restoredID }) else {
                throw RestoreFailure.profileUnavailable
            }
            try ModelCatalogRenderer.synchronize(for: restoredProfile, codexHome: codexHome)
            let key = restoredProfile.requiresAPIKey ? try keychain.read(provider: restoredProfile.id) : nil
            if restoredProfile.requiresAPIKey && (key?.isEmpty != false) {
                throw KeychainError.invalidData
            }
            try chatGPT.setEnvironment(profile: restoredProfile, key: key)
            try chatGPT.verifyConfiguration(codexHome: codexHome, profile: restoredProfile, key: key)
            try await chatGPT.launch()
            launchedRestoredRuntime = true
            try await chatGPT.verifyLaunchedRuntime(profile: restoredProfile)
            return SwitchResult(
                succeeded: true,
                phase: .complete,
                diagnostics: try DiagnosticsService(codexHome: codexHome).inspect(),
                backup: targetBackup,
                message: "Latest backup restored."
            )
        } catch {
            guard let recoveryBackup else {
                return SwitchResult(succeeded: false, phase: .recovering, diagnostics: nil, backup: nil, message: String(describing: error))
            }
            do {
                if launchedRestoredRuntime {
                    try? await chatGPT.quit()
                    try? await chatGPT.waitUntilQuiescent(timeout: 15)
                }
                try backupService.restore(recoveryBackup, to: codexHome)
                let key = currentProfile.requiresAPIKey ? try keychain.read(provider: currentProfile.id) : nil
                try chatGPT.setEnvironment(profile: currentProfile, key: key)
                try chatGPT.verifyConfiguration(codexHome: codexHome, profile: currentProfile, key: key)
                try await chatGPT.launch()
                try await chatGPT.verifyLaunchedRuntime(profile: currentProfile)
                return SwitchResult(succeeded: false, phase: .recovering, diagnostics: try? DiagnosticsService(codexHome: codexHome).inspect(), backup: recoveryBackup, message: "Restore failed and the previous state was restored: \(error)")
            } catch let recoveryError {
                return SwitchResult(succeeded: false, phase: .recovering, diagnostics: nil, backup: recoveryBackup, message: "Restore and automatic recovery failed. Backup: \(recoveryBackup.backupID). Error: \(recoveryError)")
            }
        }
    }
}

private enum RestoreFailure: Error { case profileUnavailable }
