import Foundation
import StoreKit
import Testing
@testable import PaymentKit

@Suite("支付客户端", .serialized)
struct PaymentClientTests {
    @Test("公共快照区分待交付和等待 StoreKit 结束")
    func publicPendingStateModelsAreExplicit() {
        let transaction = PaymentTransaction.fixture(id: 90)
        let pending = PaymentPendingTransaction(
            transaction: transaction,
            state: .deliveredAwaitingFinish
        )
        let snapshot = PaymentSnapshot(pendingTransactions: [pending])
        let report = PaymentRetryReport(
            attemptedCount: 1,
            deliveredCount: 1,
            finishedCount: 0,
            awaitingFinishCount: 1,
            failureCount: 0,
            unresolvedCount: 0,
            snapshot: snapshot
        )

        #expect(snapshot.pendingTransactions == [pending])
        #expect(report.awaitingFinishCount == 1)
        #expect(
            PaymentEvent.transactionDelivered(
                transaction,
                finishState: .awaitingStoreKit
            ) == .transactionDelivered(transaction, finishState: .awaitingStoreKit)
        )
        #expect(PaymentErrorCode.persistenceFailed.rawValue == "persistenceFailed")
        #expect(PaymentErrorCode.recoveryFailed.rawValue == "recoveryFailed")
    }

    @Test("待处理交易 ID 使用不透明摘要且随签名事件变化")
    func pendingTransactionIdentifierIsOpaqueAndStable() {
        let sensitiveJWS = "header.sensitive-payload.signature"
        let transaction = PaymentTransaction.fixture(
            id: 91,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: sensitiveJWS
        )
        let identical = PaymentTransaction.fixture(
            id: 91,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: sensitiveJWS
        )
        let resigned = PaymentTransaction.fixture(
            id: 91,
            signedDate: Date(timeIntervalSince1970: 11),
            jwsRepresentation: "header.new-payload.signature"
        )

        let identifier = PaymentPendingTransaction(
            transaction: transaction,
            state: .awaitingDelivery
        ).id
        let identicalIdentifier = PaymentPendingTransaction(
            transaction: identical,
            state: .deliveredAwaitingFinish
        ).id
        let resignedIdentifier = PaymentPendingTransaction(
            transaction: resigned,
            state: .awaitingDelivery
        ).id

        #expect(identifier.count == 64)
        #expect(identifier.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(!identifier.contains(sensitiveJWS))
        #expect(identifier == identicalIdentifier)
        #expect(identifier != resignedIdentifier)
    }

    @Test("实际优惠随交易持久化但不改变可靠交付业务状态")
    func appliedOfferPersistsWithoutChangingDeliveryIdentity() {
        let appliedOffer = PaymentAppliedOffer(
            id: nil,
            type: .introductory,
            paymentMode: .freeTrial,
            period: PaymentSubscriptionPeriod(unit: .week, value: 1),
            periodRawValue: "P1W"
        )
        let transaction = PaymentTransaction.fixture(
            id: 92,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group",
            appliedOffer: appliedOffer
        )
        let withoutOffer = PaymentTransaction.fixture(
            id: 92,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group"
        )
        let reference = PendingTransactionReference(transaction: transaction)

        #expect(transaction.appliedOffer == appliedOffer)
        #expect(transaction.deliveryState == withoutOffer.deliveryState)
        #expect(reference.persistedTransaction == transaction)
    }

    @Test("旧 outbox payload 缺少优惠字段时继续解码为 nil")
    func legacyOutboxPayloadDecodesWithoutAppliedOffer() throws {
        let transaction = PaymentTransaction.fixture(
            id: 921,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group",
            appliedOffer: PaymentAppliedOffer(
                id: nil,
                type: .introductory,
                paymentMode: .freeTrial,
                period: PaymentSubscriptionPeriod(unit: .week, value: 1),
                periodRawValue: "P1W"
            )
        )
        let encoded = try JSONEncoder().encode(
            PendingTransactionReference(transaction: transaction)
        )
        var root = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var payload = try #require(root["transactionPayload"] as? [String: Any])
        for key in [
            "appliedOfferID",
            "appliedOfferTypeRawValue",
            "appliedOfferPaymentModeRawValue",
            "appliedOfferPeriodUnitRawValue",
            "appliedOfferPeriodValue",
            "appliedOfferPeriodRawValue",
        ] {
            payload.removeValue(forKey: key)
        }
        root["transactionPayload"] = payload

        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let restored = try JSONDecoder().decode(
            PendingTransactionReference.self,
            from: legacyData
        )

        #expect(restored.persistedTransaction?.appliedOffer == nil)
        #expect(restored.persistedTransaction?.deliveryState == transaction.deliveryState)
    }

    @Test("续订信息公开实际优惠且旧初始化调用保持 nil")
    func renewalInfoExposesAppliedOffer() {
        let appliedOffer = PaymentAppliedOffer(
            id: "annual-intro",
            type: .introductory,
            paymentMode: .payUpFront,
            period: PaymentSubscriptionPeriod(unit: .year, value: 1),
            periodRawValue: "P1Y"
        )
        let renewal = PaymentRenewalInfo(
            originalTransactionID: 93,
            currentProductID: "annual",
            willAutoRenew: true,
            autoRenewPreference: "annual",
            expirationReason: nil,
            priceIncreaseStatus: .noIncreasePending,
            isInBillingRetry: false,
            gracePeriodExpirationDate: nil,
            renewalDate: nil,
            renewalPrice: 29.99,
            currencyCode: "USD",
            jwsRepresentation: "renewal-jws",
            appliedOffer: appliedOffer
        )
        let legacyStyle = PaymentRenewalInfo(
            originalTransactionID: 94,
            currentProductID: "monthly",
            willAutoRenew: true,
            autoRenewPreference: nil,
            expirationReason: nil,
            priceIncreaseStatus: .noIncreasePending,
            isInBillingRetry: false,
            gracePeriodExpirationDate: nil,
            renewalDate: nil,
            renewalPrice: nil,
            currencyCode: nil,
            jwsRepresentation: "legacy-renewal-jws"
        )

        #expect(renewal.appliedOffer == appliedOffer)
        #expect(legacyStyle.appliedOffer == nil)
    }

    @Test("交易公开账单计划和承诺进度但不改变可靠交付业务状态")
    func transactionExposesCommitmentWithoutChangingDeliveryIdentity() {
        let commitment = PaymentTransactionCommitment(
            billingPeriodNumber: 3,
            totalBillingPeriods: 12,
            expirationDate: Date(timeIntervalSince1970: 20_000),
            price: 15
        )
        let transaction = PaymentTransaction.fixture(
            id: 95,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group",
            billingPlan: .monthlyCommitment,
            commitment: commitment
        )
        let legacy = PaymentTransaction.fixture(
            id: 95,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group"
        )

        #expect(transaction.billingPlan == .monthlyCommitment)
        #expect(transaction.commitment == commitment)
        #expect(transaction.deliveryState == legacy.deliveryState)
    }

    @Test("账单计划和承诺进度随 outbox payload 恢复且兼容旧记录")
    func commitmentMetadataPersistsInOutboxPayload() throws {
        let commitment = PaymentTransactionCommitment(
            billingPeriodNumber: 7,
            totalBillingPeriods: 12,
            expirationDate: Date(timeIntervalSince1970: 40_000),
            price: 15
        )
        let transaction = PaymentTransaction.fixture(
            id: 951,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group",
            billingPlan: .monthlyCommitment,
            commitment: commitment
        )
        let encoded = try JSONEncoder().encode(
            PendingTransactionReference(transaction: transaction)
        )
        let restored = try JSONDecoder().decode(
            PendingTransactionReference.self,
            from: encoded
        )
        #expect(restored.persistedTransaction == transaction)

        var root = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var payload = try #require(root["transactionPayload"] as? [String: Any])
        for key in [
            "billingPlanRawValue",
            "commitmentBillingPeriodNumber",
            "commitmentTotalBillingPeriods",
            "commitmentExpirationDate",
            "commitmentPrice",
        ] {
            payload.removeValue(forKey: key)
        }
        root["transactionPayload"] = payload
        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let legacy = try JSONDecoder().decode(
            PendingTransactionReference.self,
            from: legacyData
        )

        #expect(legacy.persistedTransaction?.billingPlan == nil)
        #expect(legacy.persistedTransaction?.commitment == nil)
        #expect(legacy.persistedTransaction?.deliveryState == transaction.deliveryState)
    }

    @Test("续订信息公开回归资格和下一承诺计划")
    func renewalInfoExposesWinBackEligibilityAndCommitment() {
        let commitment = PaymentRenewalCommitment(
            autoRenewPreference: "annual",
            renewalBillingPlan: .monthlyCommitment,
            renewalDate: Date(timeIntervalSince1970: 30_000),
            renewalPrice: 15,
            willAutoRenew: true
        )
        let renewal = PaymentRenewalInfo(
            originalTransactionID: 96,
            currentProductID: "annual",
            willAutoRenew: true,
            autoRenewPreference: "annual",
            expirationReason: nil,
            priceIncreaseStatus: .noIncreasePending,
            isInBillingRetry: false,
            gracePeriodExpirationDate: nil,
            renewalDate: Date(timeIntervalSince1970: 10_000),
            renewalPrice: 29.99,
            currencyCode: "USD",
            jwsRepresentation: "renewal-jws",
            appliedOffer: nil,
            eligibleWinBackOfferIDs: ["best-offer", "fallback-offer"],
            renewalBillingPlan: .monthlyCommitment,
            commitment: commitment
        )

        #expect(renewal.eligibleWinBackOfferIDs == ["best-offer", "fallback-offer"])
        #expect(renewal.renewalBillingPlan == .monthlyCommitment)
        #expect(renewal.commitment == commitment)
    }

    @Test("商品部分返回时保持配置顺序并报告缺失项")
    func partialProductsPreserveOrder() async throws {
        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([
            StoreProduct(value: .fixture(id: "premium")),
            StoreProduct(value: .fixture(id: "coins", type: .consumable)),
        ])
        let logger = RecordingPaymentLogHandler()
        let client = makeClient(
            productIDs: ["coins", "missing", "premium"],
            gateway: gateway,
            logger: logger
        )

        let products = try await client.reloadProducts()
        let snapshot = await client.snapshot()

        #expect(products.map(\.id) == ["coins", "premium"])
        #expect(snapshot.unavailableProductIDs == ["missing"])
        #expect(logger.entries.contains { $0.message == "商品加载完成" })
    }

    @Test("较晚的商品请求失败时仍提交较早的成功结果")
    func newerFailedProductLoadDoesNotDiscardEarlierSuccess() async throws {
        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([StoreProduct(value: .fixture(id: "premium"))])
        await gateway.blockNextProductLoadRequest()
        let client = makeClient(gateway: gateway)

        let earlierLoad = Task { try await client.reloadProducts() }
        try await waitUntil { await gateway.productLoadRequestCount == 1 }
        await gateway.failProductLoad(requestNumber: 2)
        do {
            _ = try await client.reloadProducts()
            Issue.record("较晚的商品请求应按 fake 配置失败")
        } catch let error as PaymentError {
            #expect(error.code == .storeKitFailed)
        }

        await gateway.resumeBlockedProductLoadRequest()
        #expect(try await earlierLoad.value.map(\.id) == ["premium"])
        #expect(await client.snapshot().products.map(\.id) == ["premium"])

        // 成功响应必须同时写入原生商品缓存，后续购买不能误报 productNotFound。
        await gateway.enqueuePurchaseResult(.pending)
        #expect(try await client.purchase(productID: "premium") == .pending)
    }

    @Test("商品加载取消会透传 CancellationError")
    func productLoadCancellationIsPreserved() async {
        let gateway = FakePaymentStoreGateway()
        await gateway.cancelProductLoad(requestNumber: 1)
        let client = makeClient(gateway: gateway)

        do {
            _ = try await client.reloadProducts()
            Issue.record("取消的商品请求不应返回成功")
        } catch is CancellationError {
            // CancellationError 是此用例的预期结果。
        } catch {
            Issue.record("取消不应被包装成 PaymentError")
        }
    }

    @Test("购买成功后先处理交易再结束交易")
    func successfulPurchaseProcessesBeforeFinishing() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 100, signedDate: Date(timeIntervalSince1970: 1))
        await gateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: transaction))))
        let processor = OrderingTransactionProcessor(gateway: gateway)
        let client = makeClient(gateway: gateway, processor: processor)
        _ = try await client.reloadProducts()

        let outcome = try await client.purchase(productID: transaction.productID)

        #expect(outcome == .completed(transaction))
        #expect(await processor.transactions == [transaction])
        #expect(await processor.observedUnfinishedTransaction)
        #expect(await gateway.finishedTransactionIDs == [transaction.id])
    }

    @Test("后台交付成功后必须先持久标记再结束交易")
    func deliveredStateIsPersistedBeforeFinishing() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 91)
        await gateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: transaction))))
        let pendingStore = FaultInjectingPendingTransactionStore()
        let client = makeClient(gateway: gateway, pendingStore: pendingStore)
        _ = try await client.reloadProducts()

        _ = try await client.purchase(productID: transaction.productID)

        #expect(await pendingStore.markDeliveredCount == 1)
        #expect(await gateway.finishedTransactionIDs == [transaction.id])
        #expect(await pendingStore.references().isEmpty)
    }

    @Test("已交付标记落盘失败时不得结束交易")
    func markDeliveredFailurePreventsFinish() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 92)
        await gateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: transaction))))
        let pendingStore = FaultInjectingPendingTransactionStore(failMarkDelivered: true)
        let client = makeClient(gateway: gateway, pendingStore: pendingStore)
        _ = try await client.reloadProducts()

        do {
            _ = try await client.purchase(productID: transaction.productID)
            Issue.record("已交付状态没有可靠落盘时购买不应完成")
        } catch let error as PaymentError {
            #expect(error.code == .persistenceFailed)
            #expect(!error.message.contains("secret"))
        }

        #expect(await gateway.finishedTransactionIDs.isEmpty)
        #expect(await pendingStore.references().count == 1)
    }

    @Test("outbox 初始写入失败时不得调用后台或结束交易")
    func initialPersistenceFailurePreventsDelivery() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 96)
        await gateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: transaction))))
        let processor = RecordingTransactionProcessor()
        let pendingStore = FaultInjectingPendingTransactionStore(failInsert: true)
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )
        _ = try await client.reloadProducts()

        do {
            _ = try await client.purchase(productID: transaction.productID)
            Issue.record("outbox 无法写入时购买不应完成")
        } catch let error as PaymentError {
            #expect(error.code == .persistenceFailed)
        }

        #expect(await processor.transactions.isEmpty)
        #expect(await gateway.finishedTransactionIDs.isEmpty)
    }

    @Test("SQLite 打开 I/O 失败时不得调用后台或结束交易")
    func sqliteOpenFailurePreventsDeliveryAndFinish() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = rootURL
            .appendingPathComponent("pending-transactions.sqlite3", isDirectory: true)
        try FileManager.default.createDirectory(
            at: databaseURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 97)
        await gateway.setProducts([
            StoreProduct(value: .fixture(id: transaction.productID)),
        ])
        await gateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: transaction)))
        )
        let processor = RecordingTransactionProcessor()
        let pendingStore = SQLitePendingTransactionStore(databaseURL: databaseURL)
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )
        _ = try await client.reloadProducts()

        do {
            _ = try await client.purchase(productID: transaction.productID)
            Issue.record("SQLite 无法打开时购买不应继续交付")
        } catch let error as PaymentError {
            #expect(error.code == .persistenceFailed)
        }

        // outbox 初始写入是后台交付和 StoreKit finish 的硬前置条件。
        #expect(await processor.transactions.isEmpty)
        #expect(await gateway.finishedTransactionIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    @Test("同进程多个客户端共享 outbox 时不会覆盖彼此订单")
    func multipleClientsDoNotOverwriteSharedOutbox() async throws {
        let firstTransaction = PaymentTransaction.fixture(
            id: 201,
            productID: "first",
            jwsRepresentation: "first-jws"
        )
        let secondTransaction = PaymentTransaction.fixture(
            id: 202,
            productID: "second",
            jwsRepresentation: "second-jws"
        )
        let firstGateway = FakePaymentStoreGateway()
        let secondGateway = FakePaymentStoreGateway()
        await firstGateway.setProducts([StoreProduct(value: .fixture(id: "first"))])
        await secondGateway.setProducts([StoreProduct(value: .fixture(id: "second"))])
        await firstGateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: firstTransaction)))
        )
        await secondGateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: secondTransaction)))
        )
        let sharedStore = InMemoryPendingTransactionStore()
        let firstClient = makeClient(
            productIDs: ["first"],
            gateway: firstGateway,
            processor: RecordingTransactionProcessor(failuresRemaining: 1),
            pendingStore: sharedStore
        )
        let secondClient = makeClient(
            productIDs: ["second"],
            gateway: secondGateway,
            processor: RecordingTransactionProcessor(failuresRemaining: 1),
            pendingStore: sharedStore
        )
        _ = try await firstClient.reloadProducts()
        _ = try await secondClient.reloadProducts()

        let firstPurchase = Task { try await firstClient.purchase(productID: "first") }
        let secondPurchase = Task { try await secondClient.purchase(productID: "second") }
        for purchase in [firstPurchase, secondPurchase] {
            do {
                _ = try await purchase.value
                Issue.record("故障注入的后台不应完成购买")
            } catch let error as PaymentError {
                #expect(error.code == .processingFailed)
            }
        }

        #expect(Set(await sharedStore.references().map(\.transactionID)) == [201, 202])
        #expect(await firstGateway.finishedTransactionIDs.isEmpty)
        #expect(await secondGateway.finishedTransactionIDs.isEmpty)
    }

    @Test("finish 后清理失败会在重启时只补 finish 不重复交付")
    func cleanupFailureIsRecoveredIdempotently() async throws {
        let transaction = PaymentTransaction.fixture(id: 97)
        // finish 后的清理失败，模拟进程在已交付记录仍残留时退出。
        let pendingStore = FaultInjectingPendingTransactionStore(removeFailuresRemaining: 1)
        let purchaseGateway = FakePaymentStoreGateway()
        await purchaseGateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await purchaseGateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: transaction)))
        )
        let purchaseProcessor = RecordingTransactionProcessor()
        let purchaseClient = makeClient(
            gateway: purchaseGateway,
            processor: purchaseProcessor,
            pendingStore: pendingStore
        )
        _ = try await purchaseClient.reloadProducts()

        _ = try await purchaseClient.purchase(productID: transaction.productID)
        #expect(await pendingStore.references().first?.isDelivered == true)

        let restartedGateway = FakePaymentStoreGateway()
        await restartedGateway.setAllTransactions([.verified(StoreTransaction(value: transaction))])
        let restartedProcessor = RecordingTransactionProcessor()
        let restartedClient = makeClient(
            gateway: restartedGateway,
            processor: restartedProcessor,
            pendingStore: pendingStore
        )

        let report = await restartedClient.retryUnfinishedTransactions()

        #expect(await restartedProcessor.transactions.isEmpty)
        #expect(await restartedGateway.finishedTransactionIDs == [transaction.id])
        #expect(await pendingStore.references().isEmpty)
        #expect(report.deliveredCount == 0)
        #expect(report.finishedCount == 1)
    }

    @Test("购买完成后立即刷新当前权益快照")
    func completedPurchaseRefreshesSnapshot() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 110)
        await gateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await gateway.setEntitlements([.verified(StoreTransaction(value: transaction))])
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: transaction))))
        let client = makeClient(gateway: gateway)
        _ = try await client.reloadProducts()

        _ = try await client.purchase(productID: transaction.productID)

        #expect(await client.snapshot().currentEntitlements == [transaction])
    }

    @Test("自动续期购买完成后重新加载同组商品资格")
    func subscriptionPurchaseReloadsGroupEligibility() async throws {
        let gateway = FakePaymentStoreGateway()
        let offer = PaymentSubscriptionOffer.fixture(paymentMode: .freeTrial)
        let eligibleMonthly = PaymentProduct.fixture(
            id: "monthly",
            type: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group",
            introductoryOffer: offer,
            isEligibleForIntroductoryOffer: true
        )
        let eligibleAnnual = PaymentProduct.fixture(
            id: "annual",
            type: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group",
            introductoryOffer: .fixture(paymentMode: .payUpFront),
            isEligibleForIntroductoryOffer: true
        )
        let transaction = PaymentTransaction.fixture(
            id: 111,
            productID: eligibleMonthly.id,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group"
        )
        await gateway.setProducts([
            StoreProduct(value: eligibleMonthly),
            StoreProduct(value: eligibleAnnual),
        ])
        await gateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: transaction)))
        )
        let client = makeClient(
            productIDs: [eligibleMonthly.id, eligibleAnnual.id],
            gateway: gateway
        )
        _ = try await client.reloadProducts()

        // 模拟 StoreKit 在同组任一首购完成后同时撤销月/年的资格。
        await gateway.setProducts([
            StoreProduct(value: PaymentProduct.fixture(
                id: eligibleMonthly.id,
                type: .autoRenewableSubscription,
                subscriptionGroupID: "subscription-group",
                introductoryOffer: offer,
                isEligibleForIntroductoryOffer: false
            )),
            StoreProduct(value: PaymentProduct.fixture(
                id: eligibleAnnual.id,
                type: .autoRenewableSubscription,
                subscriptionGroupID: "subscription-group",
                introductoryOffer: .fixture(paymentMode: .payUpFront),
                isEligibleForIntroductoryOffer: false
            )),
        ])

        #expect(try await client.purchase(productID: eligibleMonthly.id) == .completed(transaction))
        #expect(await gateway.productLoadRequestCount == 2)
        #expect(await client.snapshot().products.allSatisfy {
            $0.subscription?.isEligibleForIntroductoryOffer == false
        })
    }

    @Test("首购资格刷新失败不改变已完成购买结果")
    func eligibilityRefreshFailureDoesNotFailPurchase() async throws {
        let gateway = FakePaymentStoreGateway()
        let product = PaymentProduct.fixture(
            id: "monthly",
            type: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group",
            introductoryOffer: .fixture(paymentMode: .freeTrial),
            isEligibleForIntroductoryOffer: true
        )
        let transaction = PaymentTransaction.fixture(
            id: 112,
            productID: product.id,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group"
        )
        await gateway.setProducts([StoreProduct(value: product)])
        await gateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: transaction)))
        )
        let client = makeClient(productIDs: [product.id], gateway: gateway)
        _ = try await client.reloadProducts()
        await gateway.failProductLoad(requestNumber: 2)

        #expect(try await client.purchase(productID: product.id) == .completed(transaction))
        #expect(await gateway.productLoadRequestCount == 2)
        #expect(
            await client.snapshot().products.first?.subscription?
                .isEligibleForIntroductoryOffer == true
        )
    }

    @Test("后台处理失败时交易保持未完成并可重试")
    func processingFailureLeavesTransactionUnfinished() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 101)
        await gateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: transaction))))
        await gateway.setUnfinished([.verified(StoreTransaction(value: transaction))])
        let processor = RecordingTransactionProcessor(failuresRemaining: 1)
        let client = makeClient(gateway: gateway, processor: processor)
        _ = try await client.reloadProducts()

        do {
            _ = try await client.purchase(productID: transaction.productID)
            Issue.record("后台处理失败时购买不应成功")
        } catch let error as PaymentError {
            #expect(error.code == .processingFailed)
        }
        #expect(await gateway.finishedTransactionIDs.isEmpty)

        await client.retryUnfinishedTransactions()

        #expect(await processor.transactions.count == 2)
        #expect(await gateway.finishedTransactionIDs == [transaction.id])
    }

    @Test("未完成交易重试报告区分交付、结束、等待和失败")
    func retryReportSummarizesOutcomes() async {
        let gateway = FakePaymentStoreGateway()
        let finished = PaymentTransaction.fixture(id: 93, jwsRepresentation: "finished-jws")
        let awaiting = PaymentTransaction.fixture(id: 94, jwsRepresentation: "awaiting-jws")
        await gateway.setUnfinished([
            .verified(StoreTransaction(value: finished)),
            .verified(StoreTransaction(value: awaiting, canFinish: false)),
            .unverified(transactionID: 95, message: "unverified"),
        ])
        let client = makeClient(gateway: gateway)

        let report = await client.retryUnfinishedTransactions()

        #expect(report.attemptedCount == 3)
        #expect(report.deliveredCount == 2)
        #expect(report.finishedCount == 1)
        #expect(report.awaitingFinishCount == 1)
        #expect(report.failureCount == 1)
        #expect(report.unresolvedCount == 0)
        #expect(report.snapshot.pendingTransactions == [
            PaymentPendingTransaction(transaction: awaiting, state: .deliveredAwaitingFinish)
        ])
    }

    @Test("应用重启后 StoreKit 漏报未完成交易时仍会自动重放")
    func restartRecoversPersistedTransactionWhenUnfinishedIsEmpty() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let transaction = PaymentTransaction.fixture(id: 117)

        let purchaseGateway = FakePaymentStoreGateway()
        await purchaseGateway.setProducts([
            StoreProduct(value: .fixture(id: transaction.productID))
        ])
        await purchaseGateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: transaction)))
        )
        let failingProcessor = RecordingTransactionProcessor(failuresRemaining: 1)
        let purchaseClient = makeClient(
            gateway: purchaseGateway,
            processor: failingProcessor,
            pendingStore: pendingStore
        )
        _ = try await purchaseClient.reloadProducts()

        do {
            _ = try await purchaseClient.purchase(productID: transaction.productID)
            Issue.record("后台失败时购买不应成功")
        } catch let error as PaymentError {
            #expect(error.code == .processingFailed)
        }

        // 模拟新应用进程：StoreKit.unfinished 为空，但全量交易历史仍保留原始交易。
        let restartedGateway = FakePaymentStoreGateway()
        await restartedGateway.setAllTransactions([
            .verified(StoreTransaction(value: transaction))
        ])
        let recoveredProcessor = RecordingTransactionProcessor()
        let logger = RecordingPaymentLogHandler()
        let restartedClient = makeClient(
            gateway: restartedGateway,
            processor: recoveredProcessor,
            pendingStore: pendingStore,
            logger: logger
        )

        await restartedClient.start()
        defer { Task { await restartedClient.stop() } }

        #expect(await recoveredProcessor.transactions == [transaction])
        #expect(await restartedGateway.finishedTransactionIDs == [transaction.id])
        #expect(await pendingStore.references().isEmpty)
        #expect(logger.entries.contains {
            $0.message == "从持久记录找回待交付交易"
                && $0.metadata["recoveredCount"] == "1"
        })
    }

    @Test("交易历史也漏报时按商品找回同一笔最新交易")
    func restartFallsBackToLatestTransactionForProduct() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let transaction = PaymentTransaction.fixture(id: 121)
        await pendingStore.insert(PendingTransactionReference(transaction: transaction))

        let gateway = FakePaymentStoreGateway()
        await gateway.setLatestTransaction(
            .verified(StoreTransaction(value: transaction)),
            for: transaction.productID
        )
        let processor = RecordingTransactionProcessor()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        await client.start()
        defer { Task { await client.stop() } }

        #expect(await processor.transactions == [transaction])
        #expect(await gateway.finishedTransactionIDs == [transaction.id])
        #expect(await pendingStore.references().isEmpty)
    }

    @Test("StoreKit 完全漏报时从 outbox 交付并保留等待 finish 记录")
    func restartDeliversPersistedPayloadWhileWaitingForFinishHandle() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let transaction = PaymentTransaction.fixture(id: 122)
        await pendingStore.insert(PendingTransactionReference(transaction: transaction))

        let gateway = FakePaymentStoreGateway()
        let processor = RecordingTransactionProcessor()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        await client.start()
        defer { Task { await client.stop() } }
        await client.retryUnfinishedTransactions()

        #expect(await processor.transactions == [transaction])
        #expect(await gateway.finishedTransactionIDs.isEmpty)
        #expect(await client.snapshot().pendingTransactions == [
            PaymentPendingTransaction(
                transaction: transaction,
                state: .deliveredAwaitingFinish
            )
        ])
        #expect(await pendingStore.references() == [
            PendingTransactionReference(transaction: transaction).markingDelivered()
        ])
    }

    @Test("已交付订单重新出现原始交易时只 finish 不重复交付")
    func deliveredOutboxRecordFinishesWithoutReprocessing() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let transaction = PaymentTransaction.fixture(id: 123)
        let reference = PendingTransactionReference(transaction: transaction)
        await pendingStore.insert(reference)
        await pendingStore.markDelivered(reference)

        let gateway = FakePaymentStoreGateway()
        await gateway.setUnfinished([.verified(StoreTransaction(value: transaction))])
        let processor = RecordingTransactionProcessor()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        await client.start()
        defer { Task { await client.stop() } }

        #expect(await processor.transactions.isEmpty)
        #expect(await gateway.finishedTransactionIDs == [transaction.id])
        #expect(await pendingStore.references().isEmpty)
    }

    @Test("已交付订单重启后仅重新签名时只补 finish")
    func deliveredOutboxRecordAcceptsResignedEquivalentTransaction() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let original = PaymentTransaction.fixture(
            id: 128,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "original-jws"
        )
        let resigned = PaymentTransaction.fixture(
            id: 128,
            signedDate: Date(timeIntervalSince1970: 20),
            jwsRepresentation: "resigned-jws"
        )
        let reference = PendingTransactionReference(transaction: original)
        await pendingStore.insert(reference)
        await pendingStore.markDelivered(reference)

        let gateway = FakePaymentStoreGateway()
        await gateway.setAllTransactions([.verified(StoreTransaction(value: resigned))])
        let processor = RecordingTransactionProcessor()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        let report = await client.retryUnfinishedTransactions()

        #expect(await processor.transactions.isEmpty)
        #expect(await gateway.finishedTransactionIDs == [resigned.id])
        #expect(await pendingStore.references().isEmpty)
        #expect(report.deliveredCount == 0)
        #expect(report.finishedCount == 1)
    }

    @Test("刷新取得不能 finish 的等价重新签名交易时保持等待 finish")
    func refreshPreservesDeliveredStateForResignedEquivalentTransaction() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let original = PaymentTransaction.fixture(
            id: 135,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "delivered-original-jws"
        )
        let resigned = PaymentTransaction.fixture(
            id: 135,
            signedDate: Date(timeIntervalSince1970: 20),
            jwsRepresentation: "delivered-resigned-jws"
        )
        let reference = PendingTransactionReference(transaction: original)
        await pendingStore.markDelivered(reference)

        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([StoreProduct(value: .fixture(id: original.productID))])
        await gateway.setUnfinished([
            .verified(StoreTransaction(value: resigned, canFinish: false))
        ])
        let processor = RecordingTransactionProcessor()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        let snapshot = try await client.refresh()
        let resignedPending = try #require(
            snapshot.pendingTransactions.first { $0.transaction == resigned }
        )

        #expect(resignedPending.state == .deliveredAwaitingFinish)
        #expect(!snapshot.pendingTransactions.contains { pending in
            pending.transaction.deliveryState == resigned.deliveryState
                && pending.state == .awaitingDelivery
        })
        #expect(await processor.transactions.isEmpty)
        #expect(await gateway.finishedTransactionIDs.isEmpty)
        #expect(await pendingStore.references() == [reference])
    }

    @Test("刷新取得已交付 outbox 的真实句柄时只补 finish")
    func refreshFinishesDeliveredOutboxWithoutReprocessing() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let original = PaymentTransaction.fixture(
            id: 140,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "delivered-original-jws"
        )
        let resigned = PaymentTransaction.fixture(
            id: 140,
            signedDate: Date(timeIntervalSince1970: 20),
            jwsRepresentation: "delivered-resigned-jws"
        )
        let originalReference = PendingTransactionReference(transaction: original)
        await pendingStore.markDelivered(originalReference)

        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([StoreProduct(value: .fixture(id: original.productID))])
        await gateway.setUnfinished([
            .verified(StoreTransaction(value: resigned, canFinish: true))
        ])
        let processor = RecordingTransactionProcessor()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        let snapshot = try await client.refresh()

        #expect(snapshot.pendingTransactions.isEmpty)
        #expect(await processor.transactions.isEmpty)
        #expect(await gateway.finishedTransactionIDs == [resigned.id])
        #expect(await pendingStore.references().isEmpty)

        // 随后相同更新只能再次幂等 finish，不能因 outbox 已清理而重复后台交付。
        await client.start()
        await gateway.sendUpdate(
            .verified(StoreTransaction(value: resigned, canFinish: true))
        )
        try await waitUntil {
            await gateway.finishedTransactionIDs.count == 2
        }
        #expect(await processor.transactions.isEmpty)
        await client.stop()
    }

    @Test("刷新不会处理尚未完成后台交付的 outbox")
    func refreshDoesNotProcessAwaitingDeliveryOutbox() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let transaction = PaymentTransaction.fixture(id: 141)
        let reference = PendingTransactionReference(transaction: transaction)
        await pendingStore.insert(reference)

        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await gateway.setUnfinished([
            .verified(StoreTransaction(value: transaction, canFinish: true))
        ])
        let processor = RecordingTransactionProcessor()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        let snapshot = try await client.refresh()

        #expect(snapshot.pendingTransactions == [
            PaymentPendingTransaction(
                transaction: transaction,
                state: .awaitingDelivery
            )
        ])
        #expect(await processor.transactions.isEmpty)
        #expect(await gateway.finishedTransactionIDs.isEmpty)
        #expect(await pendingStore.references() == [reference])
    }

    @Test("刷新不会把撤销等新业务状态误判为已交付")
    func refreshKeepsChangedResignedTransactionAwaitingDelivery() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let original = PaymentTransaction.fixture(
            id: 136,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "state-original-jws"
        )
        let revoked = PaymentTransaction.fixture(
            id: 136,
            signedDate: Date(timeIntervalSince1970: 20),
            revocationDate: Date(timeIntervalSince1970: 19),
            jwsRepresentation: "state-revoked-jws"
        )
        await pendingStore.markDelivered(PendingTransactionReference(transaction: original))

        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([StoreProduct(value: .fixture(id: original.productID))])
        await gateway.setUnfinished([
            .verified(StoreTransaction(value: revoked, canFinish: false))
        ])
        let client = makeClient(gateway: gateway, pendingStore: pendingStore)

        let snapshot = try await client.refresh()
        let revokedPending = try #require(
            snapshot.pendingTransactions.first { $0.transaction == revoked }
        )

        #expect(revokedPending.state == .awaitingDelivery)
    }

    @Test("StoreKit 暂未报告已交付订单时保留等待 finish 记录")
    func deliveredOutboxRecordWaitsWhenStoreKitDoesNotReportIt() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let transaction = PaymentTransaction.fixture(id: 127)
        let reference = PendingTransactionReference(transaction: transaction)
        await pendingStore.insert(reference)
        await pendingStore.markDelivered(reference)

        let gateway = FakePaymentStoreGateway()
        let processor = RecordingTransactionProcessor()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        let report = await client.retryUnfinishedTransactions()

        #expect(report.attemptedCount == 1)
        #expect(report.awaitingFinishCount == 1)
        #expect(await processor.transactions.isEmpty)
        #expect(await gateway.finishedTransactionIDs.isEmpty)
        #expect(await pendingStore.references() == [reference])
        #expect(report.snapshot.pendingTransactions == [
            PaymentPendingTransaction(
                transaction: transaction,
                state: .deliveredAwaitingFinish
            )
        ])
    }

    @Test("重新签名交易 finish 后清理同交易的旧签名记录")
    func finishedResignedTransactionRemovesOlderOutboxReference() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let original = PaymentTransaction.fixture(
            id: 125,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "original-signature"
        )
        let resigned = PaymentTransaction.fixture(
            id: 125,
            signedDate: Date(timeIntervalSince1970: 20),
            jwsRepresentation: "resigned-signature"
        )
        await pendingStore.insert(PendingTransactionReference(transaction: original))

        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([StoreProduct(value: .fixture(id: resigned.productID))])
        await gateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: resigned)))
        )
        let processor = RecordingTransactionProcessor()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )
        _ = try await client.reloadProducts()

        _ = try await client.purchase(productID: resigned.productID)

        #expect(await processor.transactions == [resigned])
        #expect(await gateway.finishedTransactionIDs == [resigned.id])
        #expect(await pendingStore.references().isEmpty)
    }

    @Test("结束当前签名时保留同交易的更新签名记录")
    func finishingCurrentSignatureKeepsNewerOutboxReference() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let older = PaymentTransaction.fixture(
            id: 126,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "older-signature"
        )
        let current = PaymentTransaction.fixture(
            id: 126,
            signedDate: Date(timeIntervalSince1970: 20),
            jwsRepresentation: "current-signature"
        )
        let newer = PaymentTransaction.fixture(
            id: 126,
            signedDate: Date(timeIntervalSince1970: 30),
            jwsRepresentation: "newer-signature"
        )
        await pendingStore.insert(PendingTransactionReference(transaction: older))
        await pendingStore.insert(PendingTransactionReference(transaction: newer))

        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([StoreProduct(value: .fixture(id: current.productID))])
        await gateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: current)))
        )
        let client = makeClient(gateway: gateway, pendingStore: pendingStore)
        _ = try await client.reloadProducts()

        _ = try await client.purchase(productID: current.productID)

        #expect(await pendingStore.references() == [
            PendingTransactionReference(transaction: newer)
        ])
    }

    @Test("outbox 同一交易的多个签名只保留最新已交付状态等待 finish")
    func outboxCoalescesMultipleSignaturesForSameTransaction() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let original = PaymentTransaction.fixture(
            id: 124,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "first-signature"
        )
        let resigned = PaymentTransaction.fixture(
            id: 124,
            signedDate: Date(timeIntervalSince1970: 20),
            jwsRepresentation: "second-signature"
        )
        await pendingStore.insert(PendingTransactionReference(transaction: original))
        await pendingStore.insert(PendingTransactionReference(transaction: resigned))

        let gateway = FakePaymentStoreGateway()
        let processor = RecordingTransactionProcessor()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        await client.start()
        defer { Task { await client.stop() } }

        #expect(await processor.transactions == [resigned])
        let remaining = await pendingStore.references()
        #expect(remaining == [
            PendingTransactionReference(transaction: resigned).markingDelivered()
        ])
    }

    @Test("重启补偿再次失败时快照仍报告未完成交易")
    func recoveredTransactionRemainsVisibleWhenProcessingFailsAgain() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let transaction = PaymentTransaction.fixture(id: 118)
        await pendingStore.insert(PendingTransactionReference(transaction: transaction))

        let gateway = FakePaymentStoreGateway()
        await gateway.setAllTransactions([
            .verified(StoreTransaction(value: transaction))
        ])
        let processor = RecordingTransactionProcessor(failuresRemaining: 1)
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        await client.start()
        defer { Task { await client.stop() } }

        #expect(await processor.transactions == [transaction])
        #expect(await gateway.finishedTransactionIDs.isEmpty)
        #expect(await client.snapshot().pendingTransactions == [
            PaymentPendingTransaction(transaction: transaction, state: .awaitingDelivery)
        ])
        #expect(await pendingStore.references().count == 1)
    }

    @Test("重启补偿以同一交易的最新签名状态替代旧状态")
    func recoveryUsesLatestSignedStateWhenOriginalStateIsUnavailable() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let original = PaymentTransaction.fixture(
            id: 119,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "original-jws"
        )
        let revoked = PaymentTransaction.fixture(
            id: 119,
            signedDate: Date(timeIntervalSince1970: 20),
            revocationDate: Date(timeIntervalSince1970: 19),
            jwsRepresentation: "revoked-jws"
        )
        await pendingStore.insert(PendingTransactionReference(transaction: original))

        let gateway = FakePaymentStoreGateway()
        await gateway.setAllTransactions([.verified(StoreTransaction(value: revoked))])
        let processor = RecordingTransactionProcessor()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        await client.start()
        defer { Task { await client.stop() } }

        #expect(await processor.transactions == [revoked])
        #expect(await gateway.finishedTransactionIDs == [revoked.id])
        #expect(await pendingStore.references().isEmpty)
    }

    @Test("交易历史只返回旧签名时不得删除 outbox 中的更新状态")
    func recoveryDoesNotReplaceNewerOutboxStateWithOlderHistory() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let older = PaymentTransaction.fixture(
            id: 133,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "older-history-jws"
        )
        let newerRevocation = PaymentTransaction.fixture(
            id: 133,
            signedDate: Date(timeIntervalSince1970: 20),
            revocationDate: Date(timeIntervalSince1970: 19),
            jwsRepresentation: "newer-outbox-jws"
        )
        await pendingStore.insert(
            PendingTransactionReference(transaction: newerRevocation)
        )

        let gateway = FakePaymentStoreGateway()
        await gateway.setAllTransactions([
            .verified(StoreTransaction(value: older))
        ])
        let processor = RecordingTransactionProcessor()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        let report = await client.retryUnfinishedTransactions()

        #expect(await processor.transactions == [newerRevocation])
        #expect(await gateway.finishedTransactionIDs.isEmpty)
        #expect(await pendingStore.references() == [
            PendingTransactionReference(transaction: newerRevocation)
                .markingDelivered()
        ])
        #expect(report.snapshot.pendingTransactions == [
            PaymentPendingTransaction(
                transaction: newerRevocation,
                state: .deliveredAwaitingFinish
            )
        ])
    }

    @Test("latest 只返回旧签名时不得删除 outbox 中的更新状态")
    func recoveryDoesNotReplaceNewerOutboxStateWithOlderLatestTransaction() async throws {
        let pendingStore = InMemoryPendingTransactionStore()
        let older = PaymentTransaction.fixture(
            id: 134,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "older-latest-jws"
        )
        let newerUpgrade = PaymentTransaction.fixture(
            id: 134,
            signedDate: Date(timeIntervalSince1970: 20),
            jwsRepresentation: "newer-upgrade-jws",
            isUpgraded: true
        )
        await pendingStore.insert(
            PendingTransactionReference(transaction: newerUpgrade)
        )

        let gateway = FakePaymentStoreGateway()
        await gateway.setLatestTransaction(
            .verified(StoreTransaction(value: older)),
            for: newerUpgrade.productID
        )
        let processor = RecordingTransactionProcessor()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        let report = await client.retryUnfinishedTransactions()

        #expect(await processor.transactions == [newerUpgrade])
        #expect(await gateway.finishedTransactionIDs.isEmpty)
        #expect(await pendingStore.references() == [
            PendingTransactionReference(transaction: newerUpgrade)
                .markingDelivered()
        ])
        #expect(report.snapshot.pendingTransactions == [
            PaymentPendingTransaction(
                transaction: newerUpgrade,
                state: .deliveredAwaitingFinish
            )
        ])
    }

    @Test("待批准和用户取消保持为非错误结果")
    func pendingAndCancelledOutcomes() async throws {
        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([StoreProduct(value: .fixture(id: "premium"))])
        await gateway.enqueuePurchaseResult(.pending)
        await gateway.enqueuePurchaseResult(.userCancelled)
        let client = makeClient(gateway: gateway)
        _ = try await client.reloadProducts()

        #expect(try await client.purchase(productID: "premium") == .pending)
        #expect(try await client.purchase(productID: "premium") == .cancelled)
    }

    @Test("未验证交易不会交付或结束")
    func unverifiedTransactionIsRejected() async throws {
        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([StoreProduct(value: .fixture(id: "premium"))])
        await gateway.enqueuePurchaseResult(
            .success(.unverified(transactionID: 102, message: "invalid signature"))
        )
        let processor = RecordingTransactionProcessor()
        let client = makeClient(gateway: gateway, processor: processor)
        _ = try await client.reloadProducts()

        do {
            _ = try await client.purchase(productID: "premium")
            Issue.record("未验证交易不应购买成功")
        } catch let error as PaymentError {
            #expect(error.code == .verificationFailed)
        }

        #expect(await processor.transactions.isEmpty)
        #expect(await gateway.finishedTransactionIDs.isEmpty)
    }

    @Test("同交易仅重新签名且业务状态未变时不重复交付")
    func resignedUnchangedTransactionIsDeliveredOnce() async throws {
        let gateway = FakePaymentStoreGateway()
        let original = PaymentTransaction.fixture(
            id: 104,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "original-jws"
        )
        let resigned = PaymentTransaction.fixture(
            id: 104,
            signedDate: Date(timeIntervalSince1970: 20),
            jwsRepresentation: "resigned-jws"
        )
        await gateway.setProducts([StoreProduct(value: .fixture(id: original.productID))])
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: original))))
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: resigned))))
        let processor = RecordingTransactionProcessor()
        let client = makeClient(gateway: gateway, processor: processor)
        _ = try await client.reloadProducts()

        _ = try await client.purchase(productID: original.productID)
        let secondOutcome = try await client.purchase(productID: resigned.productID)

        #expect(secondOutcome == .completed(resigned))
        #expect(await processor.transactions == [original])
        // 新签名的业务状态未变化时跳过后台，但 StoreKit 再次返回交易仍需补 finish。
        #expect(await gateway.finishedTransactionIDs == [original.id, resigned.id])
    }

    @Test("同进程已处理交易再次出现在 unfinished 时只补 finish")
    func processedTransactionReappearingUnfinishedFinishesAgain() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 132)
        await gateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await gateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: transaction)))
        )
        let processor = RecordingTransactionProcessor()
        let client = makeClient(gateway: gateway, processor: processor)
        _ = try await client.reloadProducts()

        _ = try await client.purchase(productID: transaction.productID)
        await gateway.setUnfinished([.verified(StoreTransaction(value: transaction))])
        let report = await client.retryUnfinishedTransactions()

        // 后台交付只发生一次，但 StoreKit 再次报告 unfinished 时必须再次 finish。
        #expect(await processor.transactions == [transaction])
        #expect(await gateway.finishedTransactionIDs == [transaction.id, transaction.id])
        #expect(report.deliveredCount == 0)
        #expect(report.finishedCount == 1)
        #expect(report.snapshot.pendingTransactions.isEmpty)
    }

    @Test("已完成交易短暂重现为 unfinished 时刷新自动补 finish")
    func refreshAutomaticallyFinishesProcessedUnfinishedTransaction() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 139)
        await gateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await gateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: transaction)))
        )
        let processor = RecordingTransactionProcessor()
        let client = makeClient(gateway: gateway, processor: processor)
        _ = try await client.reloadProducts()

        _ = try await client.purchase(productID: transaction.productID)
        // 真实 Sandbox 在 finish 后可能短暂继续通过 unfinished 返回同一业务状态。
        await gateway.setUnfinished([.verified(StoreTransaction(value: transaction))])
        let snapshot = try await client.refresh()

        #expect(snapshot.pendingTransactions.isEmpty)
        #expect(await processor.transactions == [transaction])
        #expect(await gateway.finishedTransactionIDs == [transaction.id, transaction.id])
    }

    @Test("相同签名事件仅处理一次而新签名状态会再次处理")
    func signedEventDeduplication() async throws {
        let gateway = FakePaymentStoreGateway()
        let original = PaymentTransaction.fixture(
            id: 103,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "original-jws"
        )
        let revoked = PaymentTransaction.fixture(
            id: 103,
            signedDate: Date(timeIntervalSince1970: 20),
            revocationDate: Date(timeIntervalSince1970: 19),
            jwsRepresentation: "revoked-jws"
        )
        await gateway.setProducts([StoreProduct(value: .fixture(id: original.productID))])
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: original))))
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: original))))
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: revoked))))
        let processor = RecordingTransactionProcessor()
        let client = makeClient(gateway: gateway, processor: processor)
        _ = try await client.reloadProducts()

        _ = try await client.purchase(productID: original.productID)
        _ = try await client.purchase(productID: original.productID)
        _ = try await client.purchase(productID: original.productID)

        #expect(await processor.transactions == [original, revoked])
        #expect(await gateway.finishedTransactionIDs == [original.id, original.id, revoked.id])
    }

    @Test("并发到达的相同签名事件等待同一次后台处理")
    func concurrentSignedEventsAwaitSharedProcessing() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 105)
        await gateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: transaction))))
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: transaction))))
        let processor = BlockingTransactionProcessor()
        let client = PaymentClient(
            configuration: PaymentConfiguration(productIDs: [transaction.productID]),
            processor: processor,
            gateway: gateway,
            logger: DisabledPaymentLogHandler()
        )
        _ = try await client.reloadProducts()

        let first = Task { try await client.purchase(productID: transaction.productID) }
        await processor.waitUntilStarted()
        let secondCompleted = CompletionFlag()
        let second = Task {
            let value = try await client.purchase(productID: transaction.productID)
            await secondCompleted.markCompleted()
            return value
        }

        // 第二个调用必须等待首个后台请求，不能提前报告 completed。
        try await Task.sleep(for: .milliseconds(50))
        #expect(await secondCompleted.value == false)

        await processor.resume()
        #expect(try await first.value == .completed(transaction))
        #expect(try await second.value == .completed(transaction))
        #expect(await processor.processCount == 1)
        #expect(await gateway.finishedTransactionIDs == [transaction.id])
    }

    @Test(
        "outbox 重放与真实交易并发时保留唯一可 finish 句柄",
        arguments: [false, true]
    )
    func realTransactionFinishesAfterSyntheticReplay(
        isResigned: Bool
    ) async throws {
        let gateway = FakePaymentStoreGateway()
        let original = PaymentTransaction.fixture(
            id: 109,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "synthetic-replay-jws"
        )
        let storeKitValue = isResigned
            ? PaymentTransaction.fixture(
                id: original.id,
                signedDate: Date(timeIntervalSince1970: 20),
                jwsRepresentation: "storekit-resigned-jws"
            )
            : original
        let pendingStore = InMemoryPendingTransactionStore()
        await pendingStore.insert(PendingTransactionReference(transaction: original))
        let processor = BlockingTransactionProcessor()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        // StoreKit 未返回 unfinished 时，重放会先使用 outbox 中不具备 finish 能力的快照。
        let startup = Task { await client.start() }
        await processor.waitUntilStarted()
        await gateway.sendUpdate(
            .verified(StoreTransaction(value: storeKitValue, canFinish: true)),
            requestNumber: 1
        )
        try await Task.sleep(for: .milliseconds(50))

        await processor.resume()
        await startup.value
        try await waitUntil { await gateway.finishedTransactionIDs == [original.id] }
        #expect(await processor.processCount == 1)
        #expect(await gateway.finishedTransactionIDs == [original.id])
        #expect(await pendingStore.references().isEmpty)
        await client.stop()
    }

    @Test("等待相同签名事件的调用可独立取消")
    func duplicateSignedEventWaiterCanBeCancelled() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 111)
        await gateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: transaction))))
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: transaction))))
        let processor = BlockingTransactionProcessor()
        let client = PaymentClient(
            configuration: PaymentConfiguration(productIDs: [transaction.productID]),
            processor: processor,
            gateway: gateway,
            logger: DisabledPaymentLogHandler()
        )
        _ = try await client.reloadProducts()

        let leader = Task { try await client.purchase(productID: transaction.productID) }
        await processor.waitUntilStarted()
        let cancelled = CompletionFlag()
        let waiter = Task {
            do {
                _ = try await client.purchase(productID: transaction.productID)
            } catch is CancellationError {
                await cancelled.markCompleted()
            } catch {
                // 此测试只接受任务取消；其他错误由下方断言统一报告。
            }
        }
        try await waitUntil { await gateway.purchaseCallCount == 2 }
        waiter.cancel()

        // leader 仍被模拟后台挂起时，waiter 也必须及时释放。
        try await Task.sleep(for: .milliseconds(50))
        #expect(await cancelled.value)

        await processor.resume()
        _ = try await leader.value
        await waiter.value
    }

    @Test("启动不会恢复购买且显式恢复只同步一次")
    func restoreIsExplicit() async throws {
        let gateway = FakePaymentStoreGateway()
        let client = makeClient(gateway: gateway)

        await client.start()
        await client.start()

        #expect(await gateway.updateStreamRequestCount == 1)
        #expect(await gateway.syncCount == 0)

        _ = try await client.restorePurchases()

        #expect(await gateway.syncCount == 1)
    }

    @Test("商店会话热重载清除上一账号的订阅更新缓存且不执行同步")
    func reloadStoreSessionClearsPreviousAccountSubscriptionCache() async throws {
        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: "premium",
                    type: .autoRenewableSubscription,
                    subscriptionGroupID: "group"
                )
            ),
        ])
        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 150,
                        renewalJWS: "account-a-query",
                        willAutoRenew: true
                    ),
                ],
                verificationFailures: []
            )
        )
        let client = makeClient(gateway: gateway)
        await client.start()
        defer { Task { await client.stop() } }

        await gateway.yieldSubscriptionStatusUpdate(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 150,
                        renewalJWS: "account-a-update",
                        willAutoRenew: false
                    ),
                ],
                verificationFailures: []
            )
        )
        try await waitUntil {
            await client.snapshot().subscriptionStatuses.first?
                .renewalInfo.jwsRepresentation == "account-a-update"
        }

        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [],
                verificationFailures: []
            )
        )

        let snapshot = await client.reloadStoreSession()

        #expect(snapshot.subscriptionStatuses.isEmpty)
        #expect(await client.snapshot().subscriptionStatuses.isEmpty)
        #expect(await gateway.updateStreamRequestCount == 2)
        #expect(await gateway.subscriptionStatusUpdateStreamRequestCount == 2)
        #expect(await gateway.syncCount == 0)
    }

    @Test("显式恢复同步后重建商店会话并清除上一账号状态")
    func restorePurchasesRebindsStoreSessionAfterAccountSwitch() async throws {
        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: "premium",
                    type: .autoRenewableSubscription,
                    subscriptionGroupID: "group"
                )
            ),
        ])
        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 151,
                        renewalJWS: "account-a-query",
                        willAutoRenew: true
                    ),
                ],
                verificationFailures: []
            )
        )
        let client = makeClient(gateway: gateway)
        await client.start()
        defer { Task { await client.stop() } }

        await gateway.yieldSubscriptionStatusUpdate(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 151,
                        renewalJWS: "account-a-update",
                        willAutoRenew: false
                    ),
                ],
                verificationFailures: []
            )
        )
        try await waitUntil {
            await client.snapshot().subscriptionStatuses.first?
                .renewalInfo.jwsRepresentation == "account-a-update"
        }

        // AppStore.sync() 完成后，StoreKit 查询已经代表账号 B。恢复流程还必须
        // 清除账号 A 的订阅更新缓存并重建长期监听，不能只在旧会话上 refresh。
        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [],
                verificationFailures: []
            )
        )

        let snapshot = try await client.restorePurchases()

        #expect(snapshot.subscriptionStatuses.isEmpty)
        #expect(await client.snapshot().subscriptionStatuses.isEmpty)
        #expect(await gateway.syncCount == 1)
        #expect(await gateway.updateStreamRequestCount == 2)
        #expect(await gateway.subscriptionStatusUpdateStreamRequestCount == 2)
    }

    @Test("恢复购买保留可诊断的 StoreKit 网络错误类别")
    func restorePreservesStoreKitNetworkErrorCategory() async {
        let gateway = FakePaymentStoreGateway()
        await gateway.failNextSync(
            with: .networkError(URLError(.notConnectedToInternet))
        )
        let logger = RecordingPaymentLogHandler()
        let client = makeClient(gateway: gateway, logger: logger)

        do {
            _ = try await client.restorePurchases()
            Issue.record("App Store 同步网络失败时不应返回成功")
        } catch let error as PaymentError {
            #expect(error.code == .storeKitFailed)
            #expect(error.message == "恢复购买失败：App Store 网络错误（-1009）")
        } catch {
            Issue.record("StoreKit 网络错误应映射为 PaymentError")
        }

        #expect(logger.entries.contains {
            $0.category == "restore"
                && $0.message == "恢复购买同步失败"
                && $0.metadata["storeKitError"] == "network"
                && $0.metadata["urlErrorCode"] == "-1009"
        })
    }

    @Test("恢复购买的 StoreKit 系统错误不会泄露底层敏感文本")
    func restoreStoreKitSystemErrorIsPrivacySafe() async {
        let sensitiveText = "sandbox-account@example.com"
        let gateway = FakePaymentStoreGateway()
        await gateway.failNextSync(
            with: .systemError(
                NSError(
                    domain: "ASDErrorDomain",
                    code: 509,
                    userInfo: [NSLocalizedDescriptionKey: sensitiveText]
                )
            )
        )
        let logger = RecordingPaymentLogHandler()
        let client = makeClient(gateway: gateway, logger: logger)

        do {
            _ = try await client.restorePurchases()
            Issue.record("App Store 系统同步失败时不应返回成功")
        } catch let error as PaymentError {
            #expect(error.code == .storeKitFailed)
            #expect(error.message == "恢复购买失败：App Store 系统错误（ASDErrorDomain 509）")
            #expect(!error.message.contains(sensitiveText))
        } catch {
            Issue.record("StoreKit 系统错误应映射为 PaymentError")
        }

        let renderedEntries = logger.entries.map {
            "\($0.message) \($0.metadata)"
        }
        #expect(renderedEntries.allSatisfy { !$0.contains(sensitiveText) })
        #expect(logger.entries.contains {
            $0.category == "restore"
                && $0.metadata["storeKitError"] == "system"
                && $0.metadata["underlyingErrorDomain"] == "ASDErrorDomain"
                && $0.metadata["underlyingErrorCode"] == "509"
        })
    }

    @Test("恢复认证期间的前台事件不会用瞬时空权益覆盖有效快照")
    func foregroundActivationDuringRestorePreservesLatestSnapshot() async throws {
        let context = makeClientWithControllableApplicationActivity()
        let entitlement = PaymentTransaction.fixture(
            id: 126,
            productID: "premium",
            productType: .nonConsumable
        )
        await context.gateway.setEntitlements([
            .verified(StoreTransaction(value: entitlement))
        ])
        await context.client.start()
        let baselineSnapshot = await context.client.snapshot()
        let baselineProductRequests = await context.gateway.productLoadRequestCount
        let baselineEntitlementRequests = await context.gateway.entitlementRequestCount
        await context.gateway.blockNextSync()
        await context.gateway.cancelNextSync()

        let restore = Task {
            try await context.client.restorePurchases()
        }
        await context.gateway.waitUntilBlockedSyncStarts()

        // 系统认证界面切换活动状态时，StoreKit 可能短暂返回空权益。
        await context.gateway.setEntitlements([])
        await context.activity.yieldActivation()
        try await Task.sleep(for: .milliseconds(300))

        #expect(await context.client.snapshot() == baselineSnapshot)
        #expect(await context.gateway.productLoadRequestCount == baselineProductRequests)
        #expect(await context.gateway.entitlementRequestCount == baselineEntitlementRequests)

        await context.gateway.resumeBlockedSync()
        do {
            _ = try await restore.value
            Issue.record("取消的恢复同步不应成功")
        } catch is CancellationError {
            // 此用例只用取消结束受控同步；快照保留行为与具体失败类型无关。
        } catch {
            Issue.record("受控同步取消不应被包装成其他错误")
        }
        #expect(await context.client.snapshot() == baselineSnapshot)
        await context.client.stop()
    }

    @Test("应用进入前台后自动重新加载商品和支付状态")
    func foregroundActivationAutomaticallyRefreshesState() async throws {
        let context = makeClientWithControllableApplicationActivity()
        await context.client.start()
        let initialProductRequestCount = await context.gateway.productLoadRequestCount
        let initialEntitlementRequestCount = await context.gateway.entitlementRequestCount

        await context.activity.yieldActivation()

        try await waitUntil {
            let productRequestCount = await context.gateway.productLoadRequestCount
            let entitlementRequestCount = await context.gateway.entitlementRequestCount
            return productRequestCount == initialProductRequestCount + 1
                && entitlementRequestCount == initialEntitlementRequestCount + 1
        }
        await context.client.stop()
    }

    @Test("应用进入前台后自动重放新发现的 unfinished 交易")
    func foregroundActivationReplaysNewlyDiscoveredUnfinishedTransactions() async throws {
        let gateway = FakePaymentStoreGateway()
        let activity = ControllableApplicationActivity()
        let processor = RecordingTransactionProcessor()
        let client = PaymentClient(
            configuration: PaymentConfiguration(productIDs: ["premium"]),
            processor: processor,
            gateway: gateway,
            pendingStore: InMemoryPendingTransactionStore(),
            logger: DisabledPaymentLogHandler(),
            applicationActivitySource: activity.source()
        )
        await client.start()
        defer { Task { await client.stop() } }

        let transaction = PaymentTransaction.fixture(id: 127)
        await gateway.setUnfinished([
            .verified(StoreTransaction(value: transaction, canFinish: true))
        ])

        await activity.yieldActivation()

        try await waitUntil {
            await gateway.finishedTransactionIDs == [transaction.id]
        }
        #expect(await processor.transactions == [transaction])
        #expect(await client.snapshot().pendingTransactions.isEmpty)
    }

    @Test("Storefront 变化后自动重新加载商品价格和可用性")
    func storefrontUpdateAutomaticallyReloadsProducts() async throws {
        let context = makeClientWithControllableStorefrontUpdates()
        await context.gateway.setProducts([
            StoreProduct(value: .fixture(id: "premium")),
        ])
        await context.client.start()
        #expect(await context.client.snapshot().unavailableProductIDs == ["bonus"])

        await context.gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: "premium",
                    price: 2.99,
                    displayPrice: "US$2.99"
                )
            ),
            StoreProduct(value: .fixture(id: "bonus")),
        ])
        await context.gateway.yieldStorefrontUpdate()

        try await waitUntil {
            let snapshot = await context.client.snapshot()
            return snapshot.products.first?.displayPrice == "US$2.99"
                && snapshot.unavailableProductIDs.isEmpty
        }
        await context.client.stop()
    }

    @Test("订阅状态更新后自动刷新取消续订偏好")
    func subscriptionStatusUpdateAutomaticallyRefreshesRenewalPreference() async throws {
        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: "premium",
                    type: .autoRenewableSubscription,
                    subscriptionGroupID: "group"
                )
            ),
        ])
        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 140,
                        willAutoRenew: true
                    ),
                ],
                verificationFailures: []
            )
        )
        let client = makeClient(gateway: gateway)
        await client.start()
        defer { Task { await client.stop() } }
        #expect(
            await client.snapshot().subscriptionStatuses.first?
                .renewalInfo.willAutoRenew == true
        )
        let baselineProductRequestCount = await gateway.productLoadRequestCount
        let baselineStatusRequestCount = await gateway.subscriptionStatusRequestCount

        await gateway.yieldSubscriptionStatusUpdate(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 140,
                        renewalJWS: "cancelled-renewal-jws",
                        willAutoRenew: false
                    ),
                ],
                verificationFailures: []
            )
        )

        try await waitUntil {
            await client.snapshot().subscriptionStatuses.first?
                .renewalInfo.willAutoRenew == false
        }
        #expect(await gateway.productLoadRequestCount == baselineProductRequestCount)
        #expect(
            await gateway.subscriptionStatusRequestCount
                == baselineStatusRequestCount + 1
        )
        #expect(await gateway.syncCount == 0)
    }

    @Test("主动查询为空时保留已验签订阅状态更新")
    func emptySubscriptionQueryPreservesVerifiedStatusUpdate() async throws {
        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: "premium",
                    type: .autoRenewableSubscription,
                    subscriptionGroupID: "group"
                )
            ),
        ])
        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 141,
                        renewalJWS: "queried-renewal-jws",
                        willAutoRenew: true
                    ),
                ],
                verificationFailures: [],
                renewalInfoSignedDatesByStatusID: [
                    "group|141": Date(timeIntervalSince1970: 10),
                ]
            )
        )
        let client = makeClient(gateway: gateway)
        await client.start()
        defer { Task { await client.stop() } }

        await gateway.yieldSubscriptionStatusUpdate(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 141,
                        renewalJWS: "updated-renewal-jws",
                        willAutoRenew: false
                    ),
                ],
                verificationFailures: [],
                renewalInfoSignedDatesByStatusID: [
                    "group|141": Date(timeIntervalSince1970: 20),
                ]
            )
        )
        try await waitUntil {
            await client.snapshot().subscriptionStatuses.first?
                .renewalInfo.jwsRepresentation == "updated-renewal-jws"
        }

        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [],
                verificationFailures: []
            )
        )

        let snapshot = try await client.refresh()

        #expect(snapshot.subscriptionStatuses.count == 1)
        #expect(
            snapshot.subscriptionStatuses.first?.renewalInfo.jwsRepresentation
                == "updated-renewal-jws"
        )
        #expect(snapshot.subscriptionStatuses.first?.renewalInfo.willAutoRenew == false)
    }

    @Test("较新的主动查询淘汰旧订阅状态更新缓存")
    func newerSubscriptionQueryEvictsOlderStatusUpdate() async throws {
        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: "premium",
                    type: .autoRenewableSubscription,
                    subscriptionGroupID: "group"
                )
            ),
        ])
        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [],
                verificationFailures: []
            )
        )
        let client = makeClient(gateway: gateway)
        await client.start()
        defer { Task { await client.stop() } }

        await gateway.yieldSubscriptionStatusUpdate(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 142,
                        renewalJWS: "older-update-renewal-jws",
                        willAutoRenew: false
                    ),
                ],
                verificationFailures: [],
                renewalInfoSignedDatesByStatusID: [
                    "group|142": Date(timeIntervalSince1970: 20),
                ]
            )
        )
        try await waitUntil {
            await client.snapshot().subscriptionStatuses.first?
                .renewalInfo.jwsRepresentation == "older-update-renewal-jws"
        }

        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 142,
                        renewalJWS: "newer-query-renewal-jws",
                        willAutoRenew: true
                    ),
                ],
                verificationFailures: [],
                renewalInfoSignedDatesByStatusID: [
                    "group|142": Date(timeIntervalSince1970: 30),
                ]
            )
        )

        let newerSnapshot = try await client.refresh()
        #expect(
            newerSnapshot.subscriptionStatuses.first?.renewalInfo.jwsRepresentation
                == "newer-query-renewal-jws"
        )

        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [],
                verificationFailures: []
            )
        )

        let emptySnapshot = try await client.refresh()
        #expect(emptySnapshot.subscriptionStatuses.isEmpty)
    }

    @Test("按交易查询的新续订状态覆盖陈旧订阅组结果")
    func transactionSpecificSubscriptionStatusOverridesStaleGroupResult() async throws {
        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: "premium",
                    type: .autoRenewableSubscription,
                    subscriptionGroupID: "group"
                )
            ),
        ])
        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(transactionID: 142, willAutoRenew: true),
                ],
                verificationFailures: []
            )
        )
        await gateway.filterSubscriptionResultsByRequestedGroups()
        await gateway.setTransactionSpecificSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 142,
                        renewalJWS: "transaction-specific-renewal-jws",
                        willAutoRenew: false
                    ),
                ],
                verificationFailures: []
            ),
            for: 142
        )

        let client = makeClient(gateway: gateway)
        await client.start()
        defer { Task { await client.stop() } }

        #expect(
            await client.snapshot().subscriptionStatuses.first?
                .renewalInfo.willAutoRenew == false
        )
        #expect(await gateway.transactionSpecificSubscriptionStatusRequestCount == 1)
    }

    @Test("订阅状态监听结束后重连且停止后不再建立")
    func subscriptionStatusUpdatesReconnectUntilStopped() async throws {
        let gateway = FakePaymentStoreGateway()
        let client = makeClient(gateway: gateway)
        await client.start()
        await gateway.finishSubscriptionStatusUpdates()
        try await gateway.waitForSubscriptionStatusUpdateRequestCount(2)

        await client.stop()
        await gateway.finishSubscriptionStatusUpdates()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await gateway.subscriptionStatusUpdateRequestCount() == 2)
    }

    @Test("订阅状态流每次仅返回一条时重连仍保持指数退避")
    func shortLivedSubscriptionStatusUpdatesKeepReconnectBackoff() async throws {
        let gateway = FakePaymentStoreGateway()
        let logger = RecordingPaymentLogHandler()
        let client = makeClient(gateway: gateway, logger: logger)
        await client.start()
        defer { Task { await client.stop() } }

        for requestNumber in 1...3 {
            await gateway.yieldSubscriptionStatusUpdate(requestNumber: requestNumber)
            await gateway.finishSubscriptionStatusUpdates(requestNumber: requestNumber)
            if requestNumber < 3 {
                try await gateway.waitForSubscriptionStatusUpdateRequestCount(
                    requestNumber + 1
                )
            }
        }

        try await Task.sleep(for: .milliseconds(600))
        #expect(await gateway.subscriptionStatusUpdateRequestCount() == 3)
        #expect(
            logger.entries.filter {
                $0.category == "subscription-status"
                    && $0.message == "订阅状态监听意外结束，准备重新建立"
            }.count == 1
        )
        #expect(
            !logger.entries.contains {
                $0.category == "subscription-status"
                    && $0.message == "忽略重复的订阅状态事件"
            }
        )
    }

    @Test("完全相同的订阅状态事件不会重复刷新")
    func duplicateSubscriptionStatusUpdateDoesNotRefreshAgain() async throws {
        let gateway = FakePaymentStoreGateway()
        let client = makeClient(gateway: gateway)
        await client.start()
        defer { Task { await client.stop() } }
        let baseline = await gateway.subscriptionStatusRequestCount
        let update = StoreSubscriptionStatusResult(
            statuses: [.fixture(transactionID: 152)],
            verificationFailures: []
        )

        await gateway.yieldSubscriptionStatusUpdate(update)
        try await waitUntil {
            await gateway.subscriptionStatusRequestCount == baseline + 1
        }
        try await Task.sleep(for: .milliseconds(100))

        await gateway.yieldSubscriptionStatusUpdate(update)
        try await Task.sleep(for: .milliseconds(300))

        #expect(await gateway.subscriptionStatusRequestCount == baseline + 1)
    }

    @Test("Storefront 监听结束后重连且停止后不再建立")
    func storefrontUpdatesReconnectUntilStopped() async throws {
        let context = makeClientWithControllableStorefrontUpdates()
        await context.client.start()
        await context.gateway.finishStorefrontUpdates()
        try await context.gateway.waitForStorefrontRequestCount(2)

        await context.client.stop()
        await context.gateway.finishStorefrontUpdates()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await context.gateway.storefrontRequestCount() == 2)
    }

    @Test("连续前台事件合并且停止后不再刷新")
    func coalescesForegroundRefreshAndStopsWithLifecycle() async throws {
        let context = makeClientWithControllableApplicationActivity()
        await context.client.start()
        let baseline = await context.gateway.productLoadRequestCount

        await context.activity.yieldActivation(count: 3)
        try await waitUntil {
            await context.gateway.productLoadRequestCount == baseline + 1
        }

        await context.client.stop()
        await context.activity.yieldActivation()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await context.gateway.productLoadRequestCount == baseline + 1)
    }

    @Test("同一合并窗口内完整刷新覆盖轻量刷新")
    func fullAutomaticRefreshOverridesPendingStateRefresh() async throws {
        let context = makeClientWithControllableApplicationActivity()
        await context.client.start()
        let baselineProducts = await context.gateway.productLoadRequestCount
        let baselineEntitlements = await context.gateway.entitlementRequestCount

        await context.client.requestAutomaticRefresh(
            .state,
            reason: "测试轻量刷新",
            generation: 1
        )
        await context.client.requestAutomaticRefresh(
            .full,
            reason: "测试完整刷新",
            generation: 1
        )

        try await waitUntil {
            let productRequests = await context.gateway.productLoadRequestCount
            let entitlementRequests = await context.gateway.entitlementRequestCount
            return productRequests == baselineProducts + 1
                && entitlementRequests == baselineEntitlements + 1
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await context.gateway.productLoadRequestCount == baselineProducts + 1)
        #expect(await context.gateway.entitlementRequestCount == baselineEntitlements + 1)
        await context.client.stop()
    }

    @Test("轻量自动刷新保留商品并更新支付状态")
    func stateAutomaticRefreshDoesNotReloadProducts() async throws {
        let context = makeClientWithControllableApplicationActivity()
        await context.client.start()
        let baselineProducts = await context.gateway.productLoadRequestCount
        let baselineEntitlements = await context.gateway.entitlementRequestCount

        await context.client.requestAutomaticRefresh(
            .state,
            reason: "测试轻量刷新",
            generation: 1
        )

        try await waitUntil {
            await context.gateway.entitlementRequestCount == baselineEntitlements + 1
        }
        #expect(await context.gateway.productLoadRequestCount == baselineProducts)
        await context.client.stop()
    }

    @Test("自动刷新期间的新触发会在当前刷新后再执行一次")
    func triggerDuringAutomaticRefreshRunsFollowUpRefresh() async throws {
        let context = makeClientWithControllableApplicationActivity()
        await context.client.start()
        let baseline = await context.gateway.productLoadRequestCount
        await context.gateway.blockNextProductLoadRequest()

        await context.activity.yieldActivation()
        try await waitUntil {
            await context.gateway.productLoadRequestCount == baseline + 1
        }

        await context.activity.yieldActivation()
        await context.gateway.resumeBlockedProductLoadRequest()
        try await waitUntil {
            await context.gateway.productLoadRequestCount == baseline + 2
        }
        await context.client.stop()
    }

    @Test("自动完整刷新失败时保留最近一次快照")
    func failedAutomaticRefreshPreservesLatestSnapshot() async throws {
        let gateway = FakePaymentStoreGateway()
        let activity = ControllableApplicationActivity()
        let logger = RecordingPaymentLogHandler()
        await gateway.setProducts([
            StoreProduct(value: .fixture(id: "premium")),
        ])
        let client = PaymentClient(
            configuration: PaymentConfiguration(productIDs: ["premium"]),
            processor: RecordingTransactionProcessor(),
            gateway: gateway,
            logger: logger,
            applicationActivitySource: activity.source()
        )
        await client.start()
        defer { Task { await client.stop() } }
        let baselineSnapshot = await client.snapshot()
        let failedRequestNumber = await gateway.productLoadRequestCount + 1
        await gateway.failProductLoad(requestNumber: failedRequestNumber)

        await activity.yieldActivation()

        try await waitUntil {
            logger.entries.contains {
                $0.message == "自动刷新失败，保留最近一次完整快照"
            }
        }
        #expect(await client.snapshot() == baselineSnapshot)
    }

    @Test("重新启动后应用活动监听只接受当前生命周期事件")
    func applicationActivityListenerUsesCurrentLifecycleGeneration() async throws {
        let context = makeClientWithControllableApplicationActivity()
        await context.client.start()
        await context.client.stop()
        await context.client.start()
        let baseline = await context.gateway.productLoadRequestCount

        await context.activity.yieldActivation(requestNumber: 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await context.gateway.productLoadRequestCount == baseline)

        await context.activity.yieldActivation(requestNumber: 2)
        try await waitUntil {
            await context.gateway.productLoadRequestCount == baseline + 1
        }
        await context.client.stop()
    }

    @Test("轻量自动刷新在最终持久存储读取期间停止后不提交快照或事件")
    func stoppedAutomaticStateRefreshDoesNotCommitAfterFinalAwait() async throws {
        let pendingStore = ControllableReferencesPendingTransactionStore()
        let context = makeClientWithControllableApplicationActivity(
            pendingStore: pendingStore
        )
        await context.client.start()
        let baselineReadCount = await pendingStore.referenceReadCount
        let baselineSnapshot = await context.client.snapshot()
        let updatedEntitlement = PaymentTransaction.fixture(id: 141)
        await context.gateway.setEntitlements([
            .verified(StoreTransaction(value: updatedEntitlement))
        ])

        let recorder = PaymentEventRecorder()
        let events = await context.client.events()
        let recordingTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }
        defer { recordingTask.cancel() }

        await pendingStore.blockReferenceRead(
            requestNumber: baselineReadCount + 2
        )
        await context.client.requestAutomaticRefresh(
            .state,
            reason: "测试最终提交竞态",
            generation: 1
        )
        await pendingStore.waitUntilBlockedReadStarts()

        await context.client.stop()
        await pendingStore.resumeBlockedRead()
        try await Task.sleep(for: .milliseconds(100))

        #expect(await context.client.snapshot() == baselineSnapshot)
        #expect(await recorder.snapshotUpdateCount == 0)
    }

    @Test("订阅边界与同窗口完整刷新合并为一次完整状态查询")
    func boundaryAndForegroundFullRefreshShareAutomaticRefreshBatch() async throws {
        let now = Date(timeIntervalSince1970: 9_000)
        let boundary = now.addingTimeInterval(10)
        let gateway = FakePaymentStoreGateway()
        let clock = ControllableAutomaticRefreshClock(now: now)
        let activity = ControllableApplicationActivity()
        await gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: "premium",
                    type: .autoRenewableSubscription,
                    subscriptionGroupID: "group"
                )
            ),
        ])
        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 1421,
                        boundary: boundary,
                        kind: .expiration
                    ),
                ],
                verificationFailures: []
            )
        )
        let client = PaymentClient(
            configuration: PaymentConfiguration(productIDs: ["premium"]),
            processor: RecordingTransactionProcessor(),
            gateway: gateway,
            logger: DisabledPaymentLogHandler(),
            applicationActivitySource: activity.source(),
            automaticRefreshClock: clock.paymentClock
        )
        await client.start()
        defer { Task { await client.stop() } }
        try await waitUntil {
            clock.pendingDeadlines == [boundary]
        }
        let baselineProductRequestCount = await gateway.productLoadRequestCount
        let baselineEntitlementRequestCount = await gateway.entitlementRequestCount
        let baselineSubscriptionRequestCount =
            await gateway.subscriptionStatusRequestCount

        clock.advance(to: boundary)
        await Task.yield()
        await activity.yieldActivation()

        try await waitUntil {
            let productRequestCount = await gateway.productLoadRequestCount
            let entitlementRequestCount = await gateway.entitlementRequestCount
            let subscriptionRequestCount = await gateway.subscriptionStatusRequestCount
            return productRequestCount == baselineProductRequestCount + 1
                && entitlementRequestCount >= baselineEntitlementRequestCount + 1
                && subscriptionRequestCount >= baselineSubscriptionRequestCount + 1
                && clock.pendingDeadlines == [boundary.addingTimeInterval(1)]
        }
        try await Task.sleep(for: .milliseconds(250))

        #expect(await gateway.productLoadRequestCount == baselineProductRequestCount + 1)
        #expect(
            await gateway.entitlementRequestCount
                == baselineEntitlementRequestCount + 1
        )
        #expect(
            await gateway.subscriptionStatusRequestCount
                == baselineSubscriptionRequestCount + 1
        )
        #expect(clock.pendingDeadlines == [boundary.addingTimeInterval(1)])
    }

    @Test(
        "订阅到期、续订、宽限期和承诺边界自动刷新状态",
        arguments: SubscriptionBoundaryKind.allCases
    )
    func refreshesAtSubscriptionTimeBoundaries(
        _ boundaryKind: SubscriptionBoundaryKind
    ) async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let boundary = now.addingTimeInterval(30)
        let context = makeClientWithControllableAutomaticRefreshClock(now: now)
        await context.gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: "premium",
                    type: .autoRenewableSubscription,
                    subscriptionGroupID: "group"
                )
            ),
        ])
        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 143,
                        state: boundaryKind == .gracePeriod
                            ? .inGracePeriod
                            : .subscribed,
                        boundary: boundary,
                        kind: boundaryKind
                    ),
                ],
                verificationFailures: []
            )
        )
        await context.client.start()
        defer { Task { await context.client.stop() } }
        try await waitUntil {
            context.clock.pendingDeadlines == [boundary]
        }
        let baselineRequestCount = await context.gateway.subscriptionStatusRequestCount

        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(transactionID: 143, state: .expired),
                ],
                verificationFailures: []
            )
        )
        context.clock.advance(to: boundary)

        try await waitUntil {
            await context.client.snapshot().subscriptionStatuses.first?.state == .expired
        }
        #expect(
            await context.gateway.subscriptionStatusRequestCount
                == baselineRequestCount + 1
        )
    }

    @Test("StoreKit 边界状态延迟时按固定序列有限重试")
    func retriesStaleBoundaryStateWithoutPermanentPolling() async throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let boundary = now.addingTimeInterval(10)
        let context = makeClientWithControllableAutomaticRefreshClock(now: now)
        let staleStatus = PaymentSubscriptionStatus.fixture(
            transactionID: 144,
            boundary: boundary,
            kind: .expiration
        )
        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [staleStatus],
                verificationFailures: []
            )
        )
        await context.client.start()
        defer { Task { await context.client.stop() } }
        try await waitUntil {
            context.clock.pendingSleepCount == 1
        }
        context.clock.keepOnlyPendingDeadlinesInHistory()
        let baselineRequestCount = await context.gateway.subscriptionStatusRequestCount
        let expectedDeadlines = [
            boundary,
            boundary.addingTimeInterval(1),
            boundary.addingTimeInterval(3),
            boundary.addingTimeInterval(8),
            boundary.addingTimeInterval(23),
        ]

        for completedAttemptCount in 1...5 {
            try await waitUntil {
                context.clock.pendingSleepCount == 1
            }
            context.clock.advanceToNextSleep()
            try await waitUntil {
                let requestCount = await context.gateway.subscriptionStatusRequestCount
                let expectedPendingCount = completedAttemptCount < 5 ? 1 : 0
                return requestCount == baselineRequestCount + completedAttemptCount
                    && context.clock.pendingSleepCount == expectedPendingCount
            }
        }

        #expect(context.clock.scheduledDeadlines == expectedDeadlines)
        #expect(context.clock.pendingSleepCount == 0)
        #expect(context.clock.boundarySleepDeadlines == [boundary])
        #expect(
            context.clock.retrySleepDeadlines
                == Array(expectedDeadlines.dropFirst())
        )
    }

    @Test(
        "同一订阅同日重叠边界共享一组有限重试",
        arguments: OverlappingSubscriptionBoundaryKinds.allCases
    )
    func overlappingKindsAtSameActualBoundaryShareOneRetrySequence(
        _ boundaryKinds: OverlappingSubscriptionBoundaryKinds
    ) async throws {
        let now = Date(timeIntervalSince1970: 24_000)
        let boundary = now.addingTimeInterval(10)
        let context = makeClientWithControllableAutomaticRefreshClock(now: now)
        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 1440,
                        boundary: boundary,
                        kind: .expiration,
                        renewalDate: boundary,
                        commitmentRenewalDate:
                            boundaryKinds == .expirationRenewalAndCommitment
                                ? boundary
                                : nil
                    ),
                ],
                verificationFailures: []
            )
        )
        await context.client.start()
        defer { Task { await context.client.stop() } }
        try await waitUntil {
            context.clock.pendingDeadlines == [boundary]
        }
        context.clock.keepOnlyPendingDeadlinesInHistory()
        let baselineRequestCount = await context.gateway.subscriptionStatusRequestCount
        let expectedDeadlines = [
            boundary,
            boundary.addingTimeInterval(1),
            boundary.addingTimeInterval(3),
            boundary.addingTimeInterval(8),
            boundary.addingTimeInterval(23),
        ]

        for completedAttemptCount in 1...5 {
            context.clock.advanceToNextSleep()
            try await waitUntil {
                let requestCount = await context.gateway.subscriptionStatusRequestCount
                let expectedPendingCount = completedAttemptCount < 5 ? 1 : 0
                return requestCount == baselineRequestCount + completedAttemptCount
                    && context.clock.pendingSleepCount == expectedPendingCount
            }
        }

        #expect(context.clock.scheduledDeadlines == expectedDeadlines)
        #expect(context.clock.pendingSleepCount == 0)
    }

    @Test("非宽限期状态经过宽限期日期不会启动收敛重试")
    func graceBoundaryOnlyConvergesForGracePeriodState() async throws {
        let now = Date(timeIntervalSince1970: 24_500)
        let boundary = now.addingTimeInterval(10)
        let context = makeClientWithControllableAutomaticRefreshClock(now: now)
        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 14401,
                        state: .subscribed,
                        boundary: boundary,
                        kind: .gracePeriod
                    ),
                ],
                verificationFailures: []
            )
        )
        await context.client.start()
        defer { Task { await context.client.stop() } }
        try await waitUntil {
            context.clock.pendingDeadlines == [boundary]
        }
        let recorder = PaymentEventRecorder()
        let events = await context.client.events()
        let recordingTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }
        defer { recordingTask.cancel() }

        context.clock.advance(to: boundary)

        try await waitUntil {
            await recorder.snapshotUpdateCount == 1
        }
        #expect(context.clock.pendingSleepCount == 0)
    }

    @Test("同日实际边界状态真实变化后可开始新的收敛序列")
    func changedStateAtSameActualBoundaryStartsNewRetrySequence() async throws {
        let now = Date(timeIntervalSince1970: 24_750)
        let boundary = now.addingTimeInterval(10)
        let context = makeClientWithControllableAutomaticRefreshClock(now: now)
        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 14402,
                        state: .subscribed,
                        boundary: boundary,
                        kind: .expiration,
                        gracePeriodExpirationDate: boundary
                    ),
                ],
                verificationFailures: []
            )
        )
        await context.client.start()
        defer { Task { await context.client.stop() } }
        try await waitUntil {
            context.clock.pendingDeadlines == [boundary]
        }
        let baselineRequestCount = await context.gateway.subscriptionStatusRequestCount

        for completedAttemptCount in 1...5 {
            context.clock.advanceToNextSleep()
            try await waitUntil {
                let expectedPendingCount = completedAttemptCount < 5 ? 1 : 0
                return await context.gateway.subscriptionStatusRequestCount
                    == baselineRequestCount + completedAttemptCount
                    && context.clock.pendingSleepCount == expectedPendingCount
            }
        }

        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 14402,
                        state: .inGracePeriod,
                        boundary: boundary,
                        kind: .expiration,
                        gracePeriodExpirationDate: boundary
                    ),
                ],
                verificationFailures: []
            )
        )
        _ = try await context.client.refresh()

        try await waitUntil {
            context.clock.pendingDeadlines
                == [boundary.addingTimeInterval(24)]
        }
    }

    @Test("启动时已过去的陈旧边界直接进入有限收敛重试")
    func retriesStalePastBoundaryAtStartup() async throws {
        let now = Date(timeIntervalSince1970: 25_000)
        let pastBoundary = now.addingTimeInterval(-1)
        let context = makeClientWithControllableAutomaticRefreshClock(now: now)
        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 1441,
                        boundary: pastBoundary,
                        kind: .expiration
                    ),
                ],
                verificationFailures: []
            )
        )
        await context.client.start()
        defer { Task { await context.client.stop() } }
        try await waitUntil {
            context.clock.pendingSleepCount == 1
        }
        context.clock.keepOnlyPendingDeadlinesInHistory()
        let baselineRequestCount = await context.gateway.subscriptionStatusRequestCount
        let expectedDeadlines = [
            now.addingTimeInterval(1),
            now.addingTimeInterval(3),
            now.addingTimeInterval(8),
            now.addingTimeInterval(23),
        ]

        for completedAttemptCount in 1...4 {
            context.clock.advanceToNextSleep()
            try await waitUntil {
                let requestCount = await context.gateway.subscriptionStatusRequestCount
                let expectedPendingCount = completedAttemptCount < 4 ? 1 : 0
                return requestCount == baselineRequestCount + completedAttemptCount
                    && context.clock.pendingSleepCount == expectedPendingCount
            }
        }

        #expect(context.clock.scheduledDeadlines == expectedDeadlines)
        #expect(context.clock.pendingSleepCount == 0)
    }

    @Test("一个订阅耗尽收敛重试后仍安排其他订阅的未来边界")
    func exhaustedStaleSubscriptionDoesNotBlockAnotherFutureBoundary() async throws {
        let now = Date(timeIntervalSince1970: 26_000)
        let staleBoundary = now.addingTimeInterval(-1)
        let futureBoundary = now.addingTimeInterval(60)
        let context = makeClientWithControllableAutomaticRefreshClock(now: now)
        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 14411,
                        groupID: "stale-group",
                        boundary: staleBoundary,
                        kind: .expiration
                    ),
                    .fixture(
                        transactionID: 14412,
                        groupID: "future-group",
                        boundary: futureBoundary,
                        kind: .expiration
                    ),
                ],
                verificationFailures: []
            )
        )
        await context.client.start()
        defer { Task { await context.client.stop() } }
        try await waitUntil {
            context.clock.pendingDeadlines == [now.addingTimeInterval(1)]
        }
        let baselineRequestCount = await context.gateway.subscriptionStatusRequestCount

        for completedRetryCount in 1...4 {
            context.clock.advanceToNextSleep()
            try await waitUntil {
                let requestCount = await context.gateway.subscriptionStatusRequestCount
                if completedRetryCount < 4 {
                    return requestCount == baselineRequestCount + completedRetryCount
                        && context.clock.pendingSleepCount == 1
                }
                return requestCount == baselineRequestCount + completedRetryCount
            }
        }

        try await waitUntil {
            context.clock.pendingDeadlines == [futureBoundary]
        }
    }

    @Test("无关订阅变化和重签名不会重置目标边界退避")
    func unrelatedSubscriptionChangesDoNotResetBoundaryRetry() async throws {
        let now = Date(timeIntervalSince1970: 27_000)
        let boundary = now.addingTimeInterval(10)
        let context = makeClientWithControllableAutomaticRefreshClock(now: now)
        let initialTarget = PaymentSubscriptionStatus.fixture(
            transactionID: 1442,
            boundary: boundary,
            kind: .expiration
        )
        let unrelated = PaymentSubscriptionStatus.fixture(
            transactionID: 1443,
            state: .expired
        )
        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [initialTarget, unrelated],
                verificationFailures: []
            )
        )
        await context.client.start()
        defer { Task { await context.client.stop() } }
        try await waitUntil {
            context.clock.pendingDeadlines == [boundary]
        }

        let resignedTarget = PaymentSubscriptionStatus.fixture(
            transactionID: 1442,
            signedDate: Date(timeIntervalSince1970: 2),
            transactionJWS: "resigned-transaction-jws",
            renewalJWS: "resigned-renewal-jws",
            boundary: boundary,
            kind: .expiration
        )
        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(transactionID: 1443, state: .revoked),
                    resignedTarget,
                ],
                verificationFailures: []
            )
        )
        context.clock.advance(to: boundary)
        try await waitUntil {
            context.clock.pendingDeadlines
                == [boundary.addingTimeInterval(1)]
        }

        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [resignedTarget, unrelated],
                verificationFailures: []
            )
        )
        context.clock.advanceToNextSleep()

        try await waitUntil {
            context.clock.pendingSleepCount == 1
        }
        #expect(
            context.clock.pendingDeadlines
                == [boundary.addingTimeInterval(3)]
        )
    }

    @Test("目标订阅的非目标日期变化不会无限重置收敛退避")
    func nonTargetBoundaryChangesDoNotRestartTargetRetrySequence() async throws {
        let now = Date(timeIntervalSince1970: 27_500)
        let boundary = now.addingTimeInterval(10)
        let context = makeClientWithControllableAutomaticRefreshClock(now: now)
        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 14431,
                        boundary: boundary,
                        kind: .expiration,
                        renewalDate: boundary.addingTimeInterval(100)
                    ),
                ],
                verificationFailures: []
            )
        )
        await context.client.start()
        defer { Task { await context.client.stop() } }
        try await waitUntil {
            context.clock.pendingDeadlines == [boundary]
        }
        context.clock.keepOnlyPendingDeadlinesInHistory()
        let baselineRequestCount = await context.gateway.subscriptionStatusRequestCount
        let expectedRetryDeadlines = [
            boundary,
            boundary.addingTimeInterval(1),
            boundary.addingTimeInterval(3),
            boundary.addingTimeInterval(8),
            boundary.addingTimeInterval(23),
        ]

        for completedAttemptCount in 1...5 {
            let changedRenewalDate = boundary.addingTimeInterval(
                100 + TimeInterval(completedAttemptCount)
            )
            await context.gateway.setSubscriptionResult(
                StoreSubscriptionStatusResult(
                    statuses: [
                        .fixture(
                            transactionID: 14431,
                            signedDate: Date(
                                timeIntervalSince1970:
                                    TimeInterval(completedAttemptCount + 1)
                            ),
                            transactionJWS: "resigned-transaction-\(completedAttemptCount)",
                            renewalJWS: "resigned-renewal-\(completedAttemptCount)",
                            boundary: boundary,
                            kind: .expiration,
                            renewalDate: changedRenewalDate
                        ),
                    ],
                    verificationFailures: []
                )
            )
            context.clock.advanceToNextSleep()

            try await waitUntil {
                let requestCount = await context.gateway.subscriptionStatusRequestCount
                let expectedDeadline = completedAttemptCount < 5
                    ? expectedRetryDeadlines[completedAttemptCount]
                    : changedRenewalDate
                return requestCount == baselineRequestCount + completedAttemptCount
                    && context.clock.pendingDeadlines == [expectedDeadline]
            }
        }

        #expect(context.clock.scheduledDeadlines == expectedRetryDeadlines + [
            boundary.addingTimeInterval(105),
        ])
    }

    @Test("相同陈旧快照再次提交时保留有限重试进度")
    func identicalStaleSnapshotPreservesBoundaryRetryProgress() async throws {
        let now = Date(timeIntervalSince1970: 28_000)
        let pastBoundary = now.addingTimeInterval(-1)
        let context = makeClientWithControllableAutomaticRefreshClock(now: now)
        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 1444,
                        boundary: pastBoundary,
                        kind: .expiration
                    ),
                ],
                verificationFailures: []
            )
        )
        await context.client.start()
        defer { Task { await context.client.stop() } }
        try await waitUntil {
            context.clock.pendingDeadlines == [now.addingTimeInterval(1)]
        }

        context.clock.advanceToNextSleep()
        try await waitUntil {
            context.clock.pendingDeadlines == [now.addingTimeInterval(3)]
        }

        _ = try await context.client.refresh()

        try await waitUntil {
            context.clock.pendingSleepCount == 1
        }
        #expect(
            context.clock.pendingDeadlines
                == [now.addingTimeInterval(3)]
        )
    }

    @Test("新快照替换旧时间边界任务")
    func newerSnapshotReplacesStaleBoundaryTask() async throws {
        let now = Date(timeIntervalSince1970: 30_000)
        let oldBoundary = now.addingTimeInterval(30)
        let newBoundary = now.addingTimeInterval(60)
        let context = makeClientWithControllableAutomaticRefreshClock(now: now)
        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 145,
                        boundary: oldBoundary,
                        kind: .expiration
                    ),
                ],
                verificationFailures: []
            )
        )
        await context.client.start()
        defer { Task { await context.client.stop() } }
        try await waitUntil {
            context.clock.pendingDeadlines == [oldBoundary]
        }

        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 145,
                        boundary: newBoundary,
                        kind: .expiration
                    ),
                ],
                verificationFailures: []
            )
        )
        _ = try await context.client.refresh()
        try await waitUntil {
            context.clock.pendingDeadlines == [newBoundary]
        }
        let baselineRequestCount = await context.gateway.subscriptionStatusRequestCount

        context.clock.advance(to: oldBoundary)
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(
            await context.gateway.subscriptionStatusRequestCount
                == baselineRequestCount
        )

        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(transactionID: 145, state: .expired),
                ],
                verificationFailures: []
            )
        )
        context.clock.advance(to: newBoundary)
        try await waitUntil {
            await context.client.snapshot().subscriptionStatuses.first?.state == .expired
        }
        #expect(
            await context.gateway.subscriptionStatusRequestCount
                == baselineRequestCount + 1
        )
    }

    @Test("停止后旧生命周期边界不提交状态且不重连长期流")
    func stopCancelsStateBoundaryWithoutReconnect() async throws {
        let now = Date(timeIntervalSince1970: 40_000)
        let boundary = now.addingTimeInterval(10)
        let context = makeClientWithControllableAutomaticRefreshClock(now: now)
        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 146,
                        boundary: boundary,
                        kind: .gracePeriod
                    ),
                ],
                verificationFailures: []
            )
        )
        await context.client.start()
        try await waitUntil {
            context.clock.pendingDeadlines == [boundary]
        }
        let baselineSnapshot = await context.client.snapshot()
        let baselineStatusRequestCount =
            await context.gateway.subscriptionStatusRequestCount
        let baselineUpdateStreamCount = await context.gateway.updateStreamRequestCount
        let baselineStorefrontStreamCount =
            await context.gateway.storefrontStreamRequestCount

        await context.client.stop()
        try await waitUntil {
            context.clock.pendingSleepCount == 0
        }
        await context.gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(transactionID: 146, state: .expired),
                ],
                verificationFailures: []
            )
        )
        context.clock.advance(to: boundary)
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(await context.client.snapshot() == baselineSnapshot)
        #expect(
            await context.gateway.subscriptionStatusRequestCount
                == baselineStatusRequestCount
        )
        #expect(
            await context.gateway.updateStreamRequestCount
                == baselineUpdateStreamCount
        )
        #expect(
            await context.gateway.storefrontStreamRequestCount
                == baselineStorefrontStreamCount
        )
    }

    @Test("未来边界睡眠不会保活支付客户端")
    func stateBoundarySleepDoesNotRetainClient() async throws {
        let now = Date(timeIntervalSince1970: 45_000)
        let boundary = now.addingTimeInterval(3_600)
        let gateway = FakePaymentStoreGateway()
        let clock = ControllableAutomaticRefreshClock(now: now)
        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [
                    .fixture(
                        transactionID: 147,
                        boundary: boundary,
                        kind: .expiration
                    ),
                ],
                verificationFailures: []
            )
        )
        var client: PaymentClient? = PaymentClient(
            configuration: PaymentConfiguration(productIDs: ["premium"]),
            processor: RecordingTransactionProcessor(),
            gateway: gateway,
            logger: DisabledPaymentLogHandler(),
            automaticRefreshClock: clock.paymentClock
        )
        let weakClient = WeakPaymentClientReference(client)
        await client?.start()
        try await waitUntil {
            clock.pendingDeadlines == [boundary]
        }

        client = nil

        try await waitUntil {
            weakClient.isReleased
        }
        try await waitUntil {
            clock.pendingSleepCount == 0
        }
    }

    @Test("完整自动刷新在商品提交点发现生命周期已停止后不提交快照")
    func stoppedAutomaticFullRefreshDoesNotCommitProducts() async throws {
        let context = makeClientWithControllableApplicationActivity()
        await context.gateway.setProducts([
            StoreProduct(value: .fixture(id: "premium"))
        ])
        await context.client.start()
        let baselineSnapshot = await context.client.snapshot()
        await context.gateway.setProducts([])
        await context.gateway.blockNextCanMakePaymentsRequest()

        let refreshTask = Task {
            try await context.client.refresh(requiredLifecycleGeneration: 1)
        }
        await context.gateway.waitUntilBlockedCanMakePaymentsRequestStarts()
        await context.client.stop()
        await context.gateway.resumeBlockedCanMakePaymentsRequest()

        do {
            _ = try await refreshTask.value
            Issue.record("过期的完整自动刷新应该被取消")
        } catch is CancellationError {
            // 生命周期变化应在商品快照提交前取消完整刷新。
        }
        #expect(await context.client.snapshot() == baselineSnapshot)
    }

    @Test("完整自动刷新在最终持久存储读取期间停止后不提交最终状态")
    func stoppedAutomaticFullRefreshDoesNotCommitFinalState() async throws {
        let pendingStore = ControllableReferencesPendingTransactionStore()
        let context = makeClientWithControllableApplicationActivity(
            pendingStore: pendingStore
        )
        await context.client.start()
        let baselineReadCount = await pendingStore.referenceReadCount
        let baselineSnapshot = await context.client.snapshot()
        let updatedEntitlement = PaymentTransaction.fixture(id: 142)
        await context.gateway.setEntitlements([
            .verified(StoreTransaction(value: updatedEntitlement))
        ])

        let recorder = PaymentEventRecorder()
        let events = await context.client.events()
        let recordingTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }
        defer { recordingTask.cancel() }

        await pendingStore.blockReferenceRead(
            requestNumber: baselineReadCount + 2
        )
        let refreshTask = Task {
            try await context.client.refresh(requiredLifecycleGeneration: 1)
        }
        await pendingStore.waitUntilBlockedReadStarts()
        try await waitUntil {
            await recorder.snapshotUpdateCount == 1
        }
        let eventCountBeforeStop = await recorder.snapshotUpdateCount

        await context.client.stop()
        await pendingStore.resumeBlockedRead()
        do {
            _ = try await refreshTask.value
            Issue.record("过期的完整自动刷新最终状态应该被取消")
        } catch is CancellationError {
            // 商品快照已在停止前提交；最终状态必须在停止后被生命周期检查拒绝。
        }
        try await Task.sleep(for: .milliseconds(100))

        #expect(await context.client.snapshot() == baselineSnapshot)
        #expect(await recorder.snapshotUpdateCount == eventCountBeforeStop)
    }

    @Test("自动状态刷新等待 unfinished 时停止不得补 finish")
    func stoppingAutomaticStateRefreshPreventsDeliveredFinish() async throws {
        let gateway = FakePaymentStoreGateway()
        let activity = ControllableApplicationActivity()
        let pendingStore = InMemoryPendingTransactionStore()
        let processor = RecordingTransactionProcessor()
        let client = PaymentClient(
            configuration: PaymentConfiguration(productIDs: ["premium"]),
            processor: processor,
            gateway: gateway,
            pendingStore: pendingStore,
            logger: DisabledPaymentLogHandler(),
            applicationActivitySource: activity.source()
        )
        await client.start()
        let baselineSnapshot = await client.snapshot()

        let transaction = PaymentTransaction.fixture(id: 143)
        let deliveredReference = PendingTransactionReference(transaction: transaction)
            .markingDelivered()
        await pendingStore.markDelivered(
            PendingTransactionReference(transaction: transaction)
        )
        await gateway.setUnfinished([
            .verified(StoreTransaction(value: transaction, canFinish: true))
        ])
        await gateway.blockNextUnfinishedRequest()

        await client.requestAutomaticRefresh(
            .state,
            reason: "test-stop-before-finish",
            generation: 1
        )
        await gateway.waitUntilBlockedUnfinishedRequestStarts()
        await client.stop()
        await gateway.resumeBlockedUnfinishedRequest()
        try await Task.sleep(for: .milliseconds(100))

        #expect(await gateway.finishedTransactionIDs.isEmpty)
        #expect(await processor.transactions.isEmpty)
        #expect(await pendingStore.references() == [deliveredReference])
        #expect(await client.snapshot() == baselineSnapshot)
    }

    @Test("全部长期监听开启时释放客户端会终止所有底层流")
    func releasingClientTerminatesAllLongLivedStreams() async throws {
        let gateway = FakePaymentStoreGateway()
        let activity = ControllableApplicationActivity()
        var client: PaymentClient? = PaymentClient(
            configuration: PaymentConfiguration(productIDs: ["premium"]),
            processor: RecordingTransactionProcessor(),
            gateway: gateway,
            logger: DisabledPaymentLogHandler(),
            applicationActivitySource: activity.source()
        )
        let weakClient = WeakPaymentClientReference(client)
        let messages = await client?.storeMessages()

        await client?.start()
        #expect(await activity.streamRequestCount == 1)
        #expect(await gateway.updateStreamRequestCount == 1)
        #expect(await gateway.purchaseIntentStreamRequestCount == 1)
        #expect(await gateway.subscriptionStatusUpdateRequestCount() == 1)
        #expect(await gateway.storefrontRequestCount() == 1)
        try await waitUntil {
            await gateway.storeMessageStreamRequestCount == 1
        }
        client = nil

        try await waitUntil {
            weakClient.isReleased
        }
        try await waitUntil {
            await activity.streamTerminationCount == 1
        }
        try await waitUntil {
            await gateway.allLongLivedStreamsTerminated
        }
        _ = messages
    }

    @Test("停止客户端会取消启动阶段正在执行的 outbox 重放")
    func stopCancelsInitialOutboxReplay() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 110)
        await gateway.setUnfinished([
            .verified(StoreTransaction(value: transaction, canFinish: true))
        ])
        let processor = CancellationObservingTransactionProcessor()
        let pendingStore = InMemoryPendingTransactionStore()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        let startup = Task { await client.start() }
        await processor.waitUntilStarted()
        await client.stop()
        try await waitUntil(timeout: .milliseconds(500)) {
            await processor.wasCancelled
        }
        if await !processor.wasCancelled {
            // 旧实现不会由 stop() 取消启动调用；只在失败路径清理测试任务。
            startup.cancel()
        }
        await startup.value

        #expect(await processor.wasCancelled)
        #expect(await gateway.finishedTransactionIDs.isEmpty)
        #expect(await pendingStore.references().allSatisfy { !$0.isDelivered })
    }

    @Test("停止客户端后启动重放不得补 finish 已交付记录")
    func stopPreventsFinishOfPreviouslyDeliveredStartupRecord() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 119)
        await gateway.setUnfinished([
            .verified(StoreTransaction(value: transaction, canFinish: true))
        ])
        let reference = PendingTransactionReference(transaction: transaction)
            .markingDelivered()
        let pendingStore = BlockingReferencesPendingTransactionStore(
            initialReferences: [reference]
        )
        let client = makeClient(
            gateway: gateway,
            pendingStore: pendingStore
        )

        let startup = Task { await client.start() }
        await pendingStore.waitUntilReadStarts()
        await client.stop()
        await pendingStore.resumeRead()
        await startup.value

        #expect(await gateway.finishedTransactionIDs.isEmpty)
        #expect(await pendingStore.storedReferences() == [reference])
    }

    @Test("恢复同步取消会透传 CancellationError")
    func restoreCancellationIsPreserved() async {
        let gateway = FakePaymentStoreGateway()
        await gateway.cancelNextSync()
        let client = makeClient(gateway: gateway)

        do {
            _ = try await client.restorePurchases()
            Issue.record("取消的恢复请求不应返回成功")
        } catch is CancellationError {
            // CancellationError 是此用例的预期结果。
        } catch {
            Issue.record("取消不应被包装成 PaymentError")
        }
    }

    @Test("停止后重新启动不会保留过期交易监听")
    func stopThenRestartDiscardsStaleListener() async throws {
        let gateway = FakePaymentStoreGateway()
        await gateway.blockNextTransactionUpdateRequest()
        let processor = RecordingTransactionProcessor()
        let client = makeClient(gateway: gateway, processor: processor)

        let staleStart = Task { await client.start() }
        try await waitUntil { await gateway.updateStreamRequestCount == 1 }
        await client.stop()

        let currentStart = Task { await client.start() }
        try await waitUntil { await gateway.updateStreamRequestCount == 2 }
        await gateway.resumeBlockedTransactionUpdateRequest()
        await staleStart.value
        await currentStart.value

        let staleTransaction = PaymentTransaction.fixture(id: 120)
        let currentTransaction = PaymentTransaction.fixture(id: 121)
        await gateway.sendUpdate(
            .verified(StoreTransaction(value: staleTransaction)),
            requestNumber: 1
        )
        await gateway.sendUpdate(
            .verified(StoreTransaction(value: currentTransaction)),
            requestNumber: 2
        )
        try await waitUntil { await processor.transactions == [currentTransaction] }

        // 给过期流留出调度时间；它不应再进入交易处理器。
        try await Task.sleep(for: .milliseconds(50))
        #expect(await processor.transactions == [currentTransaction])
        await client.stop()
    }

    @Test("未完成交易处理成功后立即从快照移除")
    func processedUnfinishedTransactionLeavesSnapshot() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 104)
        await gateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await gateway.setUnfinished([.verified(StoreTransaction(value: transaction))])
        let client = makeClient(gateway: gateway)
        _ = try await client.refresh()
        #expect(await client.snapshot().pendingTransactions.map(\.transaction) == [transaction])

        await client.retryUnfinishedTransactions()

        #expect(await client.snapshot().pendingTransactions.isEmpty)
    }

    @Test("finish 后立即移除已提交快照中的 pending")
    func finishedTransactionImmediatelyLeavesCommittedPendingSnapshot() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(
            id: 150,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "group"
        )
        let pendingStore = InMemoryPendingTransactionStore()
        await gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: transaction.productID,
                    type: .autoRenewableSubscription,
                    subscriptionGroupID: "group"
                )
            )
        ])
        await gateway.setUnfinished([
            .verified(StoreTransaction(value: transaction, canFinish: true))
        ])
        await pendingStore.insert(
            PendingTransactionReference(transaction: transaction)
        )
        let client = makeClient(
            gateway: gateway,
            pendingStore: pendingStore
        )
        _ = try await client.refresh()
        #expect(await client.snapshot().pendingTransactions.map(\.transaction) == [transaction])

        await gateway.setUnfinished([])
        await gateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: transaction, canFinish: true)))
        )
        await gateway.blockNextProductLoadRequest()
        let productLoadCount = await gateway.productLoadRequestCount
        let purchase = Task {
            try await client.purchase(productID: transaction.productID)
        }
        try await waitUntil {
            let finishedTransactionIDs = await gateway.finishedTransactionIDs
            let currentProductLoadCount = await gateway.productLoadRequestCount
            return finishedTransactionIDs == [transaction.id]
                && currentProductLoadCount == productLoadCount + 1
        }

        #expect(await client.snapshot().pendingTransactions.isEmpty)
        #expect(await pendingStore.references().isEmpty)

        await gateway.resumeBlockedProductLoadRequest()
        _ = try await purchase.value
    }

    @Test("较旧句柄 finish 后立即移除快照中的较新等价重签名")
    func olderFinishedHandleImmediatelyRemovesNewerEquivalentSnapshot() async throws {
        let gateway = FakePaymentStoreGateway()
        let finished = PaymentTransaction.fixture(
            id: 153,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "group",
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "finished-jws"
        )
        let snapshotResign = PaymentTransaction.fixture(
            id: 153,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "group",
            signedDate: Date(timeIntervalSince1970: 20),
            jwsRepresentation: "snapshot-resign-jws"
        )
        #expect(finished.deliveryState == snapshotResign.deliveryState)

        await gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: finished.productID,
                    type: .autoRenewableSubscription,
                    subscriptionGroupID: "group"
                )
            )
        ])
        await gateway.setUnfinished([
            .verified(StoreTransaction(value: snapshotResign, canFinish: true))
        ])
        let client = makeClient(gateway: gateway)
        _ = try await client.refresh()
        #expect(
            await client.snapshot().pendingTransactions.map(\.transaction)
                == [snapshotResign]
        )

        // StoreKit 的更新流可能给出同一业务状态的较旧签名句柄；finish 该句柄时，
        // 已提交快照中的较新等价重签名也必须立即离开，不能等下一次完整刷新。
        await gateway.setUnfinished([])
        await gateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: finished, canFinish: true)))
        )
        await gateway.blockNextProductLoadRequest()
        let productLoadCount = await gateway.productLoadRequestCount
        let purchase = Task {
            try await client.purchase(productID: finished.productID)
        }
        try await waitUntil {
            let finishedTransactionIDs = await gateway.finishedTransactionIDs
            let currentProductLoadCount = await gateway.productLoadRequestCount
            return finishedTransactionIDs == [finished.id]
                && currentProductLoadCount == productLoadCount + 1
        }

        #expect(await client.snapshot().pendingTransactions.isEmpty)

        await gateway.resumeBlockedProductLoadRequest()
        _ = try await purchase.value
    }

    @Test("较旧句柄 finish 不会移除快照中的较新业务状态")
    func olderFinishedHandlePreservesNewerChangedSnapshot() async throws {
        let gateway = FakePaymentStoreGateway()
        let finished = PaymentTransaction.fixture(
            id: 154,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "group",
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "older-state-jws"
        )
        let revoked = PaymentTransaction.fixture(
            id: 154,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "group",
            signedDate: Date(timeIntervalSince1970: 20),
            revocationDate: Date(timeIntervalSince1970: 15),
            jwsRepresentation: "newer-revocation-jws"
        )
        #expect(finished.deliveryState != revoked.deliveryState)

        await gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: finished.productID,
                    type: .autoRenewableSubscription,
                    subscriptionGroupID: "group"
                )
            )
        ])
        await gateway.setUnfinished([
            .verified(StoreTransaction(value: revoked, canFinish: true))
        ])
        let client = makeClient(gateway: gateway)
        _ = try await client.refresh()

        await gateway.setUnfinished([])
        await gateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: finished, canFinish: true)))
        )
        await gateway.blockNextProductLoadRequest()
        let productLoadCount = await gateway.productLoadRequestCount
        let purchase = Task {
            try await client.purchase(productID: finished.productID)
        }
        try await waitUntil {
            let finishedTransactionIDs = await gateway.finishedTransactionIDs
            let currentProductLoadCount = await gateway.productLoadRequestCount
            return finishedTransactionIDs == [finished.id]
                && currentProductLoadCount == productLoadCount + 1
        }

        #expect(
            await client.snapshot().pendingTransactions.map(\.transaction)
                == [revoked]
        )

        await gateway.resumeBlockedProductLoadRequest()
        _ = try await purchase.value
    }

    @Test("并发刷新不得在 finish 后重新提交旧 outbox fallback")
    func staleOutboxFallbackDoesNotReappearAfterFinish() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(
            id: 151,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "group"
        )
        let pendingStore = ControllableReferencesPendingTransactionStore()
        await gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: transaction.productID,
                    type: .autoRenewableSubscription,
                    subscriptionGroupID: "group"
                )
            )
        ])
        let client = makeClient(
            gateway: gateway,
            pendingStore: pendingStore
        )
        _ = try await client.reloadProducts()
        await pendingStore.insert(
            PendingTransactionReference(transaction: transaction)
        )

        await pendingStore.blockReferenceRead(requestNumber: 2)
        let staleRefresh = Task {
            try await client.refresh()
        }
        await pendingStore.waitUntilBlockedReadStarts()

        await gateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: transaction, canFinish: true)))
        )
        await gateway.blockNextProductLoadRequest()
        let productLoadCount = await gateway.productLoadRequestCount
        let purchase = Task {
            try await client.purchase(productID: transaction.productID)
        }
        try await waitUntil {
            let finishedTransactionIDs = await gateway.finishedTransactionIDs
            let currentProductLoadCount = await gateway.productLoadRequestCount
            return finishedTransactionIDs == [transaction.id]
                && currentProductLoadCount == productLoadCount + 1
        }
        #expect(await pendingStore.references().isEmpty)

        await pendingStore.resumeBlockedRead()
        let snapshot = try await staleRefresh.value

        #expect(snapshot.pendingTransactions.isEmpty)
        #expect(await client.snapshot().pendingTransactions.isEmpty)

        await gateway.resumeBlockedProductLoadRequest()
        _ = try await purchase.value
    }

    @Test("finish 清理重入时较新等价重签名不得残留 pending")
    func resignedTransactionDuringFinishCleanupDoesNotRemainPending() async throws {
        let gateway = FakePaymentStoreGateway()
        let original = PaymentTransaction.fixture(
            id: 152,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "group",
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "original-jws"
        )
        let resigned = PaymentTransaction.fixture(
            id: 152,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: "group",
            signedDate: Date(timeIntervalSince1970: 20),
            jwsRepresentation: "resigned-jws"
        )
        #expect(original.deliveryState == resigned.deliveryState)

        let pendingStore = PostRemovalBlockingPendingTransactionStore()
        await gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: original.productID,
                    type: .autoRenewableSubscription,
                    subscriptionGroupID: "group"
                )
            )
        ])
        await gateway.setUnfinished([
            .verified(StoreTransaction(value: resigned, canFinish: true))
        ])
        await gateway.enqueuePurchaseResult(
            .success(.verified(StoreTransaction(value: original, canFinish: true)))
        )
        let client = makeClient(
            gateway: gateway,
            pendingStore: pendingStore
        )
        _ = try await client.reloadProducts()

        await pendingStore.blockAfterNextRemoval()
        let purchase = Task {
            try await client.purchase(productID: original.productID)
        }
        await pendingStore.waitUntilRemovalStarts()

        let concurrentSnapshot = try await client.refresh()
        #expect(concurrentSnapshot.pendingTransactions.isEmpty)

        await pendingStore.resumeRemoval()
        _ = try await purchase.value
        #expect(await client.snapshot().pendingTransactions.isEmpty)
        #expect(await pendingStore.references().isEmpty)
    }

    @Test("外部交易更新通过同一可靠交付路径处理")
    func externalTransactionUpdateIsProcessed() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 106)
        let processor = RecordingTransactionProcessor()
        let client = makeClient(gateway: gateway, processor: processor)
        await client.start()

        await gateway.sendUpdate(.verified(StoreTransaction(value: transaction)))
        try await waitUntil {
            await processor.transactions == [transaction]
        }

        #expect(await gateway.finishedTransactionIDs == [transaction.id])
        await client.stop()
    }

    @Test("慢订单不会阻塞后续不同订单")
    func slowTransactionDoesNotHeadOfLineBlockUpdates() async throws {
        let gateway = FakePaymentStoreGateway()
        let slowTransaction = PaymentTransaction.fixture(id: 130)
        let fastTransaction = PaymentTransaction.fixture(id: 131, jwsRepresentation: "fast-jws")
        let processor = SelectiveBlockingTransactionProcessor(blockedTransactionID: slowTransaction.id)
        let client = makeClient(gateway: gateway, processor: processor)
        await client.start()

        await gateway.sendUpdate(.verified(StoreTransaction(value: slowTransaction)))
        await processor.waitUntilBlockedTransactionStarts()
        await gateway.sendUpdate(.verified(StoreTransaction(value: fastTransaction)))

        try await waitUntil {
            await gateway.finishedTransactionIDs.contains(fastTransaction.id)
        }
        #expect(await processor.transactions.contains(fastTransaction))
        #expect(!(await gateway.finishedTransactionIDs.contains(slowTransaction.id)))

        await processor.resumeBlockedTransaction()
        try await waitUntil {
            await gateway.finishedTransactionIDs.contains(slowTransaction.id)
        }
        await client.stop()
    }

    @Test("交易监听异常结束后会自动重建")
    func transactionListenerRestartsAfterUnexpectedEnd() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 132)
        let processor = RecordingTransactionProcessor()
        let client = makeClient(gateway: gateway, processor: processor)
        await client.start()

        await gateway.finishUpdateStream(requestNumber: 1)
        try await waitUntil { await gateway.updateStreamRequestCount == 2 }
        await gateway.sendUpdate(
            .verified(StoreTransaction(value: transaction)),
            requestNumber: 2
        )
        try await waitUntil { await processor.transactions == [transaction] }

        #expect(await gateway.finishedTransactionIDs == [transaction.id])
        await client.stop()
    }

    @Test("交易监听异常结束会自动重放被取消的在途 outbox")
    func unexpectedListenerEndReplaysCancelledInFlightOutbox() async throws {
        let gateway = FakePaymentStoreGateway()
        let processor = CancelOnceThenSucceedTransactionProcessor()
        let pendingStore = InMemoryPendingTransactionStore()
        let logger = RecordingPaymentLogHandler()
        let transaction = PaymentTransaction.fixture(id: 137)
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore,
            logger: logger
        )

        await client.start()
        await gateway.sendUpdate(.verified(StoreTransaction(value: transaction)))
        await processor.waitUntilFirstAttemptStarts()

        // 模拟 StoreKit 更新流在处理器执行期间异常结束。监听批次会取消在途任务，
        // 但已经持久化的 outbox 必须由下一次监听建立后的重放流程接管。
        await gateway.finishUpdateStream(requestNumber: 1)

        try await waitUntil { await gateway.updateStreamRequestCount == 2 }
        try await waitUntil { await processor.attemptCount == 2 }
        try await waitUntil {
            let snapshot = await client.snapshot()
            return snapshot.pendingTransactions.count == 1
                && snapshot.pendingTransactions.first?.state == .deliveredAwaitingFinish
        }

        #expect(await processor.firstAttemptWasCancelled)
        #expect(await processor.successfulTransactions == [transaction])

        let references = await pendingStore.references()
        #expect(references.count == 1)
        #expect(references.first?.isDelivered == true)
        #expect(await gateway.finishedTransactionIDs.isEmpty)

        let snapshot = await client.snapshot()
        #expect(snapshot.pendingTransactions.count == 1)
        #expect(snapshot.pendingTransactions.first?.state == .deliveredAwaitingFinish)
        #expect(logger.entries.contains {
            $0.message == "交易更新监听已重建并完成 outbox 重放"
                && $0.metadata["replayAttemptedCount"] == "1"
                && $0.metadata["replayFailureCount"] == "0"
                && $0.metadata["remainingBacklogCount"] == "1"
        })

        await client.stop()
    }

    @Test("退避期间停止不会建立新监听或重放 outbox")
    func stopDuringReconnectBackoffDoesNotReconnect() async throws {
        let gateway = FakePaymentStoreGateway()
        let processor = RecordingTransactionProcessor()
        let logger = RecordingPaymentLogHandler()
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            logger: logger
        )

        await client.start()
        await gateway.finishUpdateStream(requestNumber: 1)
        try await waitUntil {
            logger.entries.contains {
                $0.message == "交易更新监听意外结束，准备重新建立"
            }
        }

        await client.stop()
        try await Task.sleep(for: .milliseconds(350))

        #expect(await gateway.updateStreamRequestCount == 1)
        #expect(await processor.transactions.isEmpty)
        #expect(await gateway.finishedTransactionIDs.isEmpty)
    }

    @Test("重放期间停止不会提交旧生命周期的交易状态")
    func stopDuringReconnectReplayDoesNotCommitDelivery() async throws {
        let gateway = FakePaymentStoreGateway()
        let processor = CancellationObservingTransactionProcessor()
        let pendingStore = InMemoryPendingTransactionStore()
        let transaction = PaymentTransaction.fixture(id: 138)
        let client = makeClient(
            gateway: gateway,
            processor: processor,
            pendingStore: pendingStore
        )

        await client.start()
        await pendingStore.insert(PendingTransactionReference(transaction: transaction))
        await gateway.finishUpdateStream(requestNumber: 1)

        // 新监听先建立，再从 outbox 重放；处理器挂起后停止客户端，旧生命周期不能提交状态。
        await processor.waitUntilStarted()
        await client.stop()

        try await waitUntil { await processor.wasCancelled }
        let references = await pendingStore.references()
        #expect(references.count == 1)
        #expect(references.first?.isDelivered == false)
        #expect(await gateway.finishedTransactionIDs.isEmpty)
        #expect(await gateway.updateStreamRequestCount == 2)
    }

    @Test("停止客户端会取消在途交易处理")
    func stopCancelsInFlightTransactionProcessing() async throws {
        let gateway = FakePaymentStoreGateway()
        let processor = CancellationObservingTransactionProcessor()
        let client = makeClient(gateway: gateway, processor: processor)
        await client.start()

        await gateway.sendUpdate(
            .verified(StoreTransaction(value: .fixture(id: 133)))
        )
        await processor.waitUntilStarted()
        await client.stop()

        try await waitUntil { await processor.wasCancelled }
        #expect(await gateway.finishedTransactionIDs.isEmpty)
    }

    @Test("刷新只汇总已验证权益并保留订阅状态")
    func refreshMapsVerifiedState() async throws {
        let gateway = FakePaymentStoreGateway()
        let entitlement = PaymentTransaction.fixture(id: 107)
        let unfinished = PaymentTransaction.fixture(id: 108)
        let subscription = PaymentSubscriptionStatus.fixture(transactionID: 109)
        await gateway.setEntitlements([
            .verified(StoreTransaction(value: entitlement)),
            .unverified(transactionID: 999, message: "invalid"),
        ])
        await gateway.setUnfinished([.verified(StoreTransaction(value: unfinished))])
        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [subscription],
                verificationFailures: []
            )
        )
        let client = makeClient(gateway: gateway)

        let snapshot = try await client.refresh()

        #expect(snapshot.currentEntitlements == [entitlement])
        #expect(snapshot.pendingTransactions == [
            PaymentPendingTransaction(transaction: unfinished, state: .awaitingDelivery)
        ])
        #expect(snapshot.subscriptionStatuses == [subscription])
    }

    @Test("较早的刷新结果不会覆盖较新的状态")
    func staleRefreshDoesNotOverwriteNewerSnapshot() async throws {
        let gateway = FakePaymentStoreGateway()
        let oldTransaction = PaymentTransaction.fixture(id: 112)
        let newTransaction = PaymentTransaction.fixture(id: 113)
        await gateway.setProducts([StoreProduct(value: .fixture(id: "premium"))])
        await gateway.setEntitlements([.verified(StoreTransaction(value: oldTransaction))])
        await gateway.blockNextEntitlementRequest()
        let client = makeClient(gateway: gateway)

        let staleRefresh = Task { try await client.refresh() }
        try await waitUntil { await gateway.entitlementRequestCount == 1 }

        await gateway.setEntitlements([.verified(StoreTransaction(value: newTransaction))])
        let newestSnapshot = try await client.refresh()
        await gateway.resumeBlockedEntitlementRequest()
        _ = try await staleRefresh.value

        #expect(newestSnapshot.currentEntitlements == [newTransaction])
        #expect(await client.snapshot().currentEntitlements == [newTransaction])
    }

    @Test("刷新取消时不提交部分状态")
    func cancelledRefreshDoesNotCommitPartialState() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 115)
        await gateway.setProducts([StoreProduct(value: .fixture(id: "premium"))])
        await gateway.setEntitlements([.verified(StoreTransaction(value: transaction))])
        await gateway.blockNextEntitlementRequest()
        let client = makeClient(gateway: gateway)

        let refresh = Task { try await client.refresh() }
        try await waitUntil { await gateway.entitlementRequestCount == 1 }
        refresh.cancel()
        await gateway.resumeBlockedEntitlementRequest()

        do {
            _ = try await refresh.value
            Issue.record("取消的刷新请求不应提交状态")
        } catch is CancellationError {
            // CancellationError 是此用例的预期结果。
        }
        #expect(await client.snapshot().currentEntitlements.isEmpty)
    }

    @Test("较晚刷新失败时仍提交较早的完整状态")
    func newerFailedRefreshDoesNotDiscardEarlierSuccess() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 114)
        await gateway.setProducts([StoreProduct(value: .fixture(id: "premium"))])
        await gateway.setEntitlements([.verified(StoreTransaction(value: transaction))])
        await gateway.blockNextEntitlementRequest()
        let client = makeClient(gateway: gateway)

        let earlierRefresh = Task { try await client.refresh() }
        try await waitUntil { await gateway.entitlementRequestCount == 1 }
        await gateway.failProductLoad(requestNumber: 2)
        do {
            _ = try await client.refresh()
            Issue.record("较晚刷新应在商品加载阶段失败")
        } catch let error as PaymentError {
            #expect(error.code == .storeKitFailed)
        }

        await gateway.resumeBlockedEntitlementRequest()
        let snapshot = try await earlierRefresh.value

        #expect(snapshot.currentEntitlements == [transaction])
        #expect(await client.snapshot().currentEntitlements == [transaction])
    }

    @Test("商品版本变化时轻量刷新会重新查询订阅组")
    func lightweightRefreshRetriesAfterProductVersionChanges() async throws {
        let gateway = FakePaymentStoreGateway()
        let status = PaymentSubscriptionStatus.fixture(transactionID: 116)
        await gateway.setProducts([
            StoreProduct(
                value: .fixture(
                    id: "monthly",
                    type: .autoRenewableSubscription,
                    subscriptionGroupID: "group"
                )
            )
        ])
        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(statuses: [status], verificationFailures: [])
        )
        await gateway.filterSubscriptionResultsByRequestedGroups()
        await gateway.blockNextProductLoadRequest()
        let client = makeClient(productIDs: ["monthly"], gateway: gateway)

        let fullRefresh = Task { try await client.refresh() }
        try await waitUntil { await gateway.productLoadRequestCount == 1 }

        await gateway.blockNextSubscriptionStatusRequest()
        let lightweightRefresh = Task { await client.retryUnfinishedTransactions() }
        try await waitUntil { await gateway.subscriptionStatusRequestCount == 1 }

        await gateway.resumeBlockedProductLoadRequest()
        #expect(try await fullRefresh.value.subscriptionStatuses == [status])
        await gateway.resumeBlockedSubscriptionStatusRequest()
        _ = await lightweightRefresh.value

        #expect(await gateway.subscriptionStatusRequestCount == 3)
        #expect(await client.snapshot().subscriptionStatuses == [status])
    }

    @Test("轻量状态刷新也报告订阅验签失败")
    func stateRefreshReportsSubscriptionVerificationFailure() async {
        let gateway = FakePaymentStoreGateway()
        await gateway.setSubscriptionResult(
            StoreSubscriptionStatusResult(
                statuses: [],
                verificationFailures: [
                    StoreVerificationFailure(transactionID: 654_321, message: "invalid renewal")
                ]
            )
        )
        let logger = RecordingPaymentLogHandler()
        let client = makeClient(gateway: gateway, logger: logger)

        await client.retryUnfinishedTransactions()

        #expect(logger.entries.contains {
            $0.category == "verification" && $0.metadata["transactionSuffix"] == "654321"
        })
    }

    @Test("购买限制和无效数量在调用 StoreKit 前失败")
    func purchasePreconditionsAreValidated() async throws {
        let gateway = FakePaymentStoreGateway()
        await gateway.setProducts([StoreProduct(value: .fixture(id: "premium"))])
        let client = makeClient(gateway: gateway)
        _ = try await client.reloadProducts()

        do {
            _ = try await client.purchase(
                productID: "premium",
                options: PurchaseOptions(quantity: 0)
            )
            Issue.record("数量为零时不应调用 StoreKit")
        } catch let error as PaymentError {
            #expect(error.code == .invalidQuantity)
        }

        await gateway.setCanMakePayments(false)
        do {
            _ = try await client.purchase(productID: "premium")
            Issue.record("购买受限时不应调用 StoreKit")
        } catch let error as PaymentError {
            #expect(error.code == .purchasesNotAllowed)
        }
        #expect(await gateway.purchaseCallCount == 0)
    }

    @Test("有效的服务端首购资格声明精确透传到 StoreKit 网关")
    func introductoryOfferEligibilityIsForwarded() async throws {
        let gateway = FakePaymentStoreGateway()
        let product = PaymentProduct.fixture(
            id: "monthly",
            type: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group",
            introductoryOffer: .fixture(paymentMode: .freeTrial)
        )
        await gateway.setProducts([StoreProduct(value: product)])
        await gateway.enqueuePurchaseResult(.pending)
        let client = makeClient(productIDs: [product.id], gateway: gateway)
        _ = try await client.reloadProducts()
        let eligibility = PaymentIntroductoryOfferEligibility(
            compactJWS: "header.payload.signature"
        )
        let options = PurchaseOptions(
            offer: .introductory(eligibility: eligibility)
        )

        #expect(try await client.purchase(productID: product.id, options: options) == .pending)
        #expect(await gateway.purchaseOptions == [options])
    }

    @Test("无效首购资格声明和不支持的商品在调用 StoreKit 前失败")
    func invalidIntroductoryOfferEligibilityIsRejected() async throws {
        let gateway = FakePaymentStoreGateway()
        let monthly = PaymentProduct.fixture(
            id: "monthly",
            type: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group",
            introductoryOffer: .fixture(paymentMode: .freeTrial)
        )
        let annualWithoutOffer = PaymentProduct.fixture(
            id: "annual",
            type: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group"
        )
        let lifetime = PaymentProduct.fixture(id: "lifetime")
        await gateway.setProducts([
            StoreProduct(value: monthly),
            StoreProduct(value: annualWithoutOffer),
            StoreProduct(value: lifetime),
        ])
        let client = makeClient(
            productIDs: [monthly.id, annualWithoutOffer.id, lifetime.id],
            gateway: gateway
        )
        _ = try await client.reloadProducts()

        for invalidJWS in ["", "header.payload", "header..signature", ".payload.signature"] {
            do {
                _ = try await client.purchase(
                    productID: monthly.id,
                    options: PurchaseOptions(
                        offer: .introductory(
                            eligibility: .init(compactJWS: invalidJWS)
                        )
                    )
                )
                Issue.record("格式错误的资格 JWS 不应进入 StoreKit")
            } catch let error as PaymentError {
                #expect(error.code == .invalidPurchaseOptions)
                #expect(!error.message.contains(invalidJWS))
            }
        }

        let eligibility = PaymentIntroductoryOfferEligibility(
            compactJWS: "header.payload.signature"
        )
        for productID in [annualWithoutOffer.id, lifetime.id] {
            do {
                _ = try await client.purchase(
                    productID: productID,
                    options: PurchaseOptions(
                        offer: .introductory(eligibility: eligibility)
                    )
                )
                Issue.record("没有首购优惠的商品不应接受资格声明")
            } catch let error as PaymentError {
                #expect(error.code == .invalidPurchaseOptions)
                #expect(!error.message.contains("header.payload.signature"))
            }
        }
        #expect(await gateway.purchaseCallCount == 0)
    }

    @Test("有效促销授权精确透传且错误 JWS 或 offer ID 在购买前拒绝")
    func promotionalOfferAuthorizationIsValidatedAndForwarded() async throws {
        let gateway = FakePaymentStoreGateway()
        let promotionalOffer = PaymentSubscriptionOffer(
            id: "retention",
            type: .promotional,
            price: 0.99,
            displayPrice: "$0.99",
            period: .init(unit: .month, value: 1),
            periodCount: 2,
            paymentMode: .payAsYouGo
        )
        let product = PaymentProduct.fixture(
            id: "monthly",
            type: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group",
            promotionalOffers: [promotionalOffer]
        )
        await gateway.setProducts([StoreProduct(value: product)])
        await gateway.enqueuePurchaseResult(.pending)
        let client = makeClient(productIDs: [product.id], gateway: gateway)
        _ = try await client.reloadProducts()

        let options = PurchaseOptions(
            offer: .promotional(
                authorization: .init(
                    offerID: "retention",
                    compactJWS: "header.payload.signature"
                )
            )
        )
        #expect(try await client.purchase(productID: product.id, options: options) == .pending)
        #expect(await gateway.purchaseOptions == [options])

        for (offerID, jws, expectedCode) in [
            ("retention", "header..signature", PaymentErrorCode.offerAuthorizationInvalid),
            ("missing", "header.payload.signature", PaymentErrorCode.offerNotFound),
        ] {
            do {
                _ = try await client.purchase(
                    productID: product.id,
                    options: PurchaseOptions(
                        offer: .promotional(
                            authorization: .init(offerID: offerID, compactJWS: jws)
                        )
                    )
                )
                Issue.record("无效促销授权不应进入 StoreKit")
            } catch let error as PaymentError {
                #expect(error.code == expectedCode)
                #expect(!error.message.contains(jws))
            }
        }
        #expect(await gateway.purchaseCallCount == 1)
    }

    @Test("回归优惠必须同时存在于商品配置和 Apple 资格列表")
    func winBackOfferRequiresCurrentEligibility() async throws {
        let gateway = FakePaymentStoreGateway()
        let winBackOffer = PaymentSubscriptionOffer(
            id: "return-free-month",
            type: .winBack,
            price: 0,
            displayPrice: "$0.00",
            period: .init(unit: .month, value: 1),
            periodCount: 1,
            paymentMode: .freeTrial
        )
        let product = PaymentProduct.fixture(
            id: "monthly",
            type: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group",
            winBackOffers: [winBackOffer]
        )
        let eligibleStatus = PaymentSubscriptionStatus.fixture(
            transactionID: 97,
            groupID: "subscription-group",
            productID: product.id,
            eligibleWinBackOfferIDs: ["return-free-month"]
        )
        await gateway.setProducts([StoreProduct(value: product)])
        await gateway.setSubscriptionResult(
            .init(statuses: [eligibleStatus], verificationFailures: [])
        )
        await gateway.enqueuePurchaseResult(.pending)
        let client = makeClient(productIDs: [product.id], gateway: gateway)
        _ = try await client.refresh()

        let eligibleOptions = PurchaseOptions(
            offer: .winBack(offerID: "return-free-month")
        )
        #expect(
            try await client.purchase(productID: product.id, options: eligibleOptions)
                == .pending
        )

        do {
            _ = try await client.purchase(
                productID: product.id,
                options: .init(offer: .winBack(offerID: "not-eligible"))
            )
            Issue.record("不在资格列表中的回归优惠不应进入 StoreKit")
        } catch let error as PaymentError {
            #expect(error.code == .offerNotFound)
        }
        #expect(await gateway.purchaseCallCount == 1)
    }

    @Test("月付承诺计划必须存在于目标商品定价条款")
    func billingPlanMustExistForProduct() async throws {
        let gateway = FakePaymentStoreGateway()
        let commitment = PaymentSubscriptionCommitment(
            price: 180,
            displayPrice: "¥180.00",
            period: .init(unit: .year, value: 1)
        )
        let terms = PaymentSubscriptionPricingTerms(
            billingPlan: .monthlyCommitment,
            billingPrice: 15,
            billingDisplayPrice: "¥15.00",
            billingPeriod: .init(unit: .month, value: 1),
            commitment: commitment,
            offers: []
        )
        let product = PaymentProduct.fixture(
            id: "annual",
            type: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group",
            pricingTerms: [terms]
        )
        await gateway.setProducts([StoreProduct(value: product)])
        await gateway.enqueuePurchaseResult(.pending)
        let client = makeClient(productIDs: [product.id], gateway: gateway)
        _ = try await client.reloadProducts()

        let options = PurchaseOptions(billingPlan: .monthlyCommitment)
        #expect(try await client.purchase(productID: product.id, options: options) == .pending)

        do {
            _ = try await client.purchase(
                productID: product.id,
                options: .init(billingPlan: .unknown("future-plan"))
            )
            Issue.record("未知账单计划不应进入 StoreKit")
        } catch let error as PaymentError {
            #expect(error.code == .billingPlanUnavailable)
        }
        #expect(await gateway.purchaseCallCount == 1)
    }

    @Test("所选账单计划必须包含同一类型的优惠")
    func billingPlanOfferMatchingIncludesOfferType() async throws {
        let gateway = FakePaymentStoreGateway()
        let introductory = PaymentSubscriptionOffer(
            id: nil,
            type: .introductory,
            price: 0,
            displayPrice: "$0.00",
            period: .init(unit: .week, value: 1),
            periodCount: 1,
            paymentMode: .freeTrial
        )
        let unrelatedNilIDOffer = PaymentSubscriptionOffer(
            id: nil,
            type: .promotional,
            price: 0.99,
            displayPrice: "$0.99",
            period: .init(unit: .month, value: 1),
            periodCount: 1,
            paymentMode: .payAsYouGo
        )
        let terms = PaymentSubscriptionPricingTerms(
            billingPlan: .monthlyCommitment,
            billingPrice: 15,
            billingDisplayPrice: "¥15.00",
            billingPeriod: .init(unit: .month, value: 1),
            commitment: .init(
                price: 180,
                displayPrice: "¥180.00",
                period: .init(unit: .year, value: 1)
            ),
            offers: [unrelatedNilIDOffer]
        )
        let product = PaymentProduct.fixture(
            id: "annual",
            type: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group",
            introductoryOffer: introductory,
            pricingTerms: [terms],
            isEligibleForIntroductoryOffer: true
        )
        await gateway.setProducts([StoreProduct(value: product)])
        let client = makeClient(productIDs: [product.id], gateway: gateway)
        _ = try await client.reloadProducts()

        do {
            _ = try await client.purchase(
                productID: product.id,
                options: .init(
                    billingPlan: .monthlyCommitment,
                    offer: .introductory(eligibility: nil)
                )
            )
            Issue.record("同 ID 但不同类型的优惠不应通过账单计划校验")
        } catch let error as PaymentError {
            #expect(error.code == .offerNotFound)
        }
        #expect(await gateway.purchaseCallCount == 0)
    }

    @Test("外部回归购买意图可延迟接收并沿用同一可靠购买路径")
    func externalWinBackPurchaseIntentCanBeCompletedLater() async throws {
        let gateway = FakePaymentStoreGateway()
        let offer = PaymentSubscriptionOffer(
            id: "return-free-month",
            type: .winBack,
            price: 0,
            displayPrice: "$0.00",
            period: .init(unit: .month, value: 1),
            periodCount: 1,
            paymentMode: .freeTrial
        )
        let product = PaymentProduct.fixture(
            id: "monthly",
            type: .autoRenewableSubscription,
            subscriptionGroupID: "subscription-group",
            winBackOffers: [offer]
        )
        let intent = PaymentPurchaseIntent(productID: product.id, offer: offer)
        await gateway.setProducts([StoreProduct(value: product)])
        await gateway.enqueuePurchaseResult(.pending)
        let client = makeClient(productIDs: [product.id], gateway: gateway)
        let intents = await client.purchaseIntents()
        let received = Task { await intents.first(where: { _ in true }) }
        defer { received.cancel() }

        await client.start()
        await gateway.sendPurchaseIntent(
            StorePurchaseIntent(
                value: intent,
                product: StoreProduct(value: product)
            )
        )
        let receivedIntent = try #require(await received.value)

        #expect(receivedIntent == intent)
        #expect(try await client.purchase(intent: intent) == .pending)
        #expect(
            await gateway.purchaseOptions
                == [.init(offer: .winBack(offerID: "return-free-month"))]
        )
        #expect(await gateway.purchaseIntentPurchaseCallCount == 1)
        #expect(await gateway.purchaseCallCount == 0)
        await client.stop()
    }

    @Test("不支持购买意图的系统不会建立或重连监听")
    func unsupportedPurchaseIntentsDoNotStartListener() async throws {
        let gateway = FakePaymentStoreGateway()
        await gateway.setPurchaseIntentsSupported(false)
        let client = makeClient(gateway: gateway)
        let intents = await client.purchaseIntents()
        let completion = Task {
            var receivedCount = 0
            for await _ in intents {
                receivedCount += 1
            }
            return receivedCount
        }

        await client.start()

        #expect(await gateway.purchaseIntentStreamRequestCount == 0)
        #expect(await completion.value == 0)
        await client.stop()
    }

    @Test("购买意图监听异常结束后重连且停止后不再建立新监听")
    func purchaseIntentListenerReconnectsUntilStopped() async throws {
        let gateway = FakePaymentStoreGateway()
        let product = PaymentProduct.fixture(id: "promoted-product")
        let intent = PaymentPurchaseIntent(productID: product.id)
        let client = makeClient(productIDs: [product.id], gateway: gateway)
        let intents = await client.purchaseIntents()
        let received = Task { await intents.first(where: { _ in true }) }
        defer { received.cancel() }

        await client.start()
        try await waitUntil {
            await gateway.purchaseIntentStreamRequestCount == 1
        }
        await gateway.finishPurchaseIntentStream(requestNumber: 1)
        try await waitUntil(timeout: .seconds(1)) {
            await gateway.purchaseIntentStreamRequestCount == 2
        }
        await gateway.sendPurchaseIntent(
            StorePurchaseIntent(
                value: intent,
                product: StoreProduct(value: product)
            ),
            requestNumber: 2
        )
        #expect(await received.value == intent)

        await client.stop()
        await gateway.finishPurchaseIntentStream(requestNumber: 2)
        try await Task.sleep(for: .milliseconds(350))
        #expect(await gateway.purchaseIntentStreamRequestCount == 2)
    }

    @Test("放弃购买意图会从客户端移除且不能再次购买")
    func discardedPurchaseIntentCannotBePurchasedOrReplayed() async throws {
        let gateway = FakePaymentStoreGateway()
        let product = PaymentProduct.fixture(id: "discarded-product")
        let intent = PaymentPurchaseIntent(productID: product.id)
        let client = makeClient(productIDs: [product.id], gateway: gateway)
        let intents = await client.purchaseIntents()
        let received = Task { await intents.first(where: { _ in true }) }

        await client.start()
        await gateway.sendPurchaseIntent(
            StorePurchaseIntent(
                value: intent,
                product: StoreProduct(value: product)
            )
        )
        #expect(await received.value == intent)

        #expect(await client.discardPurchaseIntent(intent))
        #expect(!(await client.discardPurchaseIntent(intent)))

        do {
            _ = try await client.purchase(intent: intent)
            Issue.record("已经放弃的购买意图不应继续购买")
        } catch let error as PaymentError {
            #expect(error.code == .invalidPurchaseOptions)
        }
        #expect(await gateway.purchaseIntentPurchaseCallCount == 0)

        let replay = await client.purchaseIntents()
        let replayed = Task { await replay.first(where: { _ in true }) }
        try await Task.sleep(for: .milliseconds(50))
        replayed.cancel()
        #expect(await replayed.value == nil)
        await client.stop()
    }

    @Test("停止客户端会清理旧生命周期的购买意图")
    func stopClearsPendingPurchaseIntents() async throws {
        let gateway = FakePaymentStoreGateway()
        let product = PaymentProduct.fixture(id: "stale-product")
        let intent = PaymentPurchaseIntent(productID: product.id)
        let client = makeClient(productIDs: [product.id], gateway: gateway)
        let intents = await client.purchaseIntents()
        let received = Task { await intents.first(where: { _ in true }) }

        await client.start()
        await gateway.sendPurchaseIntent(
            StorePurchaseIntent(
                value: intent,
                product: StoreProduct(value: product)
            )
        )
        #expect(await received.value == intent)
        await client.stop()

        do {
            _ = try await client.purchase(intent: intent)
            Issue.record("旧生命周期的购买意图不应继续购买")
        } catch let error as PaymentError {
            #expect(error.code == .invalidPurchaseOptions)
        }
    }

    @Test("系统消息仅在调用方明确订阅后才由框架消费")
    func storeMessagesAreOptIn() async throws {
        let gateway = FakePaymentStoreGateway()
        let client = makeClient(gateway: gateway)

        await client.start()
        #expect(await gateway.storeMessageStreamRequestCount == 0)

        let messages = await client.storeMessages()
        let received = Task { await messages.first(where: { _ in true }) }
        try await waitUntil { await gateway.storeMessageStreamRequestCount == 1 }
        let message = PaymentStoreMessage(reason: .winBack)
        await gateway.sendStoreMessage(message)

        #expect(await received.value == message)
        await client.stop()
    }

    @Test("不支持系统消息的平台不会建立监听")
    func unsupportedStoreMessagesDoNotStartListener() async throws {
        let gateway = FakePaymentStoreGateway()
        await gateway.setStoreMessagesSupported(false)
        let client = makeClient(gateway: gateway)
        let messages = await client.storeMessages()
        let completion = Task {
            var receivedCount = 0
            for await _ in messages {
                receivedCount += 1
            }
            return receivedCount
        }

        await client.start()

        #expect(await gateway.storeMessageStreamRequestCount == 0)
        #expect(await completion.value == 0)
        await client.stop()
    }

    @Test("系统消息监听异常结束后重连且停止后不再建立新监听")
    func storeMessageListenerReconnectsUntilStopped() async throws {
        let gateway = FakePaymentStoreGateway()
        let client = makeClient(gateway: gateway)
        let messages = await client.storeMessages()
        let received = Task { await messages.first(where: { _ in true }) }

        await client.start()
        try await waitUntil {
            await gateway.storeMessageStreamRequestCount == 1
        }
        await gateway.finishStoreMessageStream(requestNumber: 1)
        try await waitUntil(timeout: .seconds(1)) {
            await gateway.storeMessageStreamRequestCount == 2
        }
        let message = PaymentStoreMessage(reason: .winBack)
        await gateway.sendStoreMessage(message, requestNumber: 2)
        #expect(await received.value == message)

        await client.stop()
        await gateway.finishStoreMessageStream(requestNumber: 2)
        try await Task.sleep(for: .milliseconds(350))
        #expect(await gateway.storeMessageStreamRequestCount == 2)
    }

    @Test("交易日志不会输出 JWS、账户令牌或完整交易 ID")
    func transactionLogsRedactSensitiveValues() async throws {
        let gateway = FakePaymentStoreGateway()
        let token = UUID()
        let transaction = PaymentTransaction.fixture(
            id: 123_456_789,
            jwsRepresentation: "secret-jws-payload",
            appAccountToken: token
        )
        await gateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: transaction))))
        let logger = RecordingPaymentLogHandler()
        let client = makeClient(gateway: gateway, logger: logger)
        _ = try await client.reloadProducts()

        _ = try await client.purchase(productID: transaction.productID)

        let rendered = logger.entries.map {
            "\($0.message) \($0.metadata.values.joined(separator: " "))"
        }.joined(separator: "\n")
        #expect(!rendered.contains(transaction.jwsRepresentation))
        #expect(!rendered.contains(token.uuidString))
        #expect(!rendered.contains(String(transaction.id)))
        #expect(rendered.contains("456789"))
        let completionEntry = logger.entries.first { $0.metadata["stage"] == "finished" }
        #expect(completionEntry?.metadata["durationMilliseconds"] != nil)
        #expect(completionEntry?.metadata["backlogCount"] == "1")
    }

    @Test("处理器底层错误不会进入公共错误或日志")
    func processorErrorDetailsAreSanitized() async throws {
        let gateway = FakePaymentStoreGateway()
        let transaction = PaymentTransaction.fixture(id: 123_456_790)
        await gateway.setProducts([StoreProduct(value: .fixture(id: transaction.productID))])
        await gateway.enqueuePurchaseResult(.success(.verified(StoreTransaction(value: transaction))))
        let logger = RecordingPaymentLogHandler()
        let client = makeClient(
            gateway: gateway,
            processor: SensitiveFailingTransactionProcessor(),
            logger: logger
        )
        _ = try await client.reloadProducts()

        do {
            _ = try await client.purchase(productID: transaction.productID)
            Issue.record("处理器失败时购买不应完成")
        } catch let error as PaymentError {
            #expect(error.code == .processingFailed)
            #expect(!error.message.contains("secret"))
        }

        let rendered = logger.entries.map {
            "\($0.message) \($0.metadata.values.joined(separator: " "))"
        }.joined(separator: "\n")
        #expect(!rendered.contains("secret-jws-and-account-token"))
    }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("等待异步状态超时")
}

