import Foundation
@_spi(Testing) import PaymentKit
import Testing
@testable import Examples

@Suite("Sandbox 优惠代码运行时隐私", .serialized)
@MainActor
struct SandboxOfferCodePrivacyTests {
    @Test(
        "成功、展示失败和取消均不把完整代码提交到公开状态、日志或 SQLite",
        arguments: SyntheticPresentationOutcome.allCases
    )
    func redemptionKeepsSecretInMemoryOnly(
        outcome: SyntheticPresentationOutcome
    ) async throws {
        let secret = "UITESTCODE0000WXYZ"
        let catalog = try SandboxOfferCodeCatalog.parse(
            Data("\(secret)\n".utf8)
        )
        let storageDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageDirectoryURL) }
        let logger = CapturingOfferCodeLogHandler()
        let backend = MockTransactionProcessor(
            latencyMilliseconds: 0,
            databaseURL: storageDirectoryURL
                .appendingPathComponent("mock-backend.sqlite3")
        )
        let client = PaymentClient(
            configuration: PaymentConfiguration(productIDs: []),
            processor: backend,
            logger: logger,
            pendingTransactionsDatabaseURL: storageDirectoryURL
                .appendingPathComponent("pending-transactions.sqlite3")
        )
        let model = PaymentKitExampleModel(
            client: client,
            backend: backend,
            startsAutomatically: false,
            sandboxOfferCodeCatalog: catalog,
            sandboxOfferCodeClipboard: PrivacyTestClipboard(),
            sandboxOfferCodePresenter: PrivacyTestPresenter(
                outcome: outcome,
                secret: secret
            )
        )
        let yearly = privacyTestYearlyProduct()
        let code = try #require(catalog.codes.first)
        model.selectOffer(
            .sandboxOfferCode(id: code.id, displayName: code.displayName),
            for: yearly.id
        )

        await model.performPrimaryAction(for: yearly)

        let publicState = [
            model.statusMessage,
            model.errorMessage ?? "",
            String(describing: model.events),
            String(describing: model.snapshot),
            String(describing: model.snapshot.pendingTransactions),
            String(describing: model.backendSnapshot),
            String(describing: model.sandboxOfferCodes),
            String(describing: model.selectedOffer(for: yearly)),
            String(describing: model.purchaseIntents),
            String(describing: model.storeMessages),
        ]
        let publicStateIsSanitized = publicState.allSatisfy {
            !$0.contains(secret)
        }
        let logsAreSanitized = logger.entries.allSatisfy { entry in
            !entry.category.contains(secret)
                && !entry.message.contains(secret)
                && entry.metadata.allSatisfy {
                    !$0.key.contains(secret) && !$0.value.contains(secret)
                }
        }
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: storageDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile
                == true
        }
        let createdBothSQLiteStores =
            fileURLs.contains { $0.lastPathComponent == "mock-backend.sqlite3" }
            && fileURLs.contains {
                $0.lastPathComponent == "pending-transactions.sqlite3"
            }
        let secretBytes = Data(secret.utf8)
        let persistedBytesAreSanitized = try fileURLs.allSatisfy { url in
            try Data(contentsOf: url).range(of: secretBytes) == nil
        }

        #expect(publicStateIsSanitized)
        #expect(logsAreSanitized)
        #expect(createdBothSQLiteStores)
        #expect(persistedBytesAreSanitized)
    }
}

enum SyntheticPresentationOutcome: CaseIterable, Sendable {
    case success
    case failure
    case cancellation
}

private struct SyntheticSecretBearingFailure: Error, CustomStringConvertible {
    let secret: String
    var description: String { secret }
}

@MainActor
private final class PrivacyTestPresenter:
    SandboxOfferCodeRedeemSheetPresenting {
    private let outcome: SyntheticPresentationOutcome
    private let secret: String

    init(outcome: SyntheticPresentationOutcome, secret: String) {
        self.outcome = outcome
        self.secret = secret
    }

    func preparedPresentation() throws -> SandboxOfferCodePreparedPresentation {
        .waitsForDismissal { [outcome, secret] in
            switch outcome {
            case .success:
                return
            case .failure:
                throw SyntheticSecretBearingFailure(secret: secret)
            case .cancellation:
                throw CancellationError()
            }
        }
    }
}

@MainActor
private final class PrivacyTestClipboard: SandboxOfferCodeClipboard {
    private var changeCount = 0

    func store(
        _ value: String,
        policy: SandboxOfferCodeClipboardPolicy
    ) -> Int {
        changeCount += 1
        return changeCount
    }

    func clearIfUnchanged(after expectedChangeCount: Int) {
        guard changeCount == expectedChangeCount else { return }
        changeCount += 1
    }
}

private final class CapturingOfferCodeLogHandler:
    PaymentLogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PaymentLogEntry] = []

    var entries: [PaymentLogEntry] {
        lock.withLock { storage }
    }

    func log(_ entry: PaymentLogEntry) {
        lock.withLock { storage.append(entry) }
    }
}

@MainActor
private func privacyTestYearlyProduct() -> PaymentProduct {
    PaymentProduct(
        id: ExampleProducts.yearly,
        type: .autoRenewableSubscription,
        displayName: "隐私测试年订阅",
        description: "仅用于隔离测试",
        price: 10,
        displayPrice: "¥10",
        isFamilyShareable: false,
        subscription: PaymentSubscriptionInfo(
            groupID: "privacy-test-subscription-group",
            period: .init(unit: .year, value: 1),
            introductoryOffer: nil,
            promotionalOffers: [],
            isEligibleForIntroductoryOffer: false
        )
    )
}
