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
        let variable: String
        switch provider {
        case .qilin: variable = "QILIN_API_KEY"
        case .vectorEngine: variable = "VECTORENGINE_API_KEY"
        case .openAI: return nil
        }
        guard let value = environment[variable], !value.isEmpty else { return nil }
        return EnvironmentKeyCandidate(provider: provider, value: value)
    }
}
