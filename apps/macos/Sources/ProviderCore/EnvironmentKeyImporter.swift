import Foundation

public struct EnvironmentKeyCandidate: Equatable, Sendable {
    public let provider: ProviderID
    public let value: String
}

public struct EnvironmentKeyImporter: Sendable {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func candidate(for provider: ProviderID) -> EnvironmentKeyCandidate? {
        let variable = provider == .qilin ? "QILIN_API_KEY" : provider == .vectorEngine ? "VECTORENGINE_API_KEY" : nil
        return candidate(for: variable, provider: provider)
    }

    public func candidate(for variable: String?, provider: ProviderID) -> EnvironmentKeyCandidate? {
        guard let variable, !variable.isEmpty else { return nil }
        guard let value = environment[variable], !value.isEmpty else { return nil }
        return EnvironmentKeyCandidate(provider: provider, value: value)
    }
}