private func makeClient(
    productIDs: [String] = ["premium"],
    gateway: FakePaymentStoreGateway,
    processor: any TransactionProcessor = RecordingTransactionProcessor(),
    pendingStore: any PendingTransactionStore = InMemoryPendingTransactionStore(),
    logger: any PaymentLogHandler = DisabledPaymentLogHandler()
) -> PaymentClient {
    PaymentClient(
        configuration: PaymentConfiguration(productIDs: productIDs),
        processor: processor,
        gateway: gateway,
        pendingStore: pendingStore,
        logger: logger
    )
}

private func makeClientWithControllableApplicationActivity() -> (
    client: PaymentClient,
    gateway: FakePaymentStoreGateway,
    activity: ControllableApplicationActivity
) {
    makeClientWithControllableApplicationActivity(
        pendingStore: InMemoryPendingTransactionStore()
    )
}

private func makeClientWithControllableApplicationActivity(
    pendingStore: any PendingTransactionStore
) -> (
    client: PaymentClient,
    gateway: FakePaymentStoreGateway,
    activity: ControllableApplicationActivity
) {
    let gateway = FakePaymentStoreGateway()
    let activity = ControllableApplicationActivity()
    let client = PaymentClient(
        configuration: PaymentConfiguration(productIDs: ["premium"]),
        processor: RecordingTransactionProcessor(),
        gateway: gateway,
        pendingStore: pendingStore,
        logger: DisabledPaymentLogHandler(),
        applicationActivitySource: activity.source()
    )
    return (client, gateway, activity)
}

