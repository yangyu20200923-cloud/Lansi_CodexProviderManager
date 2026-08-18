import Foundation
import ProviderCore

@MainActor
final class LocalizationController: ObservableObject {
    @Published var language: AppLanguage {
        didSet { store.save(language); locale = store.resolvedLocale() }
    }
    @Published private(set) var locale: Locale
    private let store: LanguageStore

    init() {
        store = LanguageStore()
        language = store.selected
        locale = store.resolvedLocale()
    }

    func string(_ key: String) -> String {
        let identifier = locale.identifier.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }

    func status(_ raw: String) -> String {
        let exact = [
            "Ready": "status.ready", "OpenAI uses the existing ChatGPT login.": "connection.openai_login",
            "Fix validation errors first.": "connection.fix_validation", "An API key and valid Base URL are required.": "connection.key_url_required",
            "Connection successful.": "connection.success", "Environment key is ready to save to Keychain.": "key.environment_ready",
            "Provider switched successfully.": "switch.success", "Latest backup restored.": "restore.success",
            "Provider switched successfully. The provider model list was loaded; restart to refresh the picker. Existing conversations keep their original Provider; start a new task to verify.": "switch.success_catalog",
            "Provider switched successfully. The upstream model list is unavailable; the bundled model list stays active. Existing conversations keep their original Provider; start a new task to verify.": "switch.success_no_catalog",
            "No backup is available to restore.": "restore.none",
            "Fill in the Provider details, then save or apply it.": "status.fill_details",
            "Apply another Provider before disabling the active one.": "status.apply_other_disable",
            "Provider copied to the clipboard without its API key.": "status.copied_clipboard",
            "Built-in Providers cannot be exported.": "status.builtin_export_denied",
            "Provider exported without its API key.": "status.exported",
            "Apply another Provider before deleting the active one.": "status.apply_other_delete",
            "Provider deleted. OpenAI is selected.": "status.deleted_openai",
            "Provider saved.": "status.saved",
            "Provider copied.": "status.provider_copied",
            "Provider imported.": "status.imported",
            "Provider pasted without an API key.": "status.pasted",
            "Provider enabled.": "status.provider_enabled",
            "Provider disabled.": "status.provider_disabled",
            "Environment key import is unavailable in isolated verification mode.": "status.isolated_env_import",
            "Connection tests are unavailable in isolated verification mode.": "status.isolated_connection",
            "Enable the Provider before testing it.": "status.enable_before_test",
            "Connection tests require API key authentication.": "status.connection_requires_key",
            "Enable the Provider before applying it.": "status.enable_before_apply",
            "Model fetching is unavailable in isolated verification mode.": "status.isolated_fetch",
            "Model fetching requires API key authentication.": "status.fetch_requires_key",
            "Enter a Base URL before fetching models.": "status.fetch_need_url"
        ]
        if let key = exact[raw] { return string(key) }
        if raw.hasPrefix("Connection failed with HTTP "), let code = Int(raw.filter(\.isNumber)) { return string("connection.http_error", code) }
        let prefixed: [(String, String)] = [
            ("Connection failed: ", "connection.failure"),
            ("Export failed: ", "status.export_failed"),
            ("Import failed: ", "status.import_failed"),
            ("Paste failed: ", "status.paste_failed"),
            ("Model fetch failed: ", "status.fetch_failed"),
            ("Switch failed and the previous state was restored: ", "switch.rollback_success"),
            ("Switch and automatic recovery failed. Backup: ", "switch.rollback_failure"),
            ("Restore failed and the previous state was restored: ", "restore.rollback_success"),
            ("Restore and automatic recovery failed. Backup: ", "restore.rollback_failure")
        ]
        for (prefix, key) in prefixed where raw.hasPrefix(prefix) {
            return string(key, String(raw.dropFirst(prefix.count)))
        }
        if let match = raw.wholeMatch(of: #/Fetched (\d+) models from the provider\./#),
           let count = Int(match.1) {
            return string("status.fetch_success", count)
        }
        return raw
    }

    func validation(_ raw: String) -> String {
        let values = [
            "Display name is required.": "validation.name_required", "Base URL is required.": "validation.url_required",
            "Base URL must be a valid HTTPS URL.": "validation.url_https", "API type is required.": "validation.api_required",
            "Only the Responses API is supported by the current Codex version.": "validation.responses_only",
            "No configuration overrides are approved.": "validation.overrides_none",
            "Model cannot be empty.": "validation.model_empty",
            "Reasoning effort cannot be empty.": "validation.reasoning_empty",
            "Review model cannot be empty.": "validation.review_empty",
            "Model list contains an empty or duplicate model.": "validation.model_list_invalid",
            "A model is required for API-key Providers. Select one or add a custom model.": "validation.model_required",
            "The selected model is not in this Provider's model list.": "validation.model_not_in_list",
            "API key environment variable is required.": "validation.env_required"
        ]
        return values[raw].map(string) ?? raw
    }
}
