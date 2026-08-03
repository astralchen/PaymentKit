#if os(macOS)
import CryptoKit
import Foundation
import PaymentKitOfferSigning
import Security

enum OfferSignerCLIError: Error {
    case invalidArguments
    case invalidPrivateKey
    case keychainFailure(OSStatus)
}

@main
struct PaymentKitOfferSignerCommand {
    static func main() {
        do {
            let output = try run(arguments: Array(CommandLine.arguments.dropFirst()))
            FileHandle.standardOutput.write(Data("\(output)\n".utf8))
        } catch {
            let message = safeMessage(for: error)
            FileHandle.standardError.write(Data("错误：\(message)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run(arguments: [String]) throws -> String {
        guard let command = arguments.first else {
            throw OfferSignerCLIError.invalidArguments
        }
        let options = try parseOptions(Array(arguments.dropFirst()))
        let keyStore = KeychainPrivateKeyStore()

        switch command {
        case "import-key":
            let alias = try required("alias", in: options)
            let path = try required("p8", in: options)
            try keyStore.importPEM(
                at: URL(fileURLWithPath: path),
                alias: alias
            )
            return "私钥已导入 macOS Keychain（不可同步）。"

        case "sign-intro":
            let privateKey = try keyStore.load(
                alias: required("alias", in: options)
            )
            let configuration = try configuration(from: options)
            let allowValue = try required("allow", in: options)
            guard let allowsIntroductoryOffer = Bool(allowValue) else {
                throw OfferSignerCLIError.invalidArguments
            }
            return try AppStoreOfferSigner.sign(
                IntroductoryOfferEligibilityRequest(
                    productID: required("product-id", in: options),
                    allowsIntroductoryOffer: allowsIntroductoryOffer,
                    transactionID: required("transaction-id", in: options)
                ),
                configuration: configuration,
                privateKey: privateKey
            )

        case "sign-promo":
            let privateKey = try keyStore.load(
                alias: required("alias", in: options)
            )
            return try AppStoreOfferSigner.sign(
                PromotionalOfferRequest(
                    productID: required("product-id", in: options),
                    offerID: required("offer-id", in: options),
                    transactionID: options["transaction-id"]
                ),
                configuration: configuration(from: options),
                privateKey: privateKey
            )

        default:
            throw OfferSignerCLIError.invalidArguments
        }
    }

    private static func configuration(
        from options: [String: String]
    ) throws -> AppStoreOfferSigningConfiguration {
        AppStoreOfferSigningConfiguration(
            keyID: try required("key-id", in: options),
            issuerID: try required("issuer-id", in: options),
            bundleID: try required("bundle-id", in: options)
        )
    }

    private static func parseOptions(
        _ arguments: [String]
    ) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else {
            throw OfferSignerCLIError.invalidArguments
        }
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--"), name.count > 2 else {
                throw OfferSignerCLIError.invalidArguments
            }
            let key = String(name.dropFirst(2))
            guard options[key] == nil else {
                throw OfferSignerCLIError.invalidArguments
            }
            options[key] = arguments[index + 1]
            index += 2
        }
        return options
    }

    private static func required(
        _ key: String,
        in options: [String: String]
    ) throws -> String {
        guard
            let value = options[key],
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw OfferSignerCLIError.invalidArguments
        }
        return value
    }

    private static func safeMessage(for error: Error) -> String {
        switch error {
        case OfferSignerCLIError.invalidArguments:
            return """
            参数无效。使用 import-key、sign-intro 或 sign-promo；\
            签名命令需要 --alias、--key-id、--issuer-id、--bundle-id 和对应优惠参数。
            """
        case OfferSignerCLIError.invalidPrivateKey:
            return "私钥不是有效的 P-256 PKCS#8 PEM 文件。"
        case let OfferSignerCLIError.keychainFailure(status):
            return "Keychain 操作失败（状态码 \(status)）。"
        case OfferSigningError.invalidConfiguration:
            return "签名配置或优惠参数无效。"
        case OfferSigningError.encodingFailed:
            return "JWS 编码失败。"
        default:
            return "签名操作失败。"
        }
    }
}
#else
import Foundation

@main
struct PaymentKitOfferSignerCommand {
    static func main() {
        FileHandle.standardError.write(
            Data("错误：签名工具仅支持 macOS。\n".utf8)
        )
        Foundation.exit(EXIT_FAILURE)
    }
}
#endif