private func makeClientWithControllableStorefrontUpdates() -> (
    client: PaymentClient,
    gateway: FakePaymentStoreGateway
) {
    let gateway = FakePaymentStoreGateway()
    let client = makeClient(
        productIDs: ["premium", "bonus"],
        gateway: gateway
    )
    return (client, gateway)
}

private func makeClientWithControllableAutomaticRefreshClock(
    now: Date
) -> (
    client: PaymentClient,
    gateway: FakePaymentStoreGateway,
    clock: ControllableAutomaticRefreshClock
) {
    let gateway = FakePaymentStoreGateway()
    let clock = ControllableAutomaticRefreshClock(now: now)
    let client = PaymentClient(
        configuration: PaymentConfiguration(productIDs: ["premium"]),
        processor: RecordingTransactionProcessor(),
        gateway: gateway,
        logger: DisabledPaymentLogHandler(),
        automaticRefreshClock: clock.paymentClock
    )
    return (client, gateway, clock)
}

enum SubscriptionBoundaryKind: CaseIterable, Sendable, Equatable {
    case expiration
    case renewal
    case gracePeriod
    case commitment
}

enum OverlappingSubscriptionBoundaryKinds: CaseIterable, Sendable, Equatable {
    case expirationAndRenewal
    case expirationRenewalAndCommitment
}

