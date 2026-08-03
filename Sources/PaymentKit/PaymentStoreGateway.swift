import Foundation
import StoreKit

/// PaymentClient 与 StoreKit 之间的可替换边界。
internal protocol PaymentStoreGateway: Sendable {
    func canMakePayments() async -> Bool
    func supportsPurchaseIntents() async -> Bool
    func supportsStoreMessages() async -> Bool
    func loadProducts(for identifiers: [String]) async throws -> [StoreProduct]
    func purchase(productID: String, options: PurchaseOptions) async throws -> StorePurchaseResult
    func purchase(
        intent: StorePurchaseIntent,
        options: PurchaseOptions
    ) async throws -> StorePurchaseResult
    func currentEntitlements() async -> [StoreTransactionVerification]
    func unfinishedTransactions() async -> [StoreTransactionVerification]
    func allTransactions() async -> [StoreTransactionVerification]
    func latestTransaction(for productID: String) async -> StoreTransactionVerification?
    func subscriptionStatuses(for groupIDs: Set<String>) async -> StoreSubscriptionStatusResult
    func subscriptionStatus(
        forTransactionID transactionID: UInt64
    ) async -> StoreSubscriptionStatusResult?
    func transactionUpdates() async -> AsyncStream<StoreTransactionVerification>
    func subscriptionStatusUpdates() async -> AsyncStream<StoreSubscriptionStatusResult>
    func purchaseIntents() async -> AsyncStream<StorePurchaseIntent>
    func storeMessages() async -> AsyncStream<PaymentStoreMessage>
    func storefrontUpdates() async -> AsyncStream<Void>
    func sync() async throws
    func finish(_ transaction: StoreTransaction) async
}

/// 同时保存中立商品快照与 StoreKit 原始值。
internal struct StoreProduct: Sendable {
    let value: PaymentProduct
    let rawValue: Product?

    init(value: PaymentProduct, rawValue: Product? = nil) {
        self.value = value
        self.rawValue = rawValue
    }
}

/// 同时保存中立外部购买意图和完成购买所需的 StoreKit 原始值。
internal struct StorePurchaseIntent: Sendable {
    let value: PaymentPurchaseIntent
    let product: StoreProduct
    let rawOffer: Product.SubscriptionOffer?

    init(
        value: PaymentPurchaseIntent,
        product: StoreProduct,
        rawOffer: Product.SubscriptionOffer? = nil
    ) {
        self.value = value
        self.product = product
        self.rawOffer = rawOffer
    }
}

/// 同时保存已验证交易快照与 StoreKit 原始值。
internal struct StoreTransaction: Sendable {
    let value: PaymentTransaction
    let rawValue: Transaction?
    let canFinish: Bool

    init(
        value: PaymentTransaction,
        rawValue: Transaction? = nil,
        canFinish: Bool = true
    ) {
        self.value = value
        self.rawValue = rawValue
        self.canFinish = canFinish
    }
}

/// StoreKit 交易验签结果的内部表示。
internal enum StoreTransactionVerification: Sendable {
    case verified(StoreTransaction)
    case unverified(transactionID: UInt64?, message: String)
}

/// StoreKit 购买结果的内部表示。
internal enum StorePurchaseResult: Sendable {
    case success(StoreTransactionVerification)
    case pending
    case userCancelled
}

/// 一条订阅状态验签失败信息。
internal struct StoreVerificationFailure: Sendable, Equatable {
    let transactionID: UInt64?
    let message: String
}

/// 订阅状态查询的内部结果。
internal struct StoreSubscriptionStatusResult: Sendable, Equatable {
    let statuses: [PaymentSubscriptionStatus]
    let verificationFailures: [StoreVerificationFailure]
    let renewalInfoSignedDatesByStatusID: [String: Date]
    let replacedGroupIDs: Set<String>

    init(
        statuses: [PaymentSubscriptionStatus],
        verificationFailures: [StoreVerificationFailure],
        renewalInfoSignedDatesByStatusID: [String: Date] = [:],
        replacedGroupIDs: Set<String> = []
    ) {
        self.statuses = statuses
        self.verificationFailures = verificationFailures
        self.renewalInfoSignedDatesByStatusID = renewalInfoSignedDatesByStatusID
        self.replacedGroupIDs = replacedGroupIDs
    }
}

/// 直接调用 StoreKit 2 的生产网关。
internal actor StoreKitPaymentStoreGateway: PaymentStoreGateway {
    private var productsByID: [String: Product] = [:]
    private let logger: any PaymentLogHandler

    /// 创建直接访问 StoreKit 2 的生产网关。
    ///
    /// - Parameter logger: 记录有限 StoreKit 序列超时等不含敏感字段的诊断信息。
    init(logger: any PaymentLogHandler = OSPaymentLogHandler()) {
        self.logger = logger
    }

    func canMakePayments() async -> Bool {
        AppStore.canMakePayments
    }

    func supportsPurchaseIntents() async -> Bool {
        if #available(iOS 16.4, macOS 14.4, *) {
            return true
        }
        return false
    }

    func supportsStoreMessages() async -> Bool {
#if os(iOS)
        if #available(iOS 16.0, *) {
            return true
        }
