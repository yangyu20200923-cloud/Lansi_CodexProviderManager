import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case unsupportedProvider
    case unexpectedStatus(OSStatus)
    case invalidData
}

public final class KeychainService: ProviderCredentialStoring, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.codex.provider-manager") {
        self.service = service
    }

    public func read(provider: ProviderID) throws -> String? {
        let account = try account(for: provider)
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return key
    }

    public func write(key: String, for provider: ProviderID) throws {
        let account = try account(for: provider)
        let data = Data(key.utf8)
        let query = baseQuery(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(provider: ProviderID) throws {
        let status = SecItemDelete(baseQuery(account: try account(for: provider)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func account(for provider: ProviderID) throws -> String {
        guard provider != .openAI else { throw KeychainError.unsupportedProvider }
        return provider.rawValue
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
