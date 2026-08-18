import AppKit
import Foundation
import ProviderCore
import UniformTypeIdentifiers

@MainActor
final class ProviderManagerViewModel: ObservableObject {
    @Published var profileSet: ProfileSet
    @Published var selectedID: ProviderID
    @Published var apiKeyDraft = ""
    @Published var isBusy = false
    @Published var isFetchingModels = false
    @Published var modelSearchQuery = ""
    @Published var modelCatalogDraft = ""
    @Published private(set) var upstreamModels: [String] = []
    @Published var managedModelSelection: Set<String> = []
    @Published var upstreamModelSelection: Set<String> = []
    @Published private(set) var isRefreshingDiagnostics = false
    @Published var statusMessage = "Ready"
    @Published var diagnostics: DiagnosticsSnapshot?
    @Published var validationIssues: [ValidationIssue] = []
    @Published private(set) var backupSummaries: [BackupSummary] = []

    private let store: ProfileStore
    let isIsolatedAcceptance: Bool
    private let keychain: any ProviderCredentialStoring
    private let runtimeController: any ProviderRuntimeControlling
    private let codexHome: URL
    private var fetchTask: Task<Void, Never>?
    private var backupService: BackupService {
        BackupService(backupRoot: codexHome.appendingPathComponent("backups/CodexProviderManager"))
    }
    private static let providerClipboardType = NSPasteboard.PasteboardType("com.codex.ProviderManager.profile+json")
    private static let jsonClipboardType = NSPasteboard.PasteboardType(UTType.json.identifier)
    /// Codex's on-device model list is bounded; upstream catalogs can be huge.
    /// The managed list is capped so a provider with thousands of models never
    /// floods the catalog. Users pick what to keep.
    static let maxCatalogModels = 100