#endif
        return false
    }

    func loadProducts(for identifiers: [String]) async throws -> [StoreProduct] {
        let products = try await Product.products(for: identifiers)
        var mapped: [StoreProduct] = []

        for product in products {
            let value = await Self.map(product)
            productsByID[product.id] = product
            mapped.append(StoreProduct(value: value, rawValue: product))
        }

        return mapped
    }

    func purchase(productID: String, options: PurchaseOptions) async throws -> StorePurchaseResult {
        guard let product = productsByID[productID] else {
            throw PaymentError(
                code: .productNotFound,
                message: "未找到商品 \(productID)",
                productID: productID
            )
        }

        return try await purchase(
            product: product,
            options: options,
            externalWinBackOffer: nil
        )
    }

    /// 使用 App Store 外部购买意图携带的原始商品和回归优惠发起购买。
    ///
    /// 外部回归优惠可能不会出现在当前商品缓存的 `winBackOffers` 中，因此必须把
    /// `PurchaseIntent.offer` 原样交回 StoreKit，不能仅凭优惠标识重新查询。
    func purchase(
        intent: StorePurchaseIntent,
        options: PurchaseOptions
    ) async throws -> StorePurchaseResult {
        guard let product = intent.product.rawValue else {
            throw PaymentError(
                code: .invalidPurchaseOptions,
                message: "购买意图缺少 StoreKit 原始商品",
                productID: intent.value.productID
            )
        }
        return try await purchase(
            product: product,
            options: options,
            externalWinBackOffer: intent.rawOffer
        )
    }

    private func purchase(
        product: Product,
        options: PurchaseOptions,
        externalWinBackOffer: Product.SubscriptionOffer?
    ) async throws -> StorePurchaseResult {
        let productID = product.id
        var storeOptions = Set<Product.PurchaseOption>()
        if options.quantity != 1 {
            storeOptions.insert(.quantity(options.quantity))
        }
        if let token = options.appAccountToken {
            storeOptions.insert(.appAccountToken(token))
        }
        if options.simulatesAskToBuyInSandbox {
            storeOptions.insert(.simulatesAskToBuyInSandbox(true))
        }
        if let eligibility = options.introductoryOfferEligibility {
            // PaymentClient 已完成 compact JWS 外形和商品适用范围校验。
            // StoreKit 负责验证后台签名及声明是否可用于本次购买。
            storeOptions.insert(
                .introductoryOfferEligibility(compactJWS: eligibility.compactJWS)
            )
        }
        if case .promotional(let authorization) = options.offer {
            // 新版 JWS 购买选项由 SDK 回部署到最低支持系统；完整声明只在内存中使用。
            storeOptions.formUnion(
                Product.PurchaseOption.promotionalOffer(
                    authorization.offerID,
                    compactJWS: authorization.compactJWS
                )
            )
        }
        if case .winBack(let offerID) = options.offer {
            guard #available(iOS 18.0, macOS 15.0, *) else {
                throw PaymentError(
                    code: .unsupportedFeature,
                    message: "当前系统不支持回归用户优惠购买",
                    productID: productID
                )
            }
            let offer: Product.SubscriptionOffer?
            if let externalWinBackOffer {
                guard externalWinBackOffer.id == offerID else {
                    throw PaymentError(
                        code: .invalidPurchaseOptions,
                        message: "购买意图的回归优惠与选择不一致",
                        productID: productID
                    )
                }
                offer = externalWinBackOffer
            } else {
                offer = product.subscription?.winBackOffers.first(where: {
                    $0.id == offerID
                })
            }
            guard let offer else {
                throw PaymentError(
                    code: .offerNotFound,
                    message: "StoreKit 没有返回请求的回归用户优惠",
                    productID: productID
                )
            }
            storeOptions.insert(.winBackOffer(offer))
        }
        if let billingPlan = options.billingPlan {
            guard #available(iOS 26.4, macOS 26.4, *) else {
                throw PaymentError(
                    code: .unsupportedFeature,
                    message: "当前系统不支持订阅承诺账单计划",
                    productID: productID
                )
            }
            switch billingPlan {
            case .upFront:
                storeOptions.insert(.billingPlanType(.upFront))
            case .monthlyCommitment:
                storeOptions.insert(.billingPlanType(.monthly))
            case .unknown:
                throw PaymentError(
                    code: .billingPlanUnavailable,
                    message: "无法映射请求的账单计划",
                    productID: productID
                )
            }
        }

        let result = try await product.purchase(options: storeOptions)
        switch result {
        case .success(let verification):
            return .success(await mapEnrichingXcodeIntroductoryOffer(verification))
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            throw PaymentError(
                code: .storeKitFailed,
                message: "StoreKit 返回了未知购买结果",
                productID: productID
            )
        }
    }

    func currentEntitlements() async -> [StoreTransactionVerification] {
        let stream = AsyncStream<StoreTransactionVerification> { continuation in
            let task = Task {
                for await verification in Transaction.currentEntitlements {
                    guard !Task.isCancelled else { break }
                    continuation.yield(
                        await mapEnrichingXcodeIntroductoryOffer(verification)
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return await collectFiniteTransactionStream(
            stream,
            operation: "current-entitlements"
        )
    }

    func unfinishedTransactions() async -> [StoreTransactionVerification] {
        let stream = AsyncStream<StoreTransactionVerification> { continuation in
            let task = Task {
                for await verification in Transaction.unfinished {
                    guard !Task.isCancelled else { break }
                    continuation.yield(
                        await mapEnrichingXcodeIntroductoryOffer(verification)
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return await collectFiniteTransactionStream(
            stream,
            operation: "unfinished"
        )
    }

    func allTransactions() async -> [StoreTransactionVerification] {
        let stream = AsyncStream<StoreTransactionVerification> { continuation in
            let task = Task {
                for await verification in Transaction.all {
                    guard !Task.isCancelled else { break }
                    continuation.yield(
                        await mapEnrichingXcodeIntroductoryOffer(verification)
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return await collectFiniteTransactionStream(
            stream,
            operation: "all-transactions"
        )
    }

    func latestTransaction(for productID: String) async -> StoreTransactionVerification? {
        guard let verification = await Transaction.latest(for: productID) else { return nil }
        return await mapEnrichingXcodeIntroductoryOffer(verification)
    }

    func subscriptionStatuses(for groupIDs: Set<String>) async -> StoreSubscriptionStatusResult {
        var statuses: [PaymentSubscriptionStatus] = []
        var failures: [StoreVerificationFailure] = []
        var signedDatesByStatusID: [String: Date] = [:]

        for groupID in groupIDs.sorted() {
            do {
                let storeStatuses = try await Product.SubscriptionInfo.status(for: groupID)
                for status in storeStatuses {
                    let mapped = await mapSubscriptionStatus(
                        status,
                        fallbackGroupID: groupID
                    )
                    statuses.append(contentsOf: mapped.statuses)
                    failures.append(contentsOf: mapped.verificationFailures)
                    signedDatesByStatusID.merge(
                        mapped.renewalInfoSignedDatesByStatusID,
                        uniquingKeysWith: max
                    )
                }
            } catch is CancellationError {
                // 取消由 PaymentClient 在提交快照前统一处理，不应伪装成验签失败。
                break
            } catch {
                failures.append(
                    StoreVerificationFailure(
                        transactionID: nil,
                        message: "订阅状态加载失败"
                    )
                )
            }
        }

        return StoreSubscriptionStatusResult(
            statuses: statuses,
            verificationFailures: failures,
            renewalInfoSignedDatesByStatusID: signedDatesByStatusID
        )
    }

    func subscriptionStatus(
        forTransactionID transactionID: UInt64
    ) async -> StoreSubscriptionStatusResult? {
        guard #available(
            iOS 18.4,
            macOS 15.4,
            tvOS 18.4,
            watchOS 11.4,
            visionOS 2.4,
            *
        ) else {
            return nil
        }
        do {
            guard let status = try await Product.SubscriptionInfo.status(
                transactionID: transactionID
            ) else {
                return nil
            }
            return await mapSubscriptionStatus(
                status,
                fallbackGroupID: nil
            )
        } catch is CancellationError {
            return nil
        } catch {
            return StoreSubscriptionStatusResult(
                statuses: [],
                verificationFailures: [
                    StoreVerificationFailure(
                        transactionID: transactionID,
                        message: "按交易查询订阅状态失败"
                    ),
                ]
            )
        }
    }

    /// 仅在交易与续订信息均通过 StoreKit 本地验签后创建公共状态。
    private func mapSubscriptionStatus(
        _ status: Product.SubscriptionInfo.Status,
        fallbackGroupID: String?
    ) async -> StoreSubscriptionStatusResult {
        guard case .verified(let transaction) = status.transaction else {
            return StoreSubscriptionStatusResult(
                statuses: [],
                verificationFailures: [
                    StoreVerificationFailure(
                        transactionID: status.transaction.unsafePayloadValue.id,
                        message: "订阅交易验签失败"
                    ),
                ]
            )
        }
        guard case .verified(let renewalInfo) = status.renewalInfo else {
            return StoreSubscriptionStatusResult(
                statuses: [],
                verificationFailures: [
                    StoreVerificationFailure(
                        transactionID: transaction.id,
                        message: "订阅续订信息验签失败"
                    ),
                ]
            )
        }
        guard let groupID = transaction.subscriptionGroupID ?? fallbackGroupID else {
            return StoreSubscriptionStatusResult(
                statuses: [],
                verificationFailures: [
                    StoreVerificationFailure(
                        transactionID: transaction.id,
                        message: "订阅组标识缺失"
                    ),
                ]
            )
        }

        let transactionValue = await enrichXcodeIntroductoryOffer(
            in: Self.map(
                transaction,
                jwsRepresentation: status.transaction.jwsRepresentation,
                signedDate: status.transaction.signedDate
            ),
            rawTransaction: transaction
        )
        let renewalValue = await enrichXcodeIntroductoryOffer(
            in: Self.map(
                renewalInfo,
                jwsRepresentation: status.renewalInfo.jwsRepresentation
            ),
            rawRenewalInfo: renewalInfo
        )
        let mappedStatus = PaymentSubscriptionStatus(
            groupID: groupID,
            state: Self.map(status.state),
            transaction: transactionValue,
            renewalInfo: renewalValue
        )
        return StoreSubscriptionStatusResult(
            statuses: [mappedStatus],
            verificationFailures: [],
            renewalInfoSignedDatesByStatusID: [
                mappedStatus.id: status.renewalInfo.signedDate,
            ]
        )
    }

    private func mapSubscriptionStatuses(
        _ statuses: [Product.SubscriptionInfo.Status],
        fallbackGroupID: String,
        replacesGroup: Bool
    ) async -> StoreSubscriptionStatusResult {
        var mappedStatuses: [PaymentSubscriptionStatus] = []
        var failures: [StoreVerificationFailure] = []
        var signedDatesByStatusID: [String: Date] = [:]

        for status in statuses {
            let mapped = await mapSubscriptionStatus(
                status,
                fallbackGroupID: fallbackGroupID
            )
            mappedStatuses.append(contentsOf: mapped.statuses)
            failures.append(contentsOf: mapped.verificationFailures)
            signedDatesByStatusID.merge(
                mapped.renewalInfoSignedDatesByStatusID,
                uniquingKeysWith: max
            )
        }

        return StoreSubscriptionStatusResult(
            statuses: mappedStatuses,
            verificationFailures: failures,
            renewalInfoSignedDatesByStatusID: signedDatesByStatusID,
            replacedGroupIDs: replacesGroup ? [fallbackGroupID] : []
        )
    }

    func transactionUpdates() async -> AsyncStream<StoreTransactionVerification> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                for await verification in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    guard let self else { break }
                    continuation.yield(
                        await self.mapEnrichingXcodeIntroductoryOffer(verification)
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 监听每个订阅组的当前状态，并在旧系统回退为仅监听后续变化。
    func subscriptionStatusUpdates() async -> AsyncStream<StoreSubscriptionStatusResult> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                if #available(
                    iOS 17.0,
                    macOS 14.0,
                    tvOS 17.0,
                    watchOS 10.0,
                    visionOS 1.0,
                    *
                ) {
                    for await update in Product.SubscriptionInfo.Status.all {
                        guard !Task.isCancelled else { break }
                        guard let self else { break }
                        continuation.yield(
                            await self.mapSubscriptionStatuses(
                                update.statuses,
                                fallbackGroupID: update.groupID,
                                replacesGroup: true
                            )
                        )
                    }
                } else {
                    for await status in Product.SubscriptionInfo.Status.updates {
                        guard !Task.isCancelled else { break }
                        guard let self else { break }
                        continuation.yield(
                            await self.mapSubscriptionStatus(
                                status,
                                fallbackGroupID: nil
                            )
                        )
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func purchaseIntents() async -> AsyncStream<StorePurchaseIntent> {
        guard #available(iOS 16.4, macOS 14.4, *) else {
            return AsyncStream { $0.finish() }
        }

        return AsyncStream { continuation in
            let task = Task { [weak self] in
                for await intent in PurchaseIntent.intents {
                    guard !Task.isCancelled, let self else { break }
                    continuation.yield(await self.map(intent))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func storeMessages() async -> AsyncStream<PaymentStoreMessage> {
#if os(iOS)
        guard #available(iOS 16.0, *) else {
            return AsyncStream { $0.finish() }
        }
        return AsyncStream { continuation in
            let task = Task {
                for await message in Message.messages {
                    guard !Task.isCancelled else { break }
                    continuation.yield(
                        PaymentStoreMessage(
                            reason: Self.map(message.reason),
                            rawValue: message
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
#else
        return AsyncStream { $0.finish() }
#endif
    }

    /// 将 StoreKit Storefront 变化映射为不携带账户或地区标识的刷新信号。
    func storefrontUpdates() async -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in Storefront.updates {
                    guard !Task.isCancelled else { break }
                    // 客户端只需知道价格环境已变化；不得把 storefront 标识带出网关。
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    func finish(_ transaction: StoreTransaction) async {
        guard transaction.canFinish else { return }
        await transaction.rawValue?.finish()
    }

    /// 将外部购买意图加入商品缓存，并保留系统提供的回归优惠原始值。
    @available(iOS 16.4, macOS 14.4, *)
    func map(_ intent: PurchaseIntent) async -> StorePurchaseIntent {
        let mappedProduct = await Self.map(intent.product)
        let storeProduct = StoreProduct(value: mappedProduct, rawValue: intent.product)
        productsByID[intent.product.id] = intent.product

        let rawOffer: Product.SubscriptionOffer?
        if #available(iOS 18.0, macOS 15.0, *) {
            rawOffer = intent.offer
        } else {
            rawOffer = nil
        }
        return StorePurchaseIntent(
            value: PaymentPurchaseIntent(
                productID: intent.product.id,
                offer: rawOffer.map(Self.map)
            ),
            product: storeProduct,
            rawOffer: rawOffer
        )
    }
}

extension StoreKitPaymentStoreGateway {
    /// 映射交易，并补偿 Xcode StoreKit Testing 在旧系统遗漏的优惠字段。
    ///
    /// Apple 明确说明兼容优惠字段在 Xcode 测试中可能返回 `nil`。补偿只在
    /// `.xcode` 环境生效；Sandbox 与 Production 始终保留签名交易原值，
    /// 避免用当前商品配置猜测历史交易。
    func mapEnrichingXcodeIntroductoryOffer(
        _ verification: VerificationResult<Transaction>
    ) async -> StoreTransactionVerification {
        let mapped = Self.map(verification)
        guard case .verified(let transaction) = mapped,
              let rawTransaction = transaction.rawValue else {
            return mapped
        }

        let value = await enrichXcodeIntroductoryOffer(
            in: transaction.value,
            rawTransaction: rawTransaction
        )
        return .verified(
            StoreTransaction(
                value: value,
                rawValue: rawTransaction,
                canFinish: transaction.canFinish
            )
        )
    }

    /// 使用同一 Xcode 测试商品补全首购优惠付款方式和总优惠周期。
    func enrichXcodeIntroductoryOffer(
        in transaction: PaymentTransaction,
        rawTransaction: Transaction
    ) async -> PaymentTransaction {
        guard isXcodeEnvironment(rawTransaction),
              let appliedOffer = transaction.appliedOffer,
              appliedOffer.type == .introductory,
              appliedOffer.paymentMode == nil || appliedOffer.period == nil,
              let product = await productForOfferFallback(
                productID: transaction.productID
              ),
              let productOffer = product.subscription?.introductoryOffer else {
            return transaction
        }

        return transaction.replacingAppliedOffer(
            Self.completing(appliedOffer, with: productOffer)
        )
    }

    /// 使用同一 Xcode 测试商品补全续订信息中缺失的首购优惠字段。
    func enrichXcodeIntroductoryOffer(
        in renewalInfo: PaymentRenewalInfo,
        rawRenewalInfo: Product.SubscriptionInfo.RenewalInfo
    ) async -> PaymentRenewalInfo {
        guard isXcodeEnvironment(rawRenewalInfo),
              let appliedOffer = renewalInfo.appliedOffer,
              appliedOffer.type == .introductory,
              appliedOffer.paymentMode == nil || appliedOffer.period == nil,
              let product = await productForOfferFallback(
                productID: renewalInfo.currentProductID
              ),
              let productOffer = product.subscription?.introductoryOffer else {
            return renewalInfo
        }

        return renewalInfo.replacingAppliedOffer(
            Self.completing(appliedOffer, with: productOffer)
        )
    }

    /// 返回优惠补偿所需的原始商品，并复用网关现有商品缓存。
    func productForOfferFallback(productID: String) async -> Product? {
        if let product = productsByID[productID] {
            return product
        }
        guard let product = try? await Product.products(for: [productID]).first else {
            return nil
        }
        productsByID[product.id] = product
        return product
    }

    /// 判断交易是否来自 Xcode 本地 StoreKit 测试。
    func isXcodeEnvironment(_ transaction: Transaction) -> Bool {
        if #available(iOS 16.0, macOS 13.0, *) {
            return transaction.environment == .xcode
        }
#if os(iOS)
        return transaction.environmentStringRepresentation
            .caseInsensitiveCompare("Xcode") == .orderedSame
#else
        return false
#endif
    }

    /// 判断续订信息是否来自 Xcode 本地 StoreKit 测试。
    func isXcodeEnvironment(
        _ renewalInfo: Product.SubscriptionInfo.RenewalInfo
    ) -> Bool {
        if #available(iOS 16.0, macOS 13.0, *) {
            return renewalInfo.environment == .xcode
        }
#if os(iOS)
        return renewalInfo.environmentStringRepresentation
            .caseInsensitiveCompare("Xcode") == .orderedSame
#else
        return false
#endif
    }

    /// 收集预期会结束的 StoreKit 交易流，并为系统服务异常提供有界等待。
    ///
    /// `Transaction.updates` 是长期监听，不使用此入口。unfinished、history 和当前
    /// 权益按 SDK 契约应当结束；若系统服务未结束序列，框架必须继续启动并依赖
    /// 交易监听与 SQLite outbox 补偿。
    private func collectFiniteTransactionStream(
        _ stream: AsyncStream<StoreTransactionVerification>,
        operation: String
    ) async -> [StoreTransactionVerification] {
        let timeoutNanoseconds: UInt64 = 5_000_000_000
        guard let values = await Self.collectFiniteStream(
            stream,
            timeoutNanoseconds: timeoutNanoseconds
        ) else {
            if !Task.isCancelled {
                logger.log(
                    PaymentLogEntry(
                        level: .warning,
                        category: "storekit",
                        message: "StoreKit 有限交易序列读取超时，继续执行",
                        metadata: [
                            "operation": operation,
                            "timeoutMilliseconds": "5000",
                        ]
                    )
                )
            }
            return []
        }
        return values
    }

    /// 在限定时间内收集一个有限异步流；超时返回 `nil` 并取消生产者。
    ///
    /// 此方法保持为内部可测试入口，确保超时本身不会遗留悬挂读取任务。
    internal nonisolated static func collectFiniteStream<Value: Sendable>(
        _ stream: AsyncStream<Value>,
        timeoutNanoseconds: UInt64
    ) async -> [Value]? {
        await withTaskGroup(
            of: [Value]?.self,
            returning: [Value]?.self
        ) { group in
            group.addTask {
                var values: [Value] = []
                for await value in stream {
                    guard !Task.isCancelled else { return nil }
                    values.append(value)
                }
                return values
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return nil
                } catch {
                    return nil
                }
            }

            let first = await group.next() ?? nil
            // 无论正常完成或超时，都取消另一个分支；AsyncStream 终止回调继续取消
            // StoreKit 生产者，避免序列读取在后台无限存活。
            group.cancelAll()
            return first
        }
    }

    static func map(_ product: Product) async -> PaymentProduct {
        let subscription: PaymentSubscriptionInfo?
        if let info = product.subscription {
            let introductoryOffer = info.introductoryOffer.map(map)
            let promotionalOffers = info.promotionalOffers.map(map)
            let winBackOffers: [PaymentSubscriptionOffer]
            if #available(iOS 18.0, macOS 15.0, *) {
                winBackOffers = info.winBackOffers.map(map)
            } else {
                winBackOffers = []
            }

            let pricingTerms: [PaymentSubscriptionPricingTerms]
            if #available(iOS 26.4, macOS 26.4, *) {
                pricingTerms = info.pricingTerms.map(map)
            } else {
                // 旧系统只有标准价格。合成预付条款后，调用方可以统一渲染定价方案。
                let period = map(info.subscriptionPeriod)
                pricingTerms = [
                    PaymentSubscriptionPricingTerms(
                        billingPlan: .upFront,
                        billingPrice: product.price,
                        billingDisplayPrice: product.displayPrice,
                        billingPeriod: period,
                        commitment: PaymentSubscriptionCommitment(
                            price: product.price,
                            displayPrice: product.displayPrice,
                            period: period
                        ),
                        offers: [introductoryOffer].compactMap { $0 }
                            + promotionalOffers
                            + winBackOffers
                    )
                ]
            }
            subscription = PaymentSubscriptionInfo(
                groupID: info.subscriptionGroupID,
                period: map(info.subscriptionPeriod),
                introductoryOffer: introductoryOffer,
                promotionalOffers: promotionalOffers,
                winBackOffers: winBackOffers,
                pricingTerms: pricingTerms,
                isEligibleForIntroductoryOffer: await info.isEligibleForIntroOffer
            )
        } else {
            subscription = nil
        }

        return PaymentProduct(
            id: product.id,
            type: map(product.type),
            displayName: product.displayName,
            description: product.description,
            price: product.price,
            displayPrice: product.displayPrice,
            isFamilyShareable: product.isFamilyShareable,
            subscription: subscription
        )
    }

    static func map(_ type: Product.ProductType) -> PaymentProductType {
        if type == .consumable { return .consumable }
        if type == .nonConsumable { return .nonConsumable }
        if type == .nonRenewable { return .nonRenewingSubscription }
        if type == .autoRenewable { return .autoRenewableSubscription }
        return .unknown(type.rawValue)
    }

    static func map(_ period: Product.SubscriptionPeriod) -> PaymentSubscriptionPeriod {
        let unit: PaymentSubscriptionPeriod.Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: unit = .unknown
        }
        return PaymentSubscriptionPeriod(unit: unit, value: period.value)
    }

    static func map(_ offer: Product.SubscriptionOffer) -> PaymentSubscriptionOffer {
        let mode: PaymentSubscriptionOffer.PaymentMode
        if offer.paymentMode == .payAsYouGo {
            mode = .payAsYouGo
        } else if offer.paymentMode == .payUpFront {
            mode = .payUpFront
        } else if offer.paymentMode == .freeTrial {
            mode = .freeTrial
        } else {
            mode = .unknown(offer.paymentMode.rawValue)
        }

        return PaymentSubscriptionOffer(
            id: offer.id,
            type: mapProductOfferType(offer.type),
            typeRawValue: offer.type.rawValue,
            price: offer.price,
            displayPrice: offer.displayPrice,
            period: map(offer.period),
            periodCount: offer.periodCount,
            paymentMode: mode
        )
    }

    /// 映射 iOS 26.4 和 macOS 26.4 引入的订阅定价条款。
    @available(iOS 26.4, macOS 26.4, *)
    static func map(
        _ terms: Product.SubscriptionInfo.PricingTerms
    ) -> PaymentSubscriptionPricingTerms {
        PaymentSubscriptionPricingTerms(
            billingPlan: map(terms.billingPlanType),
            billingPrice: terms.billingPrice,
            billingDisplayPrice: terms.billingDisplayPrice,
            billingPeriod: map(terms.billingPeriod),
            commitment: PaymentSubscriptionCommitment(
                price: terms.commitmentInfo.price,
                displayPrice: terms.commitmentInfo.displayPrice,
                period: map(terms.commitmentInfo.period)
            ),
            offers: terms.subscriptionOffers.map(map)
        )
    }

    /// 映射订阅账单计划，并保留未来 StoreKit 原始值。
    @available(iOS 26.4, macOS 26.4, *)
    static func map(
        _ billingPlan: Product.SubscriptionInfo.BillingPlanType
    ) -> PaymentBillingPlan {
        if billingPlan == .upFront { return .upFront }
        if billingPlan == .monthly { return .monthlyCommitment }
        return .unknown(billingPlan.rawValue)
    }

    /// 用商品首购优惠补全 Xcode 测试交易缺失的实际优惠字段。
    static func completing(
        _ appliedOffer: PaymentAppliedOffer,
        with storeOffer: Product.SubscriptionOffer
    ) -> PaymentAppliedOffer {
        let productOffer = map(storeOffer)
        let totalPeriod = totalOfferPeriod(
            productOffer.period,
            periodCount: productOffer.periodCount
        )
        return PaymentAppliedOffer(
            id: appliedOffer.id ?? productOffer.id,
            type: appliedOffer.type,
            paymentMode: appliedOffer.paymentMode ?? productOffer.paymentMode,
            period: appliedOffer.period ?? totalPeriod,
            periodRawValue: appliedOffer.periodRawValue ?? iso8601Period(totalPeriod)
        )
    }

    /// 将商品的单期长度和期数合并为交易实际覆盖的总优惠周期。
    static func totalOfferPeriod(
        _ period: PaymentSubscriptionPeriod,
        periodCount: Int
    ) -> PaymentSubscriptionPeriod {
        let (value, overflow) = period.value.multipliedReportingOverflow(
            by: periodCount
        )
        guard !overflow, value > 0 else { return period }
        return PaymentSubscriptionPeriod(unit: period.unit, value: value)
    }

    static func map(_ verification: VerificationResult<Transaction>) -> StoreTransactionVerification {
        switch verification {
        case .verified(let transaction):
            return .verified(
                StoreTransaction(
                    value: map(
                        transaction,
                        jwsRepresentation: verification.jwsRepresentation,
                        signedDate: verification.signedDate
                    ),
                    rawValue: transaction
                )
            )
        case .unverified(let transaction, _):
            return .unverified(
                transactionID: transaction.id,
                message: "StoreKit 交易验签失败"
            )
        }
    }

    static func map(
        _ transaction: Transaction,
        jwsRepresentation: String,
        signedDate: Date
    ) -> PaymentTransaction {
        let ownershipType: PaymentOwnershipType
        if transaction.ownershipType == .purchased {
            ownershipType = .purchased
        } else if transaction.ownershipType == .familyShared {
            ownershipType = .familyShared
        } else {
            ownershipType = .unknown(transaction.ownershipType.rawValue)
        }

        let billingPlan: PaymentBillingPlan?
        let commitment: PaymentTransactionCommitment?
        if #available(iOS 26.4, macOS 26.4, *) {
            billingPlan = transaction.billingPlanType.map(map)
            commitment = transaction.commitmentInfo.map {
                PaymentTransactionCommitment(
                    billingPeriodNumber: $0.billingPeriodNumber,
                    totalBillingPeriods: $0.totalBillingPeriods,
                    expirationDate: $0.expirationDate,
                    price: $0.price
                )
            }
        } else {
            billingPlan = nil
            commitment = nil
        }

        return PaymentTransaction(
            id: transaction.id,
            originalID: transaction.originalID,
            productID: transaction.productID,
            subscriptionGroupID: transaction.subscriptionGroupID,
            productType: map(transaction.productType),
            purchaseDate: transaction.purchaseDate,
            originalPurchaseDate: transaction.originalPurchaseDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            signedDate: signedDate,
            ownershipType: ownershipType,
            purchasedQuantity: transaction.purchasedQuantity,
            appAccountToken: transaction.appAccountToken,
            isUpgraded: transaction.isUpgraded,
            jwsRepresentation: jwsRepresentation,
            appliedOffer: mapAppliedOffer(from: transaction),
            billingPlan: billingPlan,
            commitment: commitment
        )
    }

    static func map(_ state: Product.SubscriptionInfo.RenewalState) -> PaymentRenewalState {
        if state == .subscribed { return .subscribed }
        if state == .expired { return .expired }
        if state == .inBillingRetryPeriod { return .inBillingRetryPeriod }
        if state == .inGracePeriod { return .inGracePeriod }
        if state == .revoked { return .revoked }
        return .unknown(state.rawValue)
    }

    static func map(
        _ info: Product.SubscriptionInfo.RenewalInfo,
        jwsRepresentation: String
    ) -> PaymentRenewalInfo {
        let eligibleWinBackOfferIDs: [String]
        if #available(iOS 18.0, macOS 15.0, *) {
            eligibleWinBackOfferIDs = info.eligibleWinBackOfferIDs
        } else {
            eligibleWinBackOfferIDs = []
        }

        let renewalBillingPlan: PaymentBillingPlan?
        let commitment: PaymentRenewalCommitment?
        if #available(iOS 26.4, macOS 26.4, *) {
            renewalBillingPlan = info.renewalBillingPlanType.map(map)
            commitment = info.commitmentInfo.map {
                PaymentRenewalCommitment(
                    autoRenewPreference: $0.autoRenewPreference,
                    renewalBillingPlan: map($0.renewalBillingPlanType),
                    renewalDate: $0.renewalDate,
                    renewalPrice: $0.renewalPrice,
                    willAutoRenew: $0.willAutoRenew
                )
            }
        } else {
            renewalBillingPlan = nil
            commitment = nil
        }

        return PaymentRenewalInfo(
            originalTransactionID: info.originalTransactionID,
            currentProductID: info.currentProductID,
            willAutoRenew: info.willAutoRenew,
            autoRenewPreference: info.autoRenewPreference,
            expirationReason: info.expirationReason.map(map),
            priceIncreaseStatus: map(info.priceIncreaseStatus),
            isInBillingRetry: info.isInBillingRetry,
            gracePeriodExpirationDate: info.gracePeriodExpirationDate,
            renewalDate: info.renewalDate,
            renewalPrice: info.renewalPrice,
            currencyCode: currencyCode(for: info),
            jwsRepresentation: jwsRepresentation,
            appliedOffer: mapAppliedOffer(from: info),
            eligibleWinBackOfferIDs: eligibleWinBackOfferIDs,
            renewalBillingPlan: renewalBillingPlan,
            commitment: commitment
        )
    }

    static func currencyCode(
        for info: Product.SubscriptionInfo.RenewalInfo
    ) -> String? {
#if os(macOS)
        return info.currency?.identifier
#else
        if #available(iOS 16.0, *) {
            return info.currency?.identifier
        }
        return info.currencyCode
#endif
    }

    static func map(
        _ reason: Product.SubscriptionInfo.RenewalInfo.ExpirationReason
    ) -> PaymentExpirationReason {
        if reason == .autoRenewDisabled { return .autoRenewDisabled }
        if reason == .billingError { return .billingError }
        if reason == .didNotConsentToPriceIncrease { return .didNotConsentToPriceIncrease }
        if reason == .productUnavailable { return .productUnavailable }
        return .unknown(reason.rawValue)
    }

    static func map(
        _ status: Product.SubscriptionInfo.RenewalInfo.PriceIncreaseStatus
    ) -> PaymentPriceIncreaseStatus {
        switch status {
        case .noIncreasePending: .noIncreasePending
        case .pending: .pending
        case .agreed: .agreed
        @unknown default: .unknown
        }
    }
}

extension StoreKitPaymentStoreGateway {
#if os(iOS)
    /// 将 iOS StoreKit 系统消息原因映射为跨版本中立值。
    @available(iOS 16.0, *)
    static func map(_ reason: Message.Reason) -> PaymentStoreMessageReason {
        if reason == .generic { return .generic }
        if reason == .priceIncreaseConsent { return .priceIncreaseConsent }
        if #available(iOS 16.4, *), reason == .billingIssue {
            return .billingIssue
        }
        if #available(iOS 18.0, *), reason == .winBackOffer {
            return .winBack
        }
        return .unknown(reason.rawValue)
    }
#endif

    /// 将商品优惠类型映射为中立值，并为未来类型保留未知状态。
    static func mapProductOfferType(
        _ type: Product.SubscriptionOffer.OfferType
    ) -> PaymentOfferType {
        if type == .introductory { return .introductory }
        if type == .promotional { return .promotional }
        if #available(iOS 18.0, macOS 15.0, *), type == .winBack {
            return .winBack
        }

        // Offer Code 目前通常不会出现在旧版商品优惠数组中；新版定价条款
        // 若通过 raw value 提供该类型，仍映射为统一优惠代码类型。
        let normalized = type.rawValue
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        if normalized == "code" || normalized == "offercode" {
            return .offerCode
        }
        return .unknown(Int.min)
    }

    /// 从 StoreKit 原始优惠字段创建中立快照。
    ///
    /// 此入口保持为内部 API，便于在不依赖系统购买弹窗的单元测试中验证
    /// 旧系统兼容字段和未来未知值的映射。
    static func mapAppliedOffer(
        id: String?,
        typeRawValue: Int,
        paymentModeRawValue: String?,
        periodRawValue: String?,
        period: PaymentSubscriptionPeriod? = nil
    ) -> PaymentAppliedOffer? {
        let storeType = Transaction.OfferType(rawValue: typeRawValue)
        let type: PaymentOfferType
        if storeType == .introductory {
            type = .introductory
        } else if storeType == .promotional {
            type = .promotional
        } else if storeType == .code {
            type = .offerCode
        } else if storeType == .winBack {
            type = .winBack
        } else {
            type = .unknown(typeRawValue)
        }

        let paymentMode: PaymentSubscriptionOffer.PaymentMode?
        if let paymentModeRawValue {
            let storeMode = Product.SubscriptionOffer.PaymentMode(
                rawValue: paymentModeRawValue
            )
            let legacyMode = paymentModeRawValue.uppercased()
            if storeMode == .payAsYouGo || legacyMode == "PAY_AS_YOU_GO" {
                paymentMode = .payAsYouGo
            } else if storeMode == .payUpFront || legacyMode == "PAY_UP_FRONT" {
                paymentMode = .payUpFront
            } else if storeMode == .freeTrial || legacyMode == "FREE_TRIAL" {
                paymentMode = .freeTrial
            } else {
                // StoreKit 旧兼容字段使用大写下划线，新接口使用 SDK raw value。
                // 对未来未知值保留原文，避免系统新增付款方式导致信息丢失。
                paymentMode = .unknown(paymentModeRawValue)
            }
        } else {
            paymentMode = nil
        }

        return PaymentAppliedOffer(
            id: id,
            type: type,
            paymentMode: paymentMode,
            period: period ?? periodRawValue.flatMap(parseOfferPeriod),
            periodRawValue: periodRawValue
        )
    }

    /// 解析 StoreKit 旧系统返回的单单位 ISO 8601 优惠周期。
    static func parseOfferPeriod(_ rawValue: String) -> PaymentSubscriptionPeriod? {
        guard rawValue.first == "P", rawValue.count >= 3,
              let suffix = rawValue.last else {
            return nil
        }
        let numberStart = rawValue.index(after: rawValue.startIndex)
        let numberEnd = rawValue.index(before: rawValue.endIndex)
        guard let value = Int(rawValue[numberStart..<numberEnd]), value > 0 else {
            return nil
        }

        let unit: PaymentSubscriptionPeriod.Unit
        switch suffix {
        case "D": unit = .day
        case "W": unit = .week
        case "M": unit = .month
        case "Y": unit = .year
        default: return nil
        }
        return PaymentSubscriptionPeriod(unit: unit, value: value)
    }
}

private extension StoreKitPaymentStoreGateway {
    static func mapAppliedOffer(from transaction: Transaction) -> PaymentAppliedOffer? {
        if #available(iOS 17.2, macOS 14.2, *) {
            guard let offer = transaction.offer else { return nil }
            let rawPeriod = transaction.offerPeriodStringRepresentation
            let structuredPeriod: PaymentSubscriptionPeriod?
            if #available(iOS 18.4, macOS 15.4, *), let period = offer.period {
                structuredPeriod = map(period)
            } else {
                structuredPeriod = rawPeriod.flatMap(parseOfferPeriod)
            }
            return mapAppliedOffer(
                id: offer.id,
                typeRawValue: offer.type.rawValue,
                paymentModeRawValue: offer.paymentMode?.rawValue,
                periodRawValue: rawPeriod ?? structuredPeriod.flatMap(iso8601Period),
                period: structuredPeriod
            )
        }

        // iOS 15–17.1 与 macOS 13–14.1 通过兼容属性提供同一优惠信息。
        guard let type = transaction.offerType else { return nil }
        return mapAppliedOffer(
            id: transaction.offerID,
            typeRawValue: type.rawValue,
            paymentModeRawValue: transaction.offerPaymentModeStringRepresentation,
            periodRawValue: transaction.offerPeriodStringRepresentation
        )
    }

    static func mapAppliedOffer(
        from info: Product.SubscriptionInfo.RenewalInfo
    ) -> PaymentAppliedOffer? {
        if #available(iOS 18.0, macOS 15.0, *) {
            guard let offer = info.offer else { return nil }
            let rawPeriod = info.offerPeriodStringRepresentation
            let structuredPeriod: PaymentSubscriptionPeriod?
            if #available(iOS 18.4, macOS 15.4, *), let period = offer.period {
                structuredPeriod = map(period)
            } else {
                structuredPeriod = rawPeriod.flatMap(parseOfferPeriod)
            }
            return mapAppliedOffer(
                id: offer.id,
                typeRawValue: offer.type.rawValue,
                paymentModeRawValue: offer.paymentMode?.rawValue,
                periodRawValue: rawPeriod ?? structuredPeriod.flatMap(iso8601Period),
                period: structuredPeriod
            )
        }

        // 旧系统继续使用 StoreKit 提供的兼容属性，不直接解析续订 JWS。
        guard let type = info.offerType else { return nil }
        return mapAppliedOffer(
            id: info.offerID,
            typeRawValue: type.rawValue,
            paymentModeRawValue: info.offerPaymentModeStringRepresentation,
            periodRawValue: info.offerPeriodStringRepresentation
        )
    }

    static func iso8601Period(_ period: PaymentSubscriptionPeriod) -> String? {
        let suffix: String
        switch period.unit {
        case .day: suffix = "D"
        case .week: suffix = "W"
        case .month: suffix = "M"
        case .year: suffix = "Y"
        case .unknown: return nil
        }
        return "P\(period.value)\(suffix)"
    }
}
