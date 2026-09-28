import Foundation
import Security

/// Stores the API key in the user's login Keychain.
enum Keychain {
    private static let service = "com.local.GrammarCorrector"
    private static let account = "gemini-api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ key: String) {
        SecItemDelete(baseQuery as CFDictionary)
        guard !key.isEmpty else { return }
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }
}
