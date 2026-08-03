import CryptoKit
import Foundation

/// App Store 优惠签名配置。
///
/// 标识符来自 App Store Connect。配置不包含私钥，调用方应从受保护的
/// 密钥存储中单独取得私钥。
public struct AppStoreOfferSigningConfiguration: Sendable, Equatable {
    public let keyID: String
    public let issuerID: String
    public let bundleID: String

    public init(keyID: String, issuerID: String, bundleID: String) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.bundleID = bundleID
    }
}

/// 首购优惠资格签名请求。
public struct IntroductoryOfferEligibilityRequest: Sendable, Equatable {
    public let productID: String
    public let allowsIntroductoryOffer: Bool
    public let transactionID: String

    public init(
        productID: String,
        allowsIntroductoryOffer: Bool,
        transactionID: String
    ) {
        self.productID = productID
        self.allowsIntroductoryOffer = allowsIntroductoryOffer
        self.transactionID = transactionID
    }
}

/// 促销优惠签名请求。
public struct PromotionalOfferRequest: Sendable, Equatable {
    public let productID: String
    public let offerID: String
    public let transactionID: String?

    public init(
        productID: String,
        offerID: String,
        transactionID: String?
    ) {
        self.productID = productID
        self.offerID = offerID
        self.transactionID = transactionID
    }
}

/// 优惠签名失败原因。
public enum OfferSigningError: Error, Sendable, Equatable {
    case invalidConfiguration
    case encodingFailed
}

/// 使用 App Store Connect In-App Purchase 私钥签发开发与 Sandbox JWS。
///
/// 生产应用应在受控后台执行相同协议，不应将私钥包含在客户端中。
public enum AppStoreOfferSigner {
    /// 签发首购优惠资格 JWS。
    public static func sign(
        _ request: IntroductoryOfferEligibilityRequest,
        configuration: AppStoreOfferSigningConfiguration,
        privateKey: P256.Signing.PrivateKey,
        issuedAt: Date = Date(),
        nonce: UUID = UUID()
    ) throws -> String {
        try validate(configuration)
        guard
            isPresent(request.productID),
            isPresent(request.transactionID)
        else {
            throw OfferSigningError.invalidConfiguration
        }

        var payload = basePayload(
            audience: "introductory-offer-eligibility",
            configuration: configuration,
            issuedAt: issuedAt,
            nonce: nonce
        )
        payload["productId"] = request.productID
        payload["allowIntroductoryOffer"] = request.allowsIntroductoryOffer
        payload["transactionId"] = request.transactionID
        return try compactJWS(
            payload: payload,
            configuration: configuration,
            privateKey: privateKey
        )
    }

    /// 签发促销优惠 JWS。
    public static func sign(
        _ request: PromotionalOfferRequest,
        configuration: AppStoreOfferSigningConfiguration,
        privateKey: P256.Signing.PrivateKey,
        issuedAt: Date = Date(),
        nonce: UUID = UUID()
    ) throws -> String {
        try validate(configuration)
        guard
            isPresent(request.productID),
            isPresent(request.offerID),
            request.transactionID.map(isPresent) ?? true
        else {
            throw OfferSigningError.invalidConfiguration
        }

        var payload = basePayload(
            audience: "promotional-offer",
            configuration: configuration,
            issuedAt: issuedAt,
            nonce: nonce
        )
        payload["productId"] = request.productID
        payload["offerIdentifier"] = request.offerID
        if let transactionID = request.transactionID {
            payload["transactionId"] = transactionID
        }
        return try compactJWS(
            payload: payload,
            configuration: configuration,
            privateKey: privateKey
        )
    }

    private static func validate(
        _ configuration: AppStoreOfferSigningConfiguration
    ) throws {
        guard
            isPresent(configuration.keyID),
            isPresent(configuration.issuerID),
            isPresent(configuration.bundleID)
        else {
            throw OfferSigningError.invalidConfiguration
        }
    }

    private static func basePayload(
        audience: String,
        configuration: AppStoreOfferSigningConfiguration,
        issuedAt: Date,
        nonce: UUID
    ) -> [String: Any] {
        [
            "iss": configuration.issuerID,
            "iat": Int(issuedAt.timeIntervalSince1970),
            "aud": audience,
            "bid": configuration.bundleID,
            "nonce": nonce.uuidString.lowercased(),
        ]
    }

    private static func compactJWS(
        payload: [String: Any],
        configuration: AppStoreOfferSigningConfiguration,
        privateKey: P256.Signing.PrivateKey
    ) throws -> String {
        let header: [String: Any] = [
            "alg": "ES256",
            "kid": configuration.keyID,
            "typ": "JWT",
        ]

        // 使用排序键产生稳定的签名输入；JWS 验证并不依赖 JSON 字段顺序。
        guard
            let headerData = try? JSONSerialization.data(
                withJSONObject: header,
                options: [.sortedKeys]
            ),
            let payloadData = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
        else {
            throw OfferSigningError.encodingFailed
        }
        let encodedHeader = headerData.base64URLEncodedString()
        let encodedPayload = payloadData.base64URLEncodedString()
        let signingInput = Data("\(encodedHeader).\(encodedPayload)".utf8)

        // CryptoKit 的 rawRepresentation 正好是 JWS ES256 要求的 R || S 格式。
        let signature = try privateKey.signature(for: signingInput)
        let encodedSignature = signature.rawRepresentation.base64URLEncodedString()
        return "\(encodedHeader).\(encodedPayload).\(encodedSignature)"
    }

    private static func isPresent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