private final class ControllableAutomaticRefreshClock: @unchecked Sendable {
    private struct Waiter {
        let deadline: Date
        let isRetry: Bool
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentDate: Date
    private var waiters: [UUID: Waiter] = [:]
    private var deadlineHistory: [Date] = []
    private var boundaryDeadlineHistory: [Date] = []
    private var retryDeadlineHistory: [Date] = []

    init(now: Date) {
        currentDate = now
    }

    var paymentClock: PaymentAutomaticRefreshClock {
        let boundarySleep: @Sendable (Date) async throws -> Void = {
            [weak self] deadline in
            guard let self else { throw CancellationError() }
            try await self.sleep(until: deadline, isRetry: false)
        }
        let retrySleep: @Sendable (Date) async throws -> Void = {
            [weak self] deadline in
            guard let self else { throw CancellationError() }
            try await self.sleep(until: deadline, isRetry: true)
        }
        return PaymentAutomaticRefreshClock(
            now: { [weak self] in
                self?.now ?? Date.distantPast
            },
            sleep: boundarySleep,
            retrySleep: retrySleep
        )
    }

    var now: Date {
        lock.withLock { currentDate }
    }

    var pendingSleepCount: Int {
        lock.withLock { waiters.count }
    }

    var pendingDeadlines: [Date] {
        lock.withLock {
            waiters.values.map(\.deadline).sorted()
        }
    }

