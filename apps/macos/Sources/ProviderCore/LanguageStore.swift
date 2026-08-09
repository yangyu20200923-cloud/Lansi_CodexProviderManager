import Foundation

public final class LanguageStore: @unchecked Sendable {
    public static let key = "CodexProviderManager.appLanguage"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var selected: AppLanguage {
        guard let raw = defaults.string(forKey: Self.key), let language = AppLanguage(rawValue: raw) else { return .system }
        return language
    }

    public func save(_ language: AppLanguage) { defaults.set(language.rawValue, forKey: Self.key) }

    public func resolvedLocale(preferredLanguages: [String] = Locale.preferredLanguages) -> Locale {
        guard selected == .system else { return Locale(identifier: selected.rawValue) }
        let preferred = preferredLanguages.first?.lowercased() ?? ""
        if preferred.hasPrefix("zh-hans") || preferred.hasPrefix("zh-cn") || preferred.hasPrefix("zh-sg") || preferred.hasPrefix("zh") && !preferred.contains("hant") {
            return Locale(identifier: "zh-Hans")
        }
        return Locale(identifier: "en")
    }
}
