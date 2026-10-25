import Foundation
import CryptoKit
import Security
import LocalAuthentication

/// A separate, device-local key. Translation credentials use another Keychain service.
struct ClipboardHistoryEncryption {
    private let key: SymmetricKey
    private static let signature = Data("SCCH2".utf8)

    init(keyData: Data) throws {
        guard keyData.count == 32 else { throw ClipboardHistoryFailure.encryption }
        key = SymmetricKey(data: keyData)
    }
    func seal(_ data: Data, context: String) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8)).combined
        else { throw ClipboardHistoryFailure.encryption }
        return Self.signature + combined
    }
    func open(_ data: Data, context: String) throws -> Data {
        guard data.starts(with: Self.signature) else { throw ClipboardHistoryFailure.invalid }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(Self.signature.count)))
            return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
        } catch { throw ClipboardHistoryFailure.encryption }
    }
    static func keychainKey(createIfMissing: Bool) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.local.screenclip.clipboard-history",
            kSecAttrAccount as String: "aes256-v2", kSecAttrSynchronizable as String: false]
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound, createIfMissing else { throw ClipboardHistoryFailure.encryption }
        var data = Data(count: 32)
        let randomStatus = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw ClipboardHistoryFailure.encryption }
        var item = query; item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(item as CFDictionary, nil)
        if saved == errSecDuplicateItem { return try keychainKey(createIfMissing: false) }
        guard saved == errSecSuccess else { throw ClipboardHistoryFailure.encryption }
        return data
    }
}
