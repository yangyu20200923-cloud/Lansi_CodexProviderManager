import Foundation
import ProviderCore

@MainActor
final class ProviderManagerViewModel: ObservableObject {
    @Published var profileSet: ProfileSet
    @Published var selectedID: ProviderID
    @Published var apiKeyDraft = ""
    @Published var isBusy = false
    @Published var statusMessage = "Ready"
    @Published var diagnostics: DiagnosticsSnapshot?
    @Published var validationIssues: [ValidationIssue] = []

    private let store = ProfileStore()
    private let keychain = KeychainService()
    private let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")

    init() {
        var loaded = (try? store.load()) ?? ProfileSet()
        for id in [ProviderID.qilin, .vectorEngine] {
            if let index = loaded.profiles.firstIndex(where: { $0.id == id }) {
                loaded.profiles[index].hasStoredKey = (try? keychain.read(provider: id))?.isEmpty == false
            }
        }
        if let inspected = try? DiagnosticsService(codexHome: codexHome).inspect(),
           let active = inspected.activeProvider,
           let id = ProviderID(rawValue: active) {
            loaded.activeProvider = id
        }
        profileSet = loaded
        selectedID = loaded.activeProvider
        refreshDiagnostics()
    }

    var selectedIndex: Int { profileSet.profiles.firstIndex { $0.id == selectedID } ?? 0 }

    var selectedProfile: ProviderProfile {
        get { profileSet.profiles[selectedIndex] }
        set { profileSet.profiles[selectedIndex] = newValue; validate() }
    }

    func select(_ id: ProviderID) {
        selectedID = id
        apiKeyDraft = ""
        validate()
    }

    func restoreDefaults() {
        let storedKey = profileSet.profiles[selectedIndex].hasStoredKey
        var profile = ProviderDefaults.profile(for: selectedID)
        profile.hasStoredKey = storedKey
        profileSet.profiles[selectedIndex] = profile
        validate()
    }

    func importEnvironmentKey() {
        guard let candidate = EnvironmentKeyImporter().candidate(for: selectedID) else { return }
        apiKeyDraft = candidate.value
            statusMessage = "Environment key is ready to save to Keychain."
    }

    func testConnection() async {
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
        validate()
        guard validationIssues.isEmpty else { statusMessage = "Fix validation errors first."; return }
        isBusy = true
        defer { isBusy = false }
        do {
            if selectedID != .openAI && !apiKeyDraft.isEmpty {
                try keychain.write(key: apiKeyDraft, for: selectedID)
                profileSet.profiles[selectedIndex].hasStoredKey = true
                apiKeyDraft = ""
            }
            try store.save(profileSet)
            let result = await ProviderSwitchCoordinator(codexHome: codexHome, keychain: keychain).apply(target: selectedProfile)
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

    func validate() { validationIssues = ProviderValidator.validate(selectedProfile) }

    func refreshDiagnostics() {
        diagnostics = try? DiagnosticsService(codexHome: codexHome).inspect()
    }

    private func responseEndpoint(baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let parsed = URL(string: trimmed) else { return nil }
        let suffix = parsed.path.isEmpty || parsed.path == "/" ? "/v1/responses" : "/responses"
        return URL(string: trimmed + suffix)
    }
}
