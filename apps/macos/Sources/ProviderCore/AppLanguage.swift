import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var displayKey: String { "language.\(rawValue)" }
}
