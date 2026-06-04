import Foundation
import Security

enum SarvamAPIKeyStoreError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case invalidStoredData

    var errorDescription: String? {
        switch self {
        case let .saveFailed(status):
            return "Could not save the Sarvam API key to Keychain. OSStatus \(status)."
        case let .readFailed(status):
            return "Could not read the Sarvam API key from Keychain. OSStatus \(status)."
        case let .deleteFailed(status):
            return "Could not delete the Sarvam API key from Keychain. OSStatus \(status)."
        case .invalidStoredData:
            return "The stored Sarvam API key could not be read."
        }
    }
}

enum SarvamAPIKeyStore {
    private static let service = "Indic Dictation"
    private static let account = "Sarvam API Key"

    static func loadKey() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SarvamAPIKeyStoreError.readFailed(status)
        }
        guard let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw SarvamAPIKeyStoreError.invalidStoredData
        }
        return key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : key
    }

    static func saveKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        try deleteKey(ignoringMissing: true)

        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SarvamAPIKeyStoreError.saveFailed(status)
        }
    }

    static func deleteKey() throws {
        try deleteKey(ignoringMissing: false)
    }

    private static func deleteKey(ignoringMissing: Bool) throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecItemNotFound, ignoringMissing {
            return
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SarvamAPIKeyStoreError.deleteFailed(status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
