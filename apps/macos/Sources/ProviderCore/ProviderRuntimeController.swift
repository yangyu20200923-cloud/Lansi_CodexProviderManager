import Foundation

public protocol ProviderRuntimeControlling: Sendable {
    func quit() async throws
    func waitUntilQuiescent(timeout: TimeInterval) async throws
    func launch() async throws
    func setEnvironment(profile: ProviderProfile, key: String?) throws
    func verifyConfiguration(codexHome: URL, profile: ProviderProfile, key: String?) throws
    func verifyLaunchedRuntime(profile: ProviderProfile) async throws
}

public enum ProviderRuntimeOperation: Equatable, Sendable {
    case quit
    case waitUntilQuiescent
    case launch
    case setEnvironment(ProviderID)
    case verifyConfiguration(String)
    case verifyLaunchedRuntime(ProviderID)
}

/// A deliberately side-effect-free runtime for temporary fixture acceptance runs.
public final class IsolatedProviderRuntimeController: ProviderRuntimeControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [ProviderRuntimeOperation] = []

    public init() {}

    public var recordedOperations: [ProviderRuntimeOperation] {
        lock.lock()
        defer { lock.unlock() }
        return operations
    }

    public func quit() async throws { record(.quit) }
    public func waitUntilQuiescent(timeout _: TimeInterval) async throws { record(.waitUntilQuiescent) }
    public func launch() async throws { record(.launch) }
    public func setEnvironment(profile: ProviderProfile, key _: String?) throws { record(.setEnvironment(profile.id)) }
    public func verifyConfiguration(codexHome _: URL, profile: ProviderProfile, key _: String?) throws { record(.verifyConfiguration(profile.configProviderID)) }
    public func verifyLaunchedRuntime(profile: ProviderProfile) async throws { record(.verifyLaunchedRuntime(profile.id)) }

    private func record(_ operation: ProviderRuntimeOperation) {
        lock.lock()
        operations.append(operation)
        lock.unlock()
    }
}

public enum ProviderRuntimeControllers {
    public static func production() -> any ProviderRuntimeControlling { ChatGPTService() }
    public static func isolatedAcceptance() -> IsolatedProviderRuntimeController { IsolatedProviderRuntimeController() }
}
