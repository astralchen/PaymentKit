import CryptoKit
import Foundation
import Testing
@testable import PaymentKitOfferSigning

struct PaymentKitOfferSigningTests {
    @Test
    func signsIntroductoryOfferEligibilityUsingAppleClaims() throws {
        let privateKey = P256.Signing.PrivateKey()
        let issuedAt = Date(timeIntervalSince1970: 1_721_844_000)
        let nonce = UUID(uuidString: "68C85E10-56C7-4D8D-AF8F-D4054049492D")!
        let request = IntroductoryOfferEligibilityRequest(
            productID: "paymentkit.demo.monthly",
            allowsIntroductoryOffer: true,
            transactionID: "123456789"
        )

        let compactJWS = try AppStoreOfferSigner.sign(
            request,
            configuration: .init(
                keyID: "ABC123DEFG",
                issuerID: "57246542-96fe-1a63-e053-0824d011072a",
                bundleID: "com.paymentkit.examples"
            ),
            privateKey: privateKey,
            issuedAt: issuedAt,
            nonce: nonce
        )

        let parts = compactJWS.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3)
        let header = try decodeJSON(parts[0])
        let payload = try decodeJSON(parts[1])

        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "ABC123DEFG")
        #expect(header["typ"] as? String == "JWT")
        #expect(payload["iss"] as? String == "57246542-96fe-1a63-e053-0824d011072a")
        #expect(payload["iat"] as? Int == 1_721_844_000)
        #expect(payload["aud"] as? String == "introductory-offer-eligibility")
        #expect(payload["bid"] as? String == "com.paymentkit.examples")
        #expect(payload["nonce"] as? String == nonce.uuidString.lowercased())
        #expect(payload["productId"] as? String == "paymentkit.demo.monthly")
        #expect(payload["allowIntroductoryOffer"] as? Bool == true)
        #expect(payload["transactionId"] as? String == "123456789")
        #expect(payload["exp"] == nil)
        try verify(compactJWS, using: privateKey.publicKey)
    }

    @Test
    func signsPromotionalOfferUsingAppleClaims() throws {
        let privateKey = P256.Signing.PrivateKey()
        let request = PromotionalOfferRequest(
            productID: "paymentkit.demo.monthly",
            offerID: "pk_monthly_promo_099_2m_2026",
            transactionID: nil
        )

        let compactJWS = try AppStoreOfferSigner.sign(
            request,
            configuration: .init(
                keyID: "ABC123DEFG",
                issuerID: "issuer",
                bundleID: "com.paymentkit.examples"
            ),
            privateKey: privateKey,
            issuedAt: Date(timeIntervalSince1970: 42),
            nonce: UUID(uuidString: "105DA347-0FAF-40CF-A781-5005374812ED")!
        )

        let payload = try decodeJSON(
            compactJWS.split(separator: ".", omittingEmptySubsequences: false)[1]
        )
        #expect(payload["aud"] as? String == "promotional-offer")
        #expect(payload["productId"] as? String == "paymentkit.demo.monthly")
        #expect(payload["offerIdentifier"] as? String == "pk_monthly_promo_099_2m_2026")
        #expect(payload["transactionId"] == nil)
        try verify(compactJWS, using: privateKey.publicKey)
    }

    @Test
    func rejectsEmptyRequiredValues() throws {
        let privateKey = P256.Signing.PrivateKey()

        #expect(throws: OfferSigningError.invalidConfiguration) {
            try AppStoreOfferSigner.sign(
                PromotionalOfferRequest(
                    productID: "paymentkit.demo.monthly",
                    offerID: "",
                    transactionID: nil
                ),
                configuration: .init(
                    keyID: "key",
                    issuerID: "issuer",
                    bundleID: "com.paymentkit.examples"
                ),
                privateKey: privateKey
            )
        }
    }

    private func decodeJSON(_ segment: Substring) throws -> [String: Any] {
        let data = try #require(Data(base64URLEncoded: String(segment)))
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func verify(
        _ compactJWS: String,
        using publicKey: P256.Signing.PublicKey
    ) throws {
        let parts = compactJWS.split(separator: ".", omittingEmptySubsequences: false)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        let rawSignature = try #require(
            Data(base64URLEncoded: String(parts[2]))
        )
        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: rawSignature
        )
        #expect(publicKey.isValidSignature(signature, for: signingInput))
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: base64)
    }
}
