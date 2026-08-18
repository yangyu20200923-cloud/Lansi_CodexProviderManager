import Foundation

public protocol ProviderCredentialStoring: Sendable {
    func read(provider: ProviderID) throws -> String?
    func write(key: String, for provider: ProviderID) throws
    func delete(provider: ProviderID) throws
}

/// Ephemeral credentials for isolated acceptance runs. Values never leave process memory.
public final class InMemoryProviderCredentialStore: ProviderCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProviderID: String] = [:]

    public init() {}

    public func read(provider: ProviderID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[provider]
    }

    public func write(key: String, for provider: ProviderID) throws {
        lock.lock()
        values[provider] = key
        lock.unlock()
    }

    public func delete(provider: ProviderID) throws {
        lock.lock()
        values.removeValue(forKey: provider)
        lock.unlock()
    }
}

public enum ProviderCredentialStores {
    public static func production() -> any ProviderCredentialStoring { KeychainService() }
    public static func isolatedAcceptance() -> InMemoryProviderCredentialStore { InMemoryProviderCredentialStore() }
}
