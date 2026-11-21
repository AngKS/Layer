import Foundation
import Security

/// Keeps each provider's API key in the Keychain: never in the design files, in user
/// defaults or in a property list. A key stays on this device: it isn't synced through
/// iCloud Keychain or included in backups, and it can be read once the device has been
/// unlocked after starting up, so a sketch read in the background still works.
enum APIKeyStore {
    /// Where the keys are kept. The unit tests, which run inside the app, keep theirs apart:
    /// they put keys in and take them out, and took out the ones saved in the app.
    static let service = AppSettings.isRunningUnitTests ? "kahshin.Layer.model-provider.unit-tests" : "kahshin.Layer.model-provider"

    /// The saved key, or nil when there is none.
    static func key(for provider: HostedProvider) -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    static func hasKey(for provider: HostedProvider) -> Bool {
        var query = baseQuery(for: provider)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Saves a key, replacing any saved before. An empty key removes it.
    static func setKey(_ key: String, for provider: HostedProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try removeKey(for: provider)
            return
        }
        let data = Data(trimmed.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(for: provider) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(for: provider)
            add.merge(update) { $1 }
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func removeKey(for provider: HostedProvider) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private static func baseQuery(for provider: HostedProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The key couldn't be saved in the Keychain (\(detail))."
        }
    }
}
