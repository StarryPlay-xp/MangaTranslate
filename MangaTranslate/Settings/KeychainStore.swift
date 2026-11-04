import Foundation
import Security

/// DeepSeek API Key 存在钥匙串里：只保存在这台设备上，不随 iCloud 同步
enum KeychainStore {
    private static let service = "io.github.starryplay-xp.MangaTranslate"
    private static let account = "deepseek-api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ key: String) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "保存到钥匙串失败（错误码 \(status)）" }
}