    var scheduledDeadlines: [Date] {
        lock.withLock { deadlineHistory }
    }

    var boundarySleepDeadlines: [Date] {
        lock.withLock { boundaryDeadlineHistory }
    }

    var retrySleepDeadlines: [Date] {
        lock.withLock { retryDeadlineHistory }
    }

    func advance(to date: Date) {
        let continuations = lock.withLock {
            if date > currentDate {
                currentDate = date
            }
            let dueIDs = waiters.compactMap { id, waiter in
                waiter.deadline <= currentDate ? id : nil
            }
            return dueIDs.compactMap { id in
                waiters.removeValue(forKey: id)?.continuation
            }
        }
        continuations.forEach { $0.resume() }
    }

    func advanceToNextSleep() {
        guard let deadline = pendingDeadlines.first else { return }
        advance(to: deadline)
    }

    func keepOnlyPendingDeadlinesInHistory() {
        lock.withLock {
            let pendingWaiters = waiters.values.sorted {
                $0.deadline < $1.deadline
            }
            deadlineHistory = pendingWaiters.map(\.deadline)
            boundaryDeadlineHistory = pendingWaiters
                .filter { !$0.isRetry }
                .map(\.deadline)
            retryDeadlineHistory = pendingWaiters
                .filter(\.isRetry)
                .map(\.deadline)
        }
    }

