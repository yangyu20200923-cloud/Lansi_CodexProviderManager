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
            "Provider switched successfully.": "switch.success"
        ]
        if let key = exact[raw] { return string(key) }
        if raw.hasPrefix("Connection failed with HTTP "), let code = Int(raw.filter(\.isNumber)) { return string("connection.http_error", code) }
        if raw.hasPrefix("Connection failed: ") { return string("connection.failure", String(raw.dropFirst("Connection failed: ".count))) }
        return raw
    }

    func validation(_ raw: String) -> String {
        let values = [
            "Display name is required.": "validation.name_required", "Base URL is required.": "validation.url_required",
            "Base URL must be a valid HTTPS URL.": "validation.url_https", "API type is required.": "validation.api_required"
        ]
        return values[raw].map(string) ?? raw
    }
}
