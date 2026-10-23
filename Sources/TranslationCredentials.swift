import Foundation
import Security

struct KeychainTranslationCredentials: TranslationCredentials {
    var service = "com.local.screenclip.translation"
    private func query(_ provider: TranslationProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue, kSecAttrSynchronizable as String: false]
    }
    func read(_ provider: TranslationProvider) throws -> String? {
        guard provider != .system else { return nil }
        var request = query(provider)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8)
        else { throw TranslationFailure.credentials }
        return value
    }
    func write(_ value: String?, for provider: TranslationProvider) throws {
        guard provider != .system else { return }
        let request = query(provider)
        guard let value else {
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw TranslationFailure.credentials }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = request; item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TranslationFailure.credentials }
    }
}