    private func sleep(until deadline: Date, isRetry: Bool) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let isAlreadyCancelled = lock.withLock {
                    if Task.isCancelled {
                        return true
                    }
                    waiters[id] = Waiter(
                        deadline: deadline,
                        isRetry: isRetry,
                        continuation: continuation
                    )
                    deadlineHistory.append(deadline)
                    if isRetry {
                        retryDeadlineHistory.append(deadline)
                    } else {
                        boundaryDeadlineHistory.append(deadline)
                    }
                    return false
                }
                if isAlreadyCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancelSleep(id: id)
        }
    }

    private func cancelSleep(id: UUID) {
        let continuation = lock.withLock {
            waiters.removeValue(forKey: id)?.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private actor ControllableApplicationActivity {
    private var continuations: [
        Int: AsyncStream<Void>.Continuation
    ] = [:]
    private(set) var streamRequestCount = 0
    private(set) var streamTerminationCount = 0

    nonisolated func source() -> PaymentApplicationActivitySource {
        PaymentApplicationActivitySource { [weak self] in
            guard let self else {
                return AsyncStream<Void> { $0.finish() }
            }
            return await self.events()
        }
    }

    func yieldActivation(
        count: Int = 1,
        requestNumber: Int? = nil
    ) {
        let number = requestNumber ?? streamRequestCount
        guard let continuation = continuations[number] else { return }
        for _ in 0..<count {
            continuation.yield()
        }
    }

    private func events() -> AsyncStream<Void> {
        streamRequestCount += 1
        let requestNumber = streamRequestCount
        let stream = AsyncStream<Void>.makeStream()
        stream.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.streamDidTerminate(requestNumber: requestNumber)
            }
        }
        continuations[requestNumber] = stream.continuation
        return stream.stream
    }

    private func streamDidTerminate(requestNumber: Int) {
        continuations[requestNumber] = nil
        streamTerminationCount += 1
    }
}

