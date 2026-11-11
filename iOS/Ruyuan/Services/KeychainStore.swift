import Foundation
import Security

enum KeychainStore {
    private static let service = "com.ruyuan.aesthetics.api"
    static func read() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "token",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(_ value: String) throws {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: "token"]
        if value.isEmpty { SecItemDelete(key as CFDictionary); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = key
            for (k, v) in attributes { item[k] = v }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw KeychainError.write }
        } else if status != errSecSuccess { throw KeychainError.write }
    }
    enum KeychainError: LocalizedError {
        case write
        var errorDescription: String? { "凭据保存失败，请解锁设备后重试。" }
    }
}
