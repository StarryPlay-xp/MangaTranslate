import Foundation
import Security

/// API Key 存在钥匙串里：只保存在这台设备上，不随 iCloud 同步。每个模型服务各存一把
enum KeychainStore {
    private static let service = "io.github.starryplay-xp.MangaTranslate"
    /// 第一版只存一把 DeepSeek Key 时用的账户名；升级后搬到 DeepSeek 配置里
    static let legacyAccount = "deepseek-api-key"

    static func account(for serviceID: UUID) -> String {
        "llm-api-key-" + serviceID.uuidString
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ key: String, account: String) throws {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "保存到钥匙串失败（错误码 \(status)）" }
}