private actor PaymentEventRecorder {
    private(set) var events: [PaymentEvent] = []

    var snapshotUpdateCount: Int {
        events.reduce(into: 0) { count, event in
            if case .snapshotUpdated = event {
                count += 1
            }
        }
    }

    func record(_ event: PaymentEvent) {
        events.append(event)
    }
}

private final class WeakPaymentClientReference: @unchecked Sendable {
    weak var value: PaymentClient?

    init(_ value: PaymentClient?) {
        self.value = value
    }

    var isReleased: Bool {
        value == nil
    }
}

private actor RecordingTransactionProcessor: TransactionProcessor {
    private(set) var transactions: [PaymentTransaction] = []
    private var failuresRemaining: Int

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
    }

    func process(_ transaction: PaymentTransaction) async throws {
        transactions.append(transaction)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw TestFailure.processing
        }
    }
}

private struct SensitiveFailingTransactionProcessor: TransactionProcessor {
    func process(_ transaction: PaymentTransaction) async throws {
        throw SensitiveTestFailure(message: "secret-jws-and-account-token")
    }
}

private actor OrderingTransactionProcessor: TransactionProcessor {
    private let gateway: FakePaymentStoreGateway
    private(set) var transactions: [PaymentTransaction] = []
    private(set) var observedUnfinishedTransaction = false

    init(gateway: FakePaymentStoreGateway) {
        self.gateway = gateway
    }

    func process(_ transaction: PaymentTransaction) async throws {
        transactions.append(transaction)
        // 处理器执行时 fake 网关还没有收到 finish，直接验证可靠交付顺序。
        observedUnfinishedTransaction = await gateway.finishedTransactionIDs.isEmpty
    }
}

private actor BlockingTransactionProcessor: TransactionProcessor {
    private(set) var processCount = 0
    private var processContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []

    func process(_ transaction: PaymentTransaction) async throws {
        processCount += 1
        let continuations = startedContinuations
        startedContinuations.removeAll()
        continuations.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            processContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard processCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func resume() {
        processContinuation?.resume()
        processContinuation = nil
    }
}

private actor SelectiveBlockingTransactionProcessor: TransactionProcessor {
    private let blockedTransactionID: UInt64
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var transactions: [PaymentTransaction] = []

    init(blockedTransactionID: UInt64) {
        self.blockedTransactionID = blockedTransactionID
    }

    func process(_ transaction: PaymentTransaction) async throws {
        transactions.append(transaction)
        guard transaction.id == blockedTransactionID else { return }
        let continuations = startedContinuations
        startedContinuations.removeAll()
        continuations.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
        }
    }

    func waitUntilBlockedTransactionStarts() async {
        guard !transactions.contains(where: { $0.id == blockedTransactionID }) else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func resumeBlockedTransaction() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private actor CancellationObservingTransactionProcessor: TransactionProcessor {
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var hasStarted = false
    private(set) var wasCancelled = false

    func process(_ transaction: PaymentTransaction) async throws {
        hasStarted = true
        let continuations = startedContinuations
        startedContinuations.removeAll()
        continuations.forEach { $0.resume() }
        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }
}

private actor CancelOnceThenSucceedTransactionProcessor: TransactionProcessor {
    private var firstAttemptStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var attemptCount = 0
    private(set) var firstAttemptWasCancelled = false
    private(set) var successfulTransactions: [PaymentTransaction] = []

    func process(_ transaction: PaymentTransaction) async throws {
        attemptCount += 1

        if attemptCount == 1 {
            let continuations = firstAttemptStartedContinuations
            firstAttemptStartedContinuations.removeAll()
            continuations.forEach { $0.resume() }

            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                firstAttemptWasCancelled = true
                throw CancellationError()
            }
        }

        successfulTransactions.append(transaction)
    }

    func waitUntilFirstAttemptStarts() async {
        guard attemptCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstAttemptStartedContinuations.append(continuation)
        }
    }
}

private actor FaultInjectingPendingTransactionStore: PendingTransactionStore {
    private var values = Set<PendingTransactionReference>()
    private let failInsert: Bool
    private let failMarkDelivered: Bool
    private var removeFailuresRemaining: Int
    private(set) var markDeliveredCount = 0

    init(
        failInsert: Bool = false,
        failMarkDelivered: Bool = false,
        removeFailuresRemaining: Int = 0
    ) {
        self.failInsert = failInsert
        self.failMarkDelivered = failMarkDelivered
        self.removeFailuresRemaining = removeFailuresRemaining
    }

    func references() -> Set<PendingTransactionReference> {
        values
    }

    func insert(_ reference: PendingTransactionReference) throws {
        if failInsert {
            throw SensitiveTestFailure(message: "secret-jws-and-account-token")
        }
        values.insert(reference)
    }

    func markDelivered(_ reference: PendingTransactionReference) throws {
        markDeliveredCount += 1
        if failMarkDelivered {
            throw SensitiveTestFailure(message: "secret-jws-and-account-token")
        }
        guard let existing = values.first(where: { $0 == reference }) else { return }
        values.remove(existing)
        values.insert(existing.markingDelivered())
    }

    func remove(_ reference: PendingTransactionReference) throws {
        if removeFailuresRemaining > 0 {
            removeFailuresRemaining -= 1
            throw SensitiveTestFailure(message: "secret-jws-and-account-token")
        }
        values.remove(reference)
    }

    func removeCurrentAndOlder(_ reference: PendingTransactionReference) throws {
        if removeFailuresRemaining > 0 {
            removeFailuresRemaining -= 1
            throw SensitiveTestFailure(message: "secret-jws-and-account-token")
        }
        values = values.filter {
            $0.transactionID != reference.transactionID
                || ($0 != reference && $0.signedDate >= reference.signedDate)
        }
    }
}

private actor ControllableReferencesPendingTransactionStore: PendingTransactionStore {
    private var values = Set<PendingTransactionReference>()
    private var blockedRequestNumber: Int?
    private var blockedReadContinuation: CheckedContinuation<Void, Never>?
    private var blockedReadStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var referenceReadCount = 0

    func references() async -> Set<PendingTransactionReference> {
        referenceReadCount += 1
        if blockedRequestNumber == referenceReadCount {
            blockedRequestNumber = nil
            let continuations = blockedReadStartedContinuations
            blockedReadStartedContinuations.removeAll()
            continuations.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                blockedReadContinuation = continuation
            }
        }
        return values
    }

    func insert(_ reference: PendingTransactionReference) {
        values.insert(reference)
    }

    func markDelivered(_ reference: PendingTransactionReference) {
        values.remove(reference)
        values.insert(reference.markingDelivered())
    }

    func remove(_ reference: PendingTransactionReference) {
        values.remove(reference)
    }

    func removeCurrentAndOlder(_ reference: PendingTransactionReference) {
        values = values.filter {
            $0.transactionID != reference.transactionID
                || ($0 != reference && $0.signedDate >= reference.signedDate)
        }
    }

    func blockReferenceRead(requestNumber: Int) {
        blockedRequestNumber = requestNumber
    }

    func waitUntilBlockedReadStarts() async {
        if blockedRequestNumber == nil { return }
        await withCheckedContinuation { continuation in
            blockedReadStartedContinuations.append(continuation)
        }
    }

    func resumeBlockedRead() {
        blockedReadContinuation?.resume()
        blockedReadContinuation = nil
    }
}

private actor BlockingReferencesPendingTransactionStore: PendingTransactionStore {
    private var values: Set<PendingTransactionReference>
    private var shouldBlockNextRead = true
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var readStartedContinuations: [CheckedContinuation<Void, Never>] = []

    init(initialReferences: Set<PendingTransactionReference>) {
        values = initialReferences
    }

    func references() async throws -> Set<PendingTransactionReference> {
        if shouldBlockNextRead {
            shouldBlockNextRead = false
            let continuations = readStartedContinuations
            readStartedContinuations.removeAll()
            continuations.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                readContinuation = continuation
            }
        }
        return values
    }

    func insert(_ reference: PendingTransactionReference) {
        values.insert(reference)
    }

    func markDelivered(_ reference: PendingTransactionReference) {
        values.remove(reference)
        values.insert(reference.markingDelivered())
    }

    func remove(_ reference: PendingTransactionReference) {
        values.remove(reference)
    }

    func removeCurrentAndOlder(_ reference: PendingTransactionReference) {
        values = values.filter {
            $0.transactionID != reference.transactionID
                || ($0 != reference && $0.signedDate >= reference.signedDate)
        }
    }

    func waitUntilReadStarts() async {
        guard shouldBlockNextRead else { return }
        await withCheckedContinuation { continuation in
            readStartedContinuations.append(continuation)
        }
    }

    func resumeRead() {
        readContinuation?.resume()
        readContinuation = nil
    }

    func storedReferences() -> Set<PendingTransactionReference> {
        values
    }
}

private actor PostRemovalBlockingPendingTransactionStore: PendingTransactionStore {
    private var values = Set<PendingTransactionReference>()
    private var shouldBlockAfterNextRemoval = false
    private var removalContinuation: CheckedContinuation<Void, Never>?
    private var removalStartedContinuations: [CheckedContinuation<Void, Never>] = []

    func references() -> Set<PendingTransactionReference> {
        values
    }

    func insert(_ reference: PendingTransactionReference) {
        values.insert(reference)
    }

    func markDelivered(_ reference: PendingTransactionReference) {
        values.remove(reference)
        values.insert(reference.markingDelivered())
    }

    func remove(_ reference: PendingTransactionReference) {
        values.remove(reference)
    }

    func removeCurrentAndOlder(
        _ reference: PendingTransactionReference
    ) async {
        values = values.filter {
            $0.transactionID != reference.transactionID
                || ($0 != reference && $0.signedDate >= reference.signedDate)
        }
        guard shouldBlockAfterNextRemoval else { return }
        shouldBlockAfterNextRemoval = false
        let continuations = removalStartedContinuations
        removalStartedContinuations.removeAll()
        continuations.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            removalContinuation = continuation
        }
    }

    func blockAfterNextRemoval() {
        shouldBlockAfterNextRemoval = true
    }

    func waitUntilRemovalStarts() async {
        guard shouldBlockAfterNextRemoval else { return }
        await withCheckedContinuation { continuation in
            removalStartedContinuations.append(continuation)
        }
    }

    func resumeRemoval() {
        removalContinuation?.resume()
        removalContinuation = nil
    }
}

private actor CompletionFlag {
    private(set) var value = false

    func markCompleted() {
        value = true
    }
}

private enum TestFailure: Error {
    case processing
    case missingPurchaseResult
    case productLoad
}

private struct SensitiveTestFailure: Error {
    let message: String
}

private final class RecordingPaymentLogHandler: PaymentLogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PaymentLogEntry] = []

    var entries: [PaymentLogEntry] {
        lock.withLock { storage }
    }

    func log(_ entry: PaymentLogEntry) {
        lock.withLock { storage.append(entry) }
    }
}

