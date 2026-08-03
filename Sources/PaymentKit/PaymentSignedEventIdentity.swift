import CryptoKit
import Foundation

/// 生成签名交易事件使用的不透明稳定标识。
///
/// 标识只包含不可逆摘要，可安全用于进程内去重、公开 identity 和 SQLite 主键。
/// 原始 JWS 仍只保存在明确声明为敏感的交易载荷中。
internal enum PaymentSignedEventIdentity {
    /// 返回指定交易签名事件的二进制摘要。
    static func digest(for transaction: PaymentTransaction) -> Data {
        digest(
            transactionID: transaction.id,
            signedDate: transaction.signedDate,
            jwsDigest: jwsDigest(for: transaction.jwsRepresentation)
        )
    }

    /// 返回可作为公共 identity 的小写十六进制摘要。
    static func identifier(for transaction: PaymentTransaction) -> String {
        digest(for: transaction)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 返回 JWS 原文的 SHA-256 摘要。
    static func jwsDigest(for jwsRepresentation: String) -> Data {
        Data(SHA256.hash(data: Data(jwsRepresentation.utf8)))
    }

    /// 使用与 SQLite v1 `event_id` 相同的长度前缀格式生成事件摘要。
    static func digest(
        transactionID: UInt64,
        signedDate: Date,
        jwsDigest: Data
    ) -> Data {
        let fields = [
            transactionIDData(transactionID),
            signedDateData(signedDate),
            jwsDigest,
        ]
        var input = Data()
        for field in fields {
            var length = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(field)
        }
        return Data(SHA256.hash(data: input))
    }

    static func transactionIDData(_ transactionID: UInt64) -> Data {
        var value = transactionID.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func signedDateData(_ date: Date) -> Data {
        var value = date.timeIntervalSince1970.bitPattern.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