    init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        profileStoreURL: URL? = nil,
        keychain: any ProviderCredentialStoring = ProviderCredentialStores.production(),
        runtimeController: any ProviderRuntimeControlling = ProviderRuntimeControllers.production(),
        isIsolatedAcceptance: Bool = false
    ) {
        self.store = ProfileStore(fileURL: profileStoreURL)
        self.keychain = keychain
        self.runtimeController = runtimeController
        self.isIsolatedAcceptance = isIsolatedAcceptance
        self.codexHome = codexHome
        var loaded = (try? store.load()) ?? ProfileSet()
        for index in loaded.profiles.indices where !loaded.profiles[index].isBuiltIn {
            let id = loaded.profiles[index].id
            loaded.profiles[index].hasStoredKey = (try? keychain.read(provider: id))?.isEmpty == false
        }
        if !loaded.profiles.contains(where: { $0.id == loaded.activeProvider }) {
            loaded.activeProvider = .openAI
        }
        if let active = (try? CodexConfigService().read(from: codexHome.appendingPathComponent("config.toml")))?.activeProvider,
           let profile = loaded.profiles.first(where: { $0.configProviderID == active }) {
            loaded.activeProvider = profile.id
        }
        profileSet = loaded
        selectedID = loaded.activeProvider
        Task { [weak self] in self?.refreshDiagnostics() }
    }

    var selectedIndex: Int { profileSet.profiles.firstIndex { $0.id == selectedID } ?? 0 }

    var selectedProfile: ProviderProfile {
        get { profileSet.profiles[selectedIndex] }
        set { profileSet.profiles[selectedIndex] = newValue; validate() }
    }

    func select(_ id: ProviderID) {
        selectedID = id
        apiKeyDraft = ""
        modelSearchQuery = ""
        managedModelSelection = []
        upstreamModelSelection = []
        validate()
    }

    var filteredModels: [String] {
        // Searches match both the managed list and the fetched-but-not-written
        // upstream draft so users can pick models without committing the whole
        // catalog. An empty query shows only the managed list.
        guard !modelSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return selectedProfile.models
        }
        var combined = selectedProfile.models
        var seen = Set(combined)
        for model in upstreamModels where !seen.contains(model) {
            combined.append(model)
            seen.insert(model)
        }
        return ModelCatalogService.matching(combined, query: modelSearchQuery)
    }

    func selectModel(_ model: String) {
        selectedProfile.model = model
        profileDidChange()
    }

    var isUpstreamFullyAdopted: Bool {
        !upstreamModels.isEmpty && upstreamModels.allSatisfy { selectedProfile.models.contains($0) }
    }

    func createCustomProvider() {
        let id = ProviderID.custom()
        profileSet.profiles.append(
            ProviderProfile(
                id: id,
                displayName: "New Provider",
                authMode: .apiKey,
                baseURL: nil,
                wireAPI: "responses",
                apiKeyEnvironment: nil,
                model: nil,
                isBuiltIn: false
            )
        )
        select(id)
        statusMessage = "Fill in the Provider details, then save or apply it."
    }

    func duplicateSelectedProfile() {
        guard !selectedProfile.isBuiltIn else { return }
        let previousProfiles = profileSet
        let duplicate = selectedProfile.duplicated()
        profileSet.profiles.append(duplicate)
        selectedID = duplicate.id
        apiKeyDraft = ""
        guard persistProfileSet(success: "Provider copied.") else {
            profileSet = previousProfiles
            selectedID = previousProfiles.activeProvider
            return
        }
        validate()
    }

    func toggleSelectedProfileEnabled() {
        guard !selectedProfile.isBuiltIn else { return }
        guard !selectedProfile.enabled || selectedProfile.id != profileSet.activeProvider else {
            statusMessage = "Apply another Provider before disabling the active one."
            return
        }
        let previousProfiles = profileSet
        profileSet.profiles[selectedIndex].enabled.toggle()
        let state = selectedProfile.enabled ? "enabled" : "disabled"
        guard persistProfileSet(success: "Provider \(state).") else {
            profileSet = previousProfiles
            return
        }
        validate()
    }

    func importProfile(from url: URL) {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }

        insertImportedProfile(data: try? Data(contentsOf: url), success: "Provider imported.", failurePrefix: "Import failed")
    }

    /// Copies only the portable, non-secret profile contract. API keys stay in Keychain.
    func copySelectedProfileToClipboard() {
        guard let data = exportSelectedProfile() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.providerClipboardType)
        pasteboard.setData(data, forType: Self.jsonClipboardType)
        statusMessage = "Provider copied to the clipboard without its API key."
    }

    func pasteProfileFromClipboard() {
        let pasteboard = NSPasteboard.general
        let data = pasteboard.data(forType: Self.providerClipboardType) ?? pasteboard.data(forType: Self.jsonClipboardType)
        insertImportedProfile(data: data, success: "Provider pasted without an API key.", failurePrefix: "Paste failed")
    }

    func exportSelectedProfile() -> Data? {
        guard !selectedProfile.isBuiltIn else {
            statusMessage = "Built-in Providers cannot be exported."
            return nil
        }
        do {
            return try ProfileTransfer.export(selectedProfile)
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    func completeExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            statusMessage = "Provider exported without its API key."
        case .failure(let error):
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func reportImportSelectionFailure(_ error: Error) {
        statusMessage = "Import failed: \(error.localizedDescription)"
    }

    func deleteCustomProvider(id: ProviderID) {
        guard let index = profileSet.profiles.firstIndex(where: { $0.id == id }),
              !profileSet.profiles[index].isBuiltIn else { return }
        guard profileSet.activeProvider != id else {
            statusMessage = "Apply another Provider before deleting the active one."
            return
        }
        let previousProfiles = profileSet
        profileSet.profiles.remove(at: index)
        selectedID = .openAI
        apiKeyDraft = ""
        guard persistProfileSet(success: "Provider deleted. OpenAI is selected.") else {
            profileSet = previousProfiles
            selectedID = id
            return
        }
        validate()
    }

    func saveProfile() {
        validate()
        guard validationIssues.isEmpty else {
            statusMessage = "Fix validation errors first."
            return
        }
        do {
            try store.save(profileSet)
            statusMessage = "Provider saved."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func restoreDefaults() {
        guard selectedID.isBuiltIn else { return }
        let storedKey = profileSet.profiles[selectedIndex].hasStoredKey
        var profile = ProviderDefaults.profile(for: selectedID)
        profile.hasStoredKey = storedKey
        profileSet.profiles[selectedIndex] = profile
        validate()
    }

    func importEnvironmentKey() {
        guard !isIsolatedAcceptance else {
            statusMessage = "Environment key import is unavailable in isolated verification mode."
            return
        }
        guard selectedProfile.requiresAPIKey else { return }
        guard let candidate = EnvironmentKeyImporter().candidate(
            for: selectedProfile.apiKeyEnvironment,
            provider: selectedID
        ) else { return }
        apiKeyDraft = candidate.value
        statusMessage = "Environment key is ready to save to Keychain."
    }

    func testConnection() async {
        guard !isIsolatedAcceptance else {
            statusMessage = "Connection tests are unavailable in isolated verification mode."
            return
        }
        guard selectedProfile.enabled else {
            statusMessage = "Enable the Provider before testing it."
            return
        }
        guard selectedProfile.requiresAPIKey else {
            statusMessage = "Connection tests require API key authentication."
            return
        }
        validate()
        guard validationIssues.isEmpty, selectedID != .openAI else {
            statusMessage = selectedID == .openAI ? "OpenAI uses the existing ChatGPT login." : "Fix validation errors first."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let key = apiKeyDraft.isEmpty ? try keychain.read(provider: selectedID) : apiKeyDraft
            guard let key, !key.isEmpty, let base = selectedProfile.baseURL, let url = responseEndpoint(baseURL: base) else {
                statusMessage = "An API key and valid Base URL are required."
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": selectedProfile.model ?? "gpt-5.5", "input": "Reply with OK.", "max_output_tokens": 8])
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            statusMessage = (200..<300).contains(code) ? "Connection successful." : "Connection failed with HTTP \(code)."
        } catch {
            statusMessage = "Connection failed: \(error.localizedDescription)"
        }
    }

    func apply() async {
        guard selectedProfile.enabled else {
            statusMessage = "Enable the Provider before applying it."
            return
        }
        validate()
        guard validationIssues.isEmpty else { statusMessage = "Fix validation errors first."; return }
        isBusy = true
        defer { isBusy = false }
        do {
            if selectedProfile.requiresAPIKey && !apiKeyDraft.isEmpty {
                try keychain.write(key: apiKeyDraft, for: selectedID)
                profileSet.profiles[selectedIndex].hasStoredKey = true
                apiKeyDraft = ""
            }
            try store.save(profileSet)
            let result = await ProviderSwitchCoordinator(
                codexHome: codexHome,
                keychain: keychain,
                chatGPT: runtimeController
            ).apply(
                target: selectedProfile,
                availableProfiles: profileSet.profiles,
                onPhase: { _, message in
                    Task { @MainActor in self.statusMessage = message }
                }
            )
            statusMessage = result.message
            diagnostics = result.diagnostics
            if result.succeeded {
                profileSet.activeProvider = selectedID
                try store.save(profileSet)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    var hasLatestBackup: Bool { diagnostics?.latestBackupDate != nil }

    func refreshBackupSummaries() {
        let summaries = (try? backupService.backupSummaries(codexHome: codexHome)) ?? []
        backupSummaries = summaries
        // Backups created before the logical-size field existed report zero;
        // compute those sizes in the background so the management panel shows
        // real numbers without blocking the UI.
        let home = codexHome
        Task.detached(priority: .userInitiated) {
            var updated = summaries
            var changed = false
            for index in updated.indices where updated[index].logicalBytes == 0 {
                let url = home.appendingPathComponent("backups/CodexProviderManager")
                    .appendingPathComponent(updated[index].backupID)
                updated[index] = BackupSummary(
                    backupID: updated[index].backupID,
                    createdAt: updated[index].createdAt,
                    logicalBytes: BackupService.logicalSize(of: url),
                    isPinned: updated[index].isPinned
                )
                changed = true
            }
            if changed {
                let result = updated
                await MainActor.run { self.backupSummaries = result }
            }
        }
    }

    var backupTotalBytes: Int64 {
        backupSummaries.reduce(0) { $0 + $1.logicalBytes }
    }

    func deleteBackup(id: String) {
        do {
            try backupService.delete(backupID: id, codexHome: codexHome)
            statusMessage = "Backup \(id) deleted."
        } catch {
            statusMessage = "Failed to delete backup: \(error.localizedDescription)"
        }
        refreshBackupSummaries()
    }

    func setBackupPinned(id: String, pinned: Bool) {
        do {
            try backupService.setPinned(backupID: id, isPinned: pinned, codexHome: codexHome)
        } catch {
            statusMessage = "Failed to update backup pin: \(error.localizedDescription)"
        }
        refreshBackupSummaries()
    }

    func pruneOldBackups() {
        do {
            try backupService.pruneNow(codexHome: codexHome)
            statusMessage = "Old backups cleaned up per retention policy."
        } catch {
            statusMessage = "Failed to clean up old backups: \(error.localizedDescription)"
        }
        refreshBackupSummaries()
    }

    func restoreLatestBackup() async {
        isBusy = true
        defer { isBusy = false }
        let result = await ProviderSwitchCoordinator(
            codexHome: codexHome,
            keychain: keychain,
            chatGPT: runtimeController
        ).restoreLatest(availableProfiles: profileSet.profiles)
        statusMessage = result.message
        diagnostics = result.diagnostics
        guard result.succeeded,
              let active = result.diagnostics?.activeProvider,
              let restoredProfile = profileSet.profiles.first(where: { $0.configProviderID == active }) else { return }
        profileSet.activeProvider = restoredProfile.id
        selectedID = restoredProfile.id
        do {
            try store.save(profileSet)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func validate() { validationIssues = ProviderValidator.validate(selectedProfile) }

    func profileDidChange() { validate() }

    func fetchModelsFromUpstream() async {
        fetchTask?.cancel()
        let task = Task { await self.performModelFetch() }
        fetchTask = task
        await task.value
    }

    func cancelModelFetch() {
        fetchTask?.cancel()
        fetchTask = nil
        isFetchingModels = false
    }

    private func performModelFetch() async {
        guard !isIsolatedAcceptance else {
            statusMessage = "Model fetching is unavailable in isolated verification mode."
            return
        }
        guard selectedProfile.requiresAPIKey else {
            statusMessage = "Model fetching requires API key authentication."
            return
        }
        guard let baseURL = selectedProfile.baseURL, !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Enter a Base URL before fetching models."
            return
        }
        isFetchingModels = true
        defer { isFetchingModels = false }
        do {
            let key = apiKeyDraft.isEmpty ? try keychain.read(provider: selectedID) : apiKeyDraft
            guard let key, !key.isEmpty else { throw ModelCatalogError.missingAPIKey }
            let models = try await ModelCatalogService().fetch(baseURL: baseURL, apiKey: key)
            guard !Task.isCancelled else { return }
            upstreamModels = models
            // Never flood the managed model list. The fetched catalog is kept
            // as a draft: users search it, use a model directly, or add all of
            // it with an explicit action.
            statusMessage = "Fetched \(models.count) upstream models. Search and pick the ones to use, or add them to the model list."
        } catch {
            guard !Task.isCancelled else {
                statusMessage = "Model fetch cancelled."
                return
            }
            statusMessage = "Model fetch failed: \(error.localizedDescription)"
        }
        validate()
    }

    func adoptAllUpstreamModels() {
        var merged = selectedProfile.models
        var seen = Set(merged)
        for model in upstreamModels where !seen.contains(model) {
            merged.append(model)
            seen.insert(model)
        }
        let overflow = merged.count - Self.maxCatalogModels
        if overflow > 0 {
            merged = Array(merged.prefix(Self.maxCatalogModels))
            statusMessage = "Model list limit (\(Self.maxCatalogModels)) reached; the first \(Self.maxCatalogModels) models were added."
        } else {
            statusMessage = "Added all \(upstreamModels.count) upstream models to the model list."
        }
        selectedProfile.models = merged
        _ = persistProfileSet(success: statusMessage)
        validate()
    }

    func ignoreUpstreamModels() {
        upstreamModels = []
        statusMessage = "Fetched models ignored."
        validate()
    }

    func addModelToCatalog(_ model: String) {
        guard !selectedProfile.models.contains(model) else {
            statusMessage = "\(model) is already in the model list."
            return
        }
        guard selectedProfile.models.count < Self.maxCatalogModels else {
            statusMessage = "Model list limit (\(Self.maxCatalogModels)) reached. Remove a model before adding another."
            return
        }
        selectedProfile.models.append(model)
        _ = persistProfileSet(success: "\(model) added to the model list.")
        validate()
    }

    func addModelsToCatalog(_ models: [String]) {
        var merged = selectedProfile.models
        var seen = Set(merged)
        var added = 0
        for model in models where !model.isEmpty {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            if merged.count >= Self.maxCatalogModels { break }
            merged.append(trimmed)
            seen.insert(trimmed)
            added += 1
        }
        let dropped = models.count - added
        selectedProfile.models = merged
        if dropped > 0 {
            statusMessage = "Added \(added) models; \(dropped) were already present or the list limit (\(Self.maxCatalogModels)) was reached."
        } else {
            statusMessage = "Added \(added) model\(added == 1 ? "" : "s") to the model list."
        }
        _ = persistProfileSet(success: statusMessage)
        upstreamModelSelection = []
        validate()
    }

    func removeModelsFromCatalog(_ models: [String]) {
        let removed = Set(models)
        selectedProfile.models.removeAll { removed.contains($0) }
        if let current = selectedProfile.model, removed.contains(current) {
            // Keep the current model usable: switch to another managed model
            // when one remains, otherwise keep it so the form and Codex stay
            // non-empty instead of going blank.
            selectedProfile.model = selectedProfile.models.first ?? current
        }
        managedModelSelection = managedModelSelection.subtracting(removed)
        _ = persistProfileSet(success: "Removed \(models.count) model\(models.count == 1 ? "" : "s") from the model list.")
        validate()
    }

    func clearModelCatalog() {
        selectedProfile.models = []
        managedModelSelection = []
        _ = persistProfileSet(success: "Cleared the model list. The current model stays selected.")
        validate()
    }

    func removeModelFromCatalog(_ model: String) {
        removeModelsFromCatalog([model])
    }

    func toggleManagedSelection(_ model: String) {
        if managedModelSelection.contains(model) {
            managedModelSelection.remove(model)
        } else {
            managedModelSelection.insert(model)
        }
    }

    func toggleUpstreamSelection(_ model: String) {
        if upstreamModelSelection.contains(model) {
            upstreamModelSelection.remove(model)
        } else {
            upstreamModelSelection.insert(model)
        }
    }

    func selectAllManaged() {
        managedModelSelection = Set(filteredManagedModels)
    }

    func selectAllUpstream() {
        upstreamModelSelection = Set(filteredUpstreamModels)
    }

    var filteredManagedModels: [String] {
        ModelCatalogService.matching(selectedProfile.models, query: modelSearchQuery)
    }

    var filteredUpstreamModels: [String] {
        ModelCatalogService.matching(upstreamModels, query: modelSearchQuery)
    }

    func refreshDiagnostics() {
        guard !isRefreshingDiagnostics else { return }
        isRefreshingDiagnostics = true
        let home = codexHome
        Task { [weak self] in
            let snapshot: DiagnosticsSnapshot? = await Task.detached(priority: .utility) {
                try? DiagnosticsService(codexHome: home).inspect()
            }.value
            guard let self else { return }
            diagnostics = snapshot
            isRefreshingDiagnostics = false
        }
    }

    private func persistProfileSet(success: String) -> Bool {
        do {
            try store.save(profileSet)
            statusMessage = success
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func insertImportedProfile(data: Data?, success: String, failurePrefix: String) {
        guard let data else {
            statusMessage = "\(failurePrefix): the clipboard or selected file does not contain a Provider profile."
            return
        }
        do {
            var profile = try ProfileTransfer.importProfile(from: data)
            if profileSet.profiles.contains(where: { $0.id == profile.id }) {
                profile = profile.duplicated()
            }
            let previousProfiles = profileSet
            let previousSelection = selectedID
            profileSet.profiles.append(profile)
            selectedID = profile.id
            apiKeyDraft = ""
            guard persistProfileSet(success: success) else {
                profileSet = previousProfiles
                selectedID = previousSelection
                return
            }
            validate()
        } catch {
            statusMessage = "\(failurePrefix): \(error.localizedDescription)"
        }
    }

    private func responseEndpoint(baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let parsed = URL(string: trimmed) else { return nil }
        let suffix = parsed.path.isEmpty || parsed.path == "/" ? "/v1/responses" : "/responses"
        return URL(string: trimmed + suffix)
    }
}
