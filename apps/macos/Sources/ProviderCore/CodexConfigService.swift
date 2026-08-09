import Foundation

public struct CodexConfig: Equatable, Sendable {
    public var rawText: String
    public var activeProvider: String?

    public init(rawText: String, activeProvider: String? = nil) {
        self.rawText = rawText
        self.activeProvider = activeProvider
    }
}

public enum CodexConfigError: Error, Equatable {
    case unreadable
    case duplicateKey(String)
    case missingProviderBlock(String)
    case malformedProviderBlock
}

public final class CodexConfigService: @unchecked Sendable {
    public init() {}

    public func read(from url: URL) throws -> CodexConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw CodexConfigError.unreadable }
        return CodexConfig(rawText: text, activeProvider: Self.value(for: "model_provider", in: text))
    }

    public func render(_ config: CodexConfig) -> String { config.rawText }

    public func activeProvider(from text: String) -> String? {
        Self.value(for: "model_provider", in: text)
    }

    public func apply(profile: ProviderProfile, to url: URL) throws {
        var config = try read(from: url)
        config.rawText = try updated(text: config.rawText, profile: profile)
        config.activeProvider = profile.id.rawValue
        try AtomicFile.replace(url, with: Data(config.rawText.utf8))
    }

    private func updated(text: String, profile: ProviderProfile) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty else { throw CodexConfigError.malformedProviderBlock }
        if !profile.isBuiltIn {
            let providerHeader = "[model_providers.\(profile.id.rawValue)]"
            let headerIndex: Int
            if let existing = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == providerHeader }) {
                headerIndex = existing
            } else {
                if lines.last?.isEmpty == false { lines.append("") }
                lines.append(providerHeader)
                headerIndex = lines.count - 1
            }
            let blockEnd = (headerIndex + 1..<lines.count).first { index in
                let value = lines[index].trimmingCharacters(in: .whitespaces)
                return value.hasPrefix("[") && value.hasSuffix("]")
            } ?? lines.count
            var seen = Set<String>()
            for index in headerIndex..<blockEnd {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard let equals = trimmed.firstIndex(of: "=") else { continue }
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                if ["name", "base_url", "wire_api", "env_key"].contains(key) {
                    if !seen.insert(key).inserted { throw CodexConfigError.duplicateKey(key) }
                    let value: String?
                    switch key {
                    case "name": value = profile.displayName
                    case "base_url": value = profile.baseURL
                    case "wire_api": value = profile.wireAPI
                    default: value = profile.id == .qilin ? "QILIN_API_KEY" : "VECTORENGINE_API_KEY"
                    }
                    if let value { lines[index] = "\(key) = \(Self.quote(value))" }
                }
            }
            let required: [(String, String?)] = [
                ("name", profile.displayName),
                ("base_url", profile.baseURL),
                ("wire_api", profile.wireAPI),
                ("env_key", profile.id == .qilin ? "QILIN_API_KEY" : "VECTORENGINE_API_KEY")
            ]
            var insertion = blockEnd
            for (key, value) in required where !seen.contains(key) {
                if let value { lines.insert("\(key) = \(Self.quote(value))", at: insertion); insertion += 1 }
            }
        }

        let modelProvider = "model_provider = \"\(profile.id.rawValue)\""
        let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        let modelProviderIndices = lines.indices.filter {
            guard $0 < firstTable else { return false }
            let trimmed = lines[$0].trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { return false }
            return trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "model_provider"
        }
        if modelProviderIndices.count > 1 { throw CodexConfigError.duplicateKey("model_provider") }
        if let index = modelProviderIndices.first { lines[index] = modelProvider }
        else { lines.insert(modelProvider, at: 0) }
        return lines.joined(separator: "\n")
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func value(for key: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].trimmingCharacters(in: .whitespaces) == key else { continue }
            let candidate = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }
}
