#if os(macOS)
import CryptoKit
import Foundation
import Security

/// 将开发签名私钥保存在当前用户的 macOS Keychain。
///
/// 存储项明确禁止 iCloud Keychain 同步。该工具不把私钥写入 App Group、
/// 应用容器或构建产物。
struct KeychainPrivateKeyStore {
    private static let service = "com.paymentkit.offer-signer.private-key"

    func importPEM(at fileURL: URL, alias: String) throws {
        guard !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OfferSignerCLIError.invalidArguments
        }

        let resourceValues = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard
            resourceValues.isRegularFile == true,
            let fileSize = resourceValues.fileSize,
            fileSize > 0,
            fileSize <= 16 * 1_024
        else {
            throw OfferSignerCLIError.invalidPrivateKey
        }

        let pem = try String(contentsOf: fileURL, encoding: .utf8)
        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw OfferSignerCLIError.invalidPrivateKey
        }
        try save(privateKey.rawRepresentation, alias: alias)
    }

    func load(alias: String) throws -> P256.Signing.PrivateKey {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: alias,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw OfferSignerCLIError.keychainFailure(status)
        }

        do {
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        } catch {
            throw OfferSignerCLIError.invalidPrivateKey
        }
    }

    private func save(_ data: Data, alias: String) throws {
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: alias,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]

        // 更新已存在的别名，避免 Keychain 中留下多个无法区分的私钥版本。
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw OfferSignerCLIError.keychainFailure(updateStatus)
        }

        var addition = lookup
        addition.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OfferSignerCLIError.keychainFailure(addStatus)
        }
    }
}
#endif