private actor FakePaymentStoreGateway: PaymentStoreGateway {
    private var products: [StoreProduct] = []
    private var purchaseResults: [StorePurchaseResult] = []
    private var entitlements: [StoreTransactionVerification] = []
    private var unfinished: [StoreTransactionVerification] = []
    private var allTransactionValues: [StoreTransactionVerification] = []
    private var latestTransactionsByProductID: [String: StoreTransactionVerification] = [:]
    private var subscriptionResult = StoreSubscriptionStatusResult(
        statuses: [],
        verificationFailures: []
    )
    private var transactionSpecificSubscriptionResults: [
        UInt64: StoreSubscriptionStatusResult
    ] = [:]
    private var updateContinuations: [
        Int: AsyncStream<StoreTransactionVerification>.Continuation
    ] = [:]
    private var purchaseIntentContinuations: [
        Int: AsyncStream<StorePurchaseIntent>.Continuation
    ] = [:]
    private var storeMessageContinuations: [
        Int: AsyncStream<PaymentStoreMessage>.Continuation
    ] = [:]
    private var storefrontContinuations: [
        Int: AsyncStream<Void>.Continuation
    ] = [:]
    private var subscriptionStatusUpdateContinuations: [
        Int: AsyncStream<StoreSubscriptionStatusResult>.Continuation
    ] = [:]
    private var shouldBlockNextUpdateStream = false
    private var blockedUpdateStreamContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextEntitlementRequest = false
    private var blockedEntitlementContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextUnfinishedRequest = false
    private var blockedUnfinishedContinuation: CheckedContinuation<Void, Never>?
    private var blockedUnfinishedStartedContinuations: [
        CheckedContinuation<Void, Never>
    ] = []
    private var shouldBlockNextProductLoad = false
    private var blockedProductLoadContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextCanMakePayments = false
    private var blockedCanMakePaymentsContinuation: CheckedContinuation<Void, Never>?
    private var blockedCanMakePaymentsStartedContinuations: [
        CheckedContinuation<Void, Never>
    ] = []
    private var failingProductLoadRequestNumbers = Set<Int>()
    private var cancellingProductLoadRequestNumbers = Set<Int>()
    private var shouldBlockNextSubscriptionStatusRequest = false
    private var blockedSubscriptionStatusContinuation: CheckedContinuation<Void, Never>?
    private var filtersSubscriptionResultsByRequestedGroups = false
    private var shouldCancelNextSync = false
    private var nextSyncError: StoreKitError?
    private var shouldBlockNextSync = false
    private var blockedSyncContinuation: CheckedContinuation<Void, Never>?
    private var blockedSyncStartedContinuations: [
        CheckedContinuation<Void, Never>
    ] = []
    private var paymentsAllowed = true
    private var purchaseIntentsSupported = true
    private var storeMessagesSupported = true
    private(set) var finishedTransactionIDs: [UInt64] = []
    private(set) var syncCount = 0
    private(set) var updateStreamRequestCount = 0
    private(set) var purchaseIntentStreamRequestCount = 0
    private(set) var storeMessageStreamRequestCount = 0
    private(set) var storefrontStreamRequestCount = 0
    private(set) var subscriptionStatusUpdateStreamRequestCount = 0
    private(set) var updateStreamTerminationCount = 0
    private(set) var purchaseIntentStreamTerminationCount = 0
    private(set) var storeMessageStreamTerminationCount = 0
    private(set) var storefrontStreamTerminationCount = 0
    private(set) var subscriptionStatusUpdateStreamTerminationCount = 0
    private(set) var purchaseCallCount = 0
    private(set) var purchaseIntentPurchaseCallCount = 0
    private(set) var purchaseOptions: [PurchaseOptions] = []
    private(set) var entitlementRequestCount = 0
    private(set) var productLoadRequestCount = 0
    private(set) var subscriptionStatusRequestCount = 0
    private(set) var transactionSpecificSubscriptionStatusRequestCount = 0

    func setProducts(_ products: [StoreProduct]) {
        self.products = products
    }

    func blockNextProductLoadRequest() {
        shouldBlockNextProductLoad = true
    }

    func resumeBlockedProductLoadRequest() {
        blockedProductLoadContinuation?.resume()
        blockedProductLoadContinuation = nil
    }

    func failProductLoad(requestNumber: Int) {
        failingProductLoadRequestNumbers.insert(requestNumber)
    }

    func cancelProductLoad(requestNumber: Int) {
        cancellingProductLoadRequestNumbers.insert(requestNumber)
    }

    func enqueuePurchaseResult(_ result: StorePurchaseResult) {
        purchaseResults.append(result)
    }

    func setEntitlements(_ transactions: [StoreTransactionVerification]) {
        entitlements = transactions
    }

    func blockNextEntitlementRequest() {
        shouldBlockNextEntitlementRequest = true
    }

    func resumeBlockedEntitlementRequest() {
        blockedEntitlementContinuation?.resume()
        blockedEntitlementContinuation = nil
    }

    func setUnfinished(_ transactions: [StoreTransactionVerification]) {
        unfinished = transactions
    }

    func blockNextUnfinishedRequest() {
        shouldBlockNextUnfinishedRequest = true
    }

    func waitUntilBlockedUnfinishedRequestStarts() async {
        guard shouldBlockNextUnfinishedRequest else { return }
        await withCheckedContinuation { continuation in
            blockedUnfinishedStartedContinuations.append(continuation)
        }
    }

    func resumeBlockedUnfinishedRequest() {
        blockedUnfinishedContinuation?.resume()
        blockedUnfinishedContinuation = nil
    }

    func setAllTransactions(_ transactions: [StoreTransactionVerification]) {
        allTransactionValues = transactions
    }

    func setLatestTransaction(
        _ transaction: StoreTransactionVerification,
        for productID: String
    ) {
        latestTransactionsByProductID[productID] = transaction
    }

    func setSubscriptionResult(_ result: StoreSubscriptionStatusResult) {
        subscriptionResult = result
    }

    func setTransactionSpecificSubscriptionResult(
        _ result: StoreSubscriptionStatusResult,
        for transactionID: UInt64
    ) {
        transactionSpecificSubscriptionResults[transactionID] = result
    }

    func filterSubscriptionResultsByRequestedGroups() {
        filtersSubscriptionResultsByRequestedGroups = true
    }

    func blockNextSubscriptionStatusRequest() {
        shouldBlockNextSubscriptionStatusRequest = true
    }

    func resumeBlockedSubscriptionStatusRequest() {
        blockedSubscriptionStatusContinuation?.resume()
        blockedSubscriptionStatusContinuation = nil
    }

    func cancelNextSync() {
        shouldCancelNextSync = true
    }

    func failNextSync(with error: StoreKitError) {
        nextSyncError = error
    }

    func blockNextSync() {
        shouldBlockNextSync = true
    }

    func waitUntilBlockedSyncStarts() async {
        guard shouldBlockNextSync else { return }
        await withCheckedContinuation { continuation in
            blockedSyncStartedContinuations.append(continuation)
        }
    }

    func resumeBlockedSync() {
        blockedSyncContinuation?.resume()
        blockedSyncContinuation = nil
    }

    func setCanMakePayments(_ value: Bool) {
        paymentsAllowed = value
    }

    func blockNextCanMakePaymentsRequest() {
        shouldBlockNextCanMakePayments = true
    }

    func waitUntilBlockedCanMakePaymentsRequestStarts() async {
        guard shouldBlockNextCanMakePayments else { return }
        await withCheckedContinuation { continuation in
            blockedCanMakePaymentsStartedContinuations.append(continuation)
        }
    }

    func resumeBlockedCanMakePaymentsRequest() {
        blockedCanMakePaymentsContinuation?.resume()
        blockedCanMakePaymentsContinuation = nil
    }

    func setPurchaseIntentsSupported(_ value: Bool) {
        purchaseIntentsSupported = value
    }

    func setStoreMessagesSupported(_ value: Bool) {
        storeMessagesSupported = value
    }

    var allLongLivedStreamsTerminated: Bool {
        updateStreamTerminationCount == 1
            && purchaseIntentStreamTerminationCount == 1
            && storeMessageStreamTerminationCount == 1
            && storefrontStreamTerminationCount == 1
            && subscriptionStatusUpdateStreamTerminationCount == 1
    }

    func blockNextTransactionUpdateRequest() {
        shouldBlockNextUpdateStream = true
    }

    func resumeBlockedTransactionUpdateRequest() {
        blockedUpdateStreamContinuation?.resume()
        blockedUpdateStreamContinuation = nil
    }

    func sendUpdate(
        _ verification: StoreTransactionVerification,
        requestNumber: Int? = nil
    ) {
        let number = requestNumber ?? updateStreamRequestCount
        updateContinuations[number]?.yield(verification)
    }

    func finishUpdateStream(requestNumber: Int) {
        updateContinuations[requestNumber]?.finish()
        updateContinuations[requestNumber] = nil
    }

    func sendPurchaseIntent(
        _ intent: StorePurchaseIntent,
        requestNumber: Int? = nil
    ) {
        let number = requestNumber ?? purchaseIntentStreamRequestCount
        purchaseIntentContinuations[number]?.yield(intent)
    }

    func finishPurchaseIntentStream(requestNumber: Int) {
        purchaseIntentContinuations[requestNumber]?.finish()
        purchaseIntentContinuations[requestNumber] = nil
    }

    func finishStoreMessageStream(requestNumber: Int) {
        storeMessageContinuations[requestNumber]?.finish()
        storeMessageContinuations[requestNumber] = nil
    }

    func sendStoreMessage(
        _ message: PaymentStoreMessage,
        requestNumber: Int? = nil
    ) {
        let number = requestNumber ?? storeMessageStreamRequestCount
        storeMessageContinuations[number]?.yield(message)
    }

    func yieldStorefrontUpdate(requestNumber: Int? = nil) {
        let number = requestNumber ?? storefrontStreamRequestCount
        storefrontContinuations[number]?.yield()
    }

    func yieldSubscriptionStatusUpdate(
        _ result: StoreSubscriptionStatusResult = StoreSubscriptionStatusResult(
            statuses: [],
            verificationFailures: []
        ),
        requestNumber: Int? = nil
    ) {
        let number = requestNumber ?? subscriptionStatusUpdateStreamRequestCount
        subscriptionStatusUpdateContinuations[number]?.yield(result)
    }

    func finishSubscriptionStatusUpdates(requestNumber: Int? = nil) {
        let number = requestNumber ?? subscriptionStatusUpdateStreamRequestCount
        subscriptionStatusUpdateContinuations[number]?.finish()
        subscriptionStatusUpdateContinuations[number] = nil
    }

    func subscriptionStatusUpdateRequestCount() -> Int {
        subscriptionStatusUpdateStreamRequestCount
    }

    func waitForSubscriptionStatusUpdateRequestCount(
        _ expectedCount: Int
    ) async throws {
        try await waitUntil {
            await self.subscriptionStatusUpdateRequestCount() == expectedCount
        }
    }

    func finishStorefrontUpdates(requestNumber: Int? = nil) {
        let number = requestNumber ?? storefrontStreamRequestCount
        storefrontContinuations[number]?.finish()
        storefrontContinuations[number] = nil
    }

    func storefrontRequestCount() -> Int {
        storefrontStreamRequestCount
    }

    func waitForStorefrontRequestCount(_ expectedCount: Int) async throws {
        try await waitUntil {
            await self.storefrontRequestCount() == expectedCount
        }
    }

    func canMakePayments() async -> Bool {
        if shouldBlockNextCanMakePayments {
            shouldBlockNextCanMakePayments = false
            let continuations = blockedCanMakePaymentsStartedContinuations
            blockedCanMakePaymentsStartedContinuations.removeAll()
            continuations.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                blockedCanMakePaymentsContinuation = continuation
            }
        }
        return paymentsAllowed
    }

    func supportsPurchaseIntents() async -> Bool {
        purchaseIntentsSupported
    }

    func supportsStoreMessages() async -> Bool {
        storeMessagesSupported
    }

    func loadProducts(for identifiers: [String]) async throws -> [StoreProduct] {
        productLoadRequestCount += 1
        let requestNumber = productLoadRequestCount
        let result = products
        let shouldBlock = shouldBlockNextProductLoad
        shouldBlockNextProductLoad = false
        if shouldBlock {
            await withCheckedContinuation { continuation in
                blockedProductLoadContinuation = continuation
            }
        }
        if cancellingProductLoadRequestNumbers.remove(requestNumber) != nil {
            throw CancellationError()
        }
        if failingProductLoadRequestNumbers.remove(requestNumber) != nil {
            throw TestFailure.productLoad
        }
        return result
    }

    func purchase(productID: String, options: PurchaseOptions) async throws -> StorePurchaseResult {
        purchaseCallCount += 1
        purchaseOptions.append(options)
        guard !purchaseResults.isEmpty else { throw TestFailure.missingPurchaseResult }
        return purchaseResults.removeFirst()
    }

    func purchase(
        intent: StorePurchaseIntent,
        options: PurchaseOptions
    ) async throws -> StorePurchaseResult {
        purchaseIntentPurchaseCallCount += 1
        purchaseOptions.append(options)
        guard !purchaseResults.isEmpty else { throw TestFailure.missingPurchaseResult }
        return purchaseResults.removeFirst()
    }

    func currentEntitlements() async -> [StoreTransactionVerification] {
        entitlementRequestCount += 1
        let result = entitlements
        let shouldBlock = shouldBlockNextEntitlementRequest
        shouldBlockNextEntitlementRequest = false
        if shouldBlock {
            await withCheckedContinuation { continuation in
                blockedEntitlementContinuation = continuation
            }
        }
        return result
    }

    func unfinishedTransactions() async -> [StoreTransactionVerification] {
        let result = unfinished
        let shouldBlock = shouldBlockNextUnfinishedRequest
        shouldBlockNextUnfinishedRequest = false
        if shouldBlock {
            let continuations = blockedUnfinishedStartedContinuations
            blockedUnfinishedStartedContinuations.removeAll()
            continuations.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                blockedUnfinishedContinuation = continuation
            }
        }
        return result
    }

    func allTransactions() async -> [StoreTransactionVerification] { allTransactionValues }

    func latestTransaction(for productID: String) async -> StoreTransactionVerification? {
        latestTransactionsByProductID[productID]
    }

    func subscriptionStatuses(for groupIDs: Set<String>) async -> StoreSubscriptionStatusResult {
        subscriptionStatusRequestCount += 1
        let result: StoreSubscriptionStatusResult
        if filtersSubscriptionResultsByRequestedGroups && groupIDs.isEmpty {
            result = StoreSubscriptionStatusResult(statuses: [], verificationFailures: [])
        } else {
            result = subscriptionResult
        }
        let shouldBlock = shouldBlockNextSubscriptionStatusRequest
        shouldBlockNextSubscriptionStatusRequest = false
        if shouldBlock {
            await withCheckedContinuation { continuation in
                blockedSubscriptionStatusContinuation = continuation
            }
        }
        return result
    }

    func subscriptionStatus(
        forTransactionID transactionID: UInt64
    ) async -> StoreSubscriptionStatusResult? {
        transactionSpecificSubscriptionStatusRequestCount += 1
        return transactionSpecificSubscriptionResults[transactionID]
    }

    func transactionUpdates() async -> AsyncStream<StoreTransactionVerification> {
        updateStreamRequestCount += 1
        let requestNumber = updateStreamRequestCount
        let shouldBlock = shouldBlockNextUpdateStream
        shouldBlockNextUpdateStream = false
        if shouldBlock {
            await withCheckedContinuation { continuation in
                blockedUpdateStreamContinuation = continuation
            }
        }
        let stream = AsyncStream<StoreTransactionVerification>.makeStream()
        stream.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.transactionUpdateStreamDidTerminate(
                    requestNumber: requestNumber
                )
            }
        }
        updateContinuations[requestNumber] = stream.continuation
        return stream.stream
    }

    func purchaseIntents() async -> AsyncStream<StorePurchaseIntent> {
        purchaseIntentStreamRequestCount += 1
        let requestNumber = purchaseIntentStreamRequestCount
        let stream = AsyncStream<StorePurchaseIntent>.makeStream()
        stream.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.purchaseIntentStreamDidTerminate(
                    requestNumber: requestNumber
                )
            }
        }
        purchaseIntentContinuations[requestNumber] = stream.continuation
        return stream.stream
    }

    func storeMessages() async -> AsyncStream<PaymentStoreMessage> {
        storeMessageStreamRequestCount += 1
        let requestNumber = storeMessageStreamRequestCount
        let stream = AsyncStream<PaymentStoreMessage>.makeStream()
        stream.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.storeMessageStreamDidTerminate(
                    requestNumber: requestNumber
                )
            }
        }
        storeMessageContinuations[requestNumber] = stream.continuation
        return stream.stream
    }

    func storefrontUpdates() async -> AsyncStream<Void> {
        storefrontStreamRequestCount += 1
        let requestNumber = storefrontStreamRequestCount
        let stream = AsyncStream<Void>.makeStream()
        stream.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.storefrontStreamDidTerminate(
                    requestNumber: requestNumber
                )
            }
        }
        storefrontContinuations[requestNumber] = stream.continuation
        return stream.stream
    }

    func subscriptionStatusUpdates() async -> AsyncStream<StoreSubscriptionStatusResult> {
        subscriptionStatusUpdateStreamRequestCount += 1
        let requestNumber = subscriptionStatusUpdateStreamRequestCount
        let stream = AsyncStream<StoreSubscriptionStatusResult>.makeStream()
        stream.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.subscriptionStatusUpdateStreamDidTerminate(
                    requestNumber: requestNumber
                )
            }
        }
        subscriptionStatusUpdateContinuations[requestNumber] = stream.continuation
        return stream.stream
    }

    private func transactionUpdateStreamDidTerminate(requestNumber: Int) {
        updateContinuations[requestNumber] = nil
        updateStreamTerminationCount += 1
    }

    private func purchaseIntentStreamDidTerminate(requestNumber: Int) {
        purchaseIntentContinuations[requestNumber] = nil
        purchaseIntentStreamTerminationCount += 1
    }

    private func storeMessageStreamDidTerminate(requestNumber: Int) {
        storeMessageContinuations[requestNumber] = nil
        storeMessageStreamTerminationCount += 1
    }

    private func storefrontStreamDidTerminate(requestNumber: Int) {
        storefrontContinuations[requestNumber] = nil
        storefrontStreamTerminationCount += 1
    }

    private func subscriptionStatusUpdateStreamDidTerminate(requestNumber: Int) {
        subscriptionStatusUpdateContinuations[requestNumber] = nil
        subscriptionStatusUpdateStreamTerminationCount += 1
    }

    func sync() async throws {
        syncCount += 1
        if shouldBlockNextSync {
            shouldBlockNextSync = false
            await withCheckedContinuation { continuation in
                blockedSyncContinuation = continuation
                let startedContinuations = blockedSyncStartedContinuations
                blockedSyncStartedContinuations.removeAll()
                for startedContinuation in startedContinuations {
                    startedContinuation.resume()
                }
            }
        }
        if shouldCancelNextSync {
            shouldCancelNextSync = false
            throw CancellationError()
        }
        if let nextSyncError {
            self.nextSyncError = nil
            throw nextSyncError
        }
    }

    func finish(_ transaction: StoreTransaction) async {
        finishedTransactionIDs.append(transaction.value.id)
        unfinished.removeAll { verification in
            guard case .verified(let unfinishedTransaction) = verification else {
                return false
            }
            return unfinishedTransaction.value.signedEventIdentifier
                == transaction.value.signedEventIdentifier
        }
    }
}

private extension PaymentProduct {
    static func fixture(
        id: String,
        type: PaymentProductType = .nonConsumable,
        price: Decimal = 1,
        displayPrice: String = "$1.00",
        subscriptionGroupID: String? = nil,
        introductoryOffer: PaymentSubscriptionOffer? = nil,
        promotionalOffers: [PaymentSubscriptionOffer] = [],
        winBackOffers: [PaymentSubscriptionOffer] = [],
        pricingTerms: [PaymentSubscriptionPricingTerms] = [],
        isEligibleForIntroductoryOffer: Bool = false
    ) -> PaymentProduct {
        let subscription = subscriptionGroupID.map { groupID in
            PaymentSubscriptionInfo(
                groupID: groupID,
                period: PaymentSubscriptionPeriod(unit: .month, value: 1),
                introductoryOffer: introductoryOffer,
                promotionalOffers: promotionalOffers,
                winBackOffers: winBackOffers,
                pricingTerms: pricingTerms,
                isEligibleForIntroductoryOffer: isEligibleForIntroductoryOffer
            )
        }
        return PaymentProduct(
            id: id,
            type: type,
            displayName: id,
            description: "Fixture",
            price: price,
            displayPrice: displayPrice,
            isFamilyShareable: false,
            subscription: subscription
        )
    }
}

private extension PaymentSubscriptionOffer {
    static func fixture(
        paymentMode: PaymentSubscriptionOffer.PaymentMode
    ) -> PaymentSubscriptionOffer {
        PaymentSubscriptionOffer(
            id: nil,
            price: 0,
            displayPrice: "$0.00",
            period: PaymentSubscriptionPeriod(unit: .week, value: 1),
            periodCount: 1,
            paymentMode: paymentMode
        )
    }
}

private extension PaymentTransaction {
    static func fixture(
        id: UInt64,
        productID: String = "premium",
        productType: PaymentProductType = .nonConsumable,
        subscriptionGroupID: String? = nil,
        signedDate: Date = Date(timeIntervalSince1970: 1),
        expirationDate: Date? = nil,
        revocationDate: Date? = nil,
        jwsRepresentation: String = "fixture-jws",
        appAccountToken: UUID? = nil,
        isUpgraded: Bool = false,
        appliedOffer: PaymentAppliedOffer? = nil,
        billingPlan: PaymentBillingPlan? = nil,
        commitment: PaymentTransactionCommitment? = nil
    ) -> PaymentTransaction {
        PaymentTransaction(
            id: id,
            originalID: id,
            productID: productID,
            subscriptionGroupID: subscriptionGroupID,
            productType: productType,
            purchaseDate: Date(timeIntervalSince1970: 0),
            originalPurchaseDate: Date(timeIntervalSince1970: 0),
            expirationDate: expirationDate,
            revocationDate: revocationDate,
            signedDate: signedDate,
            ownershipType: .purchased,
            purchasedQuantity: 1,
            appAccountToken: appAccountToken,
            isUpgraded: isUpgraded,
            jwsRepresentation: jwsRepresentation,
            appliedOffer: appliedOffer,
            billingPlan: billingPlan,
            commitment: commitment
        )
    }
}

private extension PaymentSubscriptionStatus {
    static func fixture(
        transactionID: UInt64,
        groupID: String = "group",
        productID: String = "premium",
        state: PaymentRenewalState = .subscribed,
        signedDate: Date = Date(timeIntervalSince1970: 1),
        transactionJWS: String = "fixture-jws",
        renewalJWS: String = "renewal-jws",
        boundary: Date? = nil,
        kind: SubscriptionBoundaryKind = .expiration,
        renewalDate: Date? = nil,
        gracePeriodExpirationDate: Date? = nil,
        commitmentRenewalDate: Date? = nil,
        eligibleWinBackOfferIDs: [String] = [],
        willAutoRenew: Bool = true
    ) -> PaymentSubscriptionStatus {
        let transaction = PaymentTransaction.fixture(
            id: transactionID,
            productID: productID,
            productType: .autoRenewableSubscription,
            subscriptionGroupID: groupID,
            signedDate: signedDate,
            expirationDate: kind == .expiration ? boundary : nil,
            jwsRepresentation: transactionJWS
        )
        return PaymentSubscriptionStatus(
            groupID: groupID,
            state: state,
            transaction: transaction,
            renewalInfo: PaymentRenewalInfo(
                originalTransactionID: transactionID,
                currentProductID: transaction.productID,
                willAutoRenew: willAutoRenew,
                autoRenewPreference: nil,
                expirationReason: nil,
                priceIncreaseStatus: .noIncreasePending,
                isInBillingRetry: false,
                gracePeriodExpirationDate: kind == .gracePeriod
                    ? boundary
                    : gracePeriodExpirationDate,
                renewalDate: kind == .renewal ? boundary : renewalDate,
                renewalPrice: nil,
                currencyCode: nil,
                jwsRepresentation: renewalJWS,
                eligibleWinBackOfferIDs: eligibleWinBackOfferIDs,
                commitment: kind == .commitment
                    ? boundary.map {
                        PaymentRenewalCommitment(
                            autoRenewPreference: productID,
                            renewalBillingPlan: .monthlyCommitment,
                            renewalDate: $0,
                            renewalPrice: 9.99,
                            willAutoRenew: true
                        )
                    }
                    : commitmentRenewalDate.map {
                        PaymentRenewalCommitment(
                            autoRenewPreference: productID,
                            renewalBillingPlan: .monthlyCommitment,
                            renewalDate: $0,
                            renewalPrice: 9.99,
                            willAutoRenew: true
                        )
                    }
            )
        )
    }
}
