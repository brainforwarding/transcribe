import Foundation
import Security

/// Minimal Keychain wrapper for the OpenAI key (or, later, the proxy SSO token). Stored as a
/// generic password under the app's service — never UserDefaults.
enum Keychain {
    static let service = "com.sebastianmarambio.transcribe"
    static let account = "openai-api-key"

    struct StorageError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "The credential could not be saved in Keychain (\(status)). Your previous credential was kept."
        }
    }

    static func set(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw StorageError(status: update) }
        var add = query
        add[kSecValueData as String] = data
        // Preserve the existing file-based Keychain implementation. Access-group and
        // data-protection attributes would require a provisioned storage migration.
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw StorageError(status: status) }
    }

    static func get() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    static func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
