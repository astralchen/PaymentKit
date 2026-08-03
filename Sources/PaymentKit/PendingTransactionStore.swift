import Foundation

/// 可从 outbox 恢复的已验证交易快照。
private struct PersistedPaymentTransaction: Codable, Sendable {
    let id: UInt64
    let originalID: UInt64
    let productID: String
    let subscriptionGroupID: String?
    let productTypeRawValue: String
    let purchaseDate: Date
    let originalPurchaseDate: Date
    let expirationDate: Date?
    let revocationDate: Date?
    let signedDate: Date
    let ownershipTypeRawValue: String
    let purchasedQuantity: Int
    let appAccountToken: UUID?
    let isUpgraded: Bool
    let jwsRepresentation: String
    let appliedOfferID: String?
    let appliedOfferTypeRawValue: Int?
    let appliedOfferPaymentModeRawValue: String?
    let appliedOfferPeriodUnitRawValue: String?
    let appliedOfferPeriodValue: Int?
    let appliedOfferPeriodRawValue: String?
    let billingPlanRawValue: String?
    let commitmentBillingPeriodNumber: UInt64?
    let commitmentTotalBillingPeriods: UInt64?
    let commitmentExpirationDate: Date?
    let commitmentPrice: Decimal?

    init(transaction: PaymentTransaction) {
        id = transaction.id
        originalID = transaction.originalID
        productID = transaction.productID
        subscriptionGroupID = transaction.subscriptionGroupID
        productTypeRawValue = transaction.productType.rawValue
        purchaseDate = transaction.purchaseDate
        originalPurchaseDate = transaction.originalPurchaseDate
        expirationDate = transaction.expirationDate
        revocationDate = transaction.revocationDate
        signedDate = transaction.signedDate
        switch transaction.ownershipType {
        case .purchased:
            ownershipTypeRawValue = "purchased"
        case .familyShared:
            ownershipTypeRawValue = "familyShared"
        case .unknown(let rawValue):
            ownershipTypeRawValue = rawValue
        }
        purchasedQuantity = transaction.purchasedQuantity
        appAccountToken = transaction.appAccountToken
        isUpgraded = transaction.isUpgraded
        jwsRepresentation = transaction.jwsRepresentation
        appliedOfferID = transaction.appliedOffer?.id
        appliedOfferTypeRawValue = transaction.appliedOffer?.type.persistenceRawValue
        appliedOfferPaymentModeRawValue =
            transaction.appliedOffer?.paymentMode?.persistenceRawValue
        appliedOfferPeriodUnitRawValue = transaction.appliedOffer?.period?.unit.rawValue
        appliedOfferPeriodValue = transaction.appliedOffer?.period?.value
        appliedOfferPeriodRawValue = transaction.appliedOffer?.periodRawValue
        billingPlanRawValue = transaction.billingPlan?.persistenceRawValue
        commitmentBillingPeriodNumber = transaction.commitment?.billingPeriodNumber
        commitmentTotalBillingPeriods = transaction.commitment?.totalBillingPeriods
        commitmentExpirationDate = transaction.commitment?.expirationDate
        commitmentPrice = transaction.commitment?.price
    }

    var value: PaymentTransaction {
        let ownershipType: PaymentOwnershipType
        switch ownershipTypeRawValue {
        case "purchased":
            ownershipType = .purchased
        case "familyShared":
            ownershipType = .familyShared
        default:
            ownershipType = .unknown(ownershipTypeRawValue)
        }
        let appliedOffer: PaymentAppliedOffer?
        if let offerTypeRawValue = appliedOfferTypeRawValue {
            let period: PaymentSubscriptionPeriod?
            if let unitRawValue = appliedOfferPeriodUnitRawValue,
               let value = appliedOfferPeriodValue {
                period = PaymentSubscriptionPeriod(
                    unit: PaymentSubscriptionPeriod.Unit(rawValue: unitRawValue) ?? .unknown,
                    value: value
                )
            } else {
                period = nil
            }
            appliedOffer = PaymentAppliedOffer(
                id: appliedOfferID,
                type: PaymentOfferType(persistenceRawValue: offerTypeRawValue),
                paymentMode: appliedOfferPaymentModeRawValue.map {
                    PaymentSubscriptionOffer.PaymentMode(persistenceRawValue: $0)
                },
                period: period,
                periodRawValue: appliedOfferPeriodRawValue
            )
        } else {
            // 旧版 payload 没有优惠字段时保持源码与数据兼容。
            appliedOffer = nil
        }
        let commitment: PaymentTransactionCommitment?
        if let billingPeriodNumber = commitmentBillingPeriodNumber,
           let totalBillingPeriods = commitmentTotalBillingPeriods,
           let expirationDate = commitmentExpirationDate,
           let price = commitmentPrice {
            commitment = PaymentTransactionCommitment(
                billingPeriodNumber: billingPeriodNumber,
                totalBillingPeriods: totalBillingPeriods,
                expirationDate: expirationDate,
                price: price
            )
        } else {
            commitment = nil
        }

        return PaymentTransaction(
            id: id,
            originalID: originalID,
            productID: productID,
            subscriptionGroupID: subscriptionGroupID,
            productType: PaymentProductType(rawValue: productTypeRawValue),
            purchaseDate: purchaseDate,
            originalPurchaseDate: originalPurchaseDate,
            expirationDate: expirationDate,
            revocationDate: revocationDate,
            signedDate: signedDate,
            ownershipType: ownershipType,
            purchasedQuantity: purchasedQuantity,
            appAccountToken: appAccountToken,
            isUpgraded: isUpgraded,
            jwsRepresentation: jwsRepresentation,
            appliedOffer: appliedOffer,
            billingPlan: billingPlanRawValue.map {
                PaymentBillingPlan(persistenceRawValue: $0)
            },
            commitment: commitment
        )
    }
}

private extension PaymentBillingPlan {
    init(persistenceRawValue: String) {
        switch persistenceRawValue {
        case "upFront":
            self = .upFront
        case "monthlyCommitment":
            self = .monthlyCommitment
        default:
            self = .unknown(persistenceRawValue)
        }
    }

    var persistenceRawValue: String {
        switch self {
        case .upFront:
            "upFront"
        case .monthlyCommitment:
            "monthlyCommitment"
        case .unknown(let rawValue):
            rawValue
        }
    }
}

private extension PaymentOfferType {
    init(persistenceRawValue: Int) {
        switch persistenceRawValue {
        case 1: self = .introductory
        case 2: self = .promotional
        case 3: self = .offerCode
        case 4: self = .winBack
        default: self = .unknown(persistenceRawValue)
        }
    }

    var persistenceRawValue: Int {
        switch self {
        case .introductory: 1
        case .promotional: 2
        case .offerCode: 3
        case .winBack: 4
        case .unknown(let rawValue): rawValue
        }
    }
}

private extension PaymentSubscriptionOffer.PaymentMode {
    init(persistenceRawValue: String) {
        switch persistenceRawValue {
        case "payAsYouGo": self = .payAsYouGo
        case "payUpFront": self = .payUpFront
        case "freeTrial": self = .freeTrial
        default: self = .unknown(persistenceRawValue)
        }
    }

    var persistenceRawValue: String {
        switch self {
        case .payAsYouGo: "payAsYouGo"
        case .payUpFront: "payUpFront"
        case .freeTrial: "freeTrial"
        case .unknown(let rawValue): rawValue
        }
    }
}

/// 一条等待可靠交付或 StoreKit `finish()` 的签名事件记录。
internal struct PendingTransactionReference: Codable, Hashable, Sendable {
    let transactionID: UInt64
    let signedDate: Date
    let jwsDigest: String
    let productID: String?
    private let transactionPayload: PersistedPaymentTransaction?
    private let hasBeenDelivered: Bool?

    /// 从已验证交易创建待交付索引。
    init(transaction: PaymentTransaction) {
        transactionID = transaction.id
        signedDate = transaction.signedDate
        jwsDigest = Self.digest(transaction.jwsRepresentation)
        productID = transaction.productID
        transactionPayload = PersistedPaymentTransaction(transaction: transaction)
        hasBeenDelivered = false
    }

    private init(
        transactionID: UInt64,
        signedDate: Date,
        jwsDigest: String,
        productID: String?,
        transactionPayload: PersistedPaymentTransaction?,
        hasBeenDelivered: Bool
    ) {
        self.transactionID = transactionID
        self.signedDate = signedDate
        self.jwsDigest = jwsDigest
        self.productID = productID
        self.transactionPayload = transactionPayload
        self.hasBeenDelivered = hasBeenDelivered
    }

    /// 上次进程是否已经完成后台幂等交付、但仍在等待 StoreKit `finish()`。
    var isDelivered: Bool {
        hasBeenDelivered == true
    }

    /// 返回上次由 StoreKit 本地验证后保存的中立交易快照。
    var persistedTransaction: PaymentTransaction? {
        transactionPayload?.value
    }

    /// 判断 StoreKit 交易是否对应同一个签名事件。
    func matches(_ transaction: PaymentTransaction) -> Bool {
        transactionID == transaction.id
            && signedDate == transaction.signedDate
            && jwsDigest == Self.digest(transaction.jwsRepresentation)
    }

    /// 判断当前记录是否已经完成指定交易业务状态的后台交付。
    ///
    /// StoreKit 可能仅更新签名时间和 JWS；这种等价重新签名不能把已交付状态
    /// 降级为等待交付。撤销、升级、到期或所有权变化仍会形成不同业务状态。
    func recordsCompletedDelivery(of transaction: PaymentTransaction) -> Bool {
        guard isDelivered else { return false }
        return matches(transaction)
            || persistedTransaction?.deliveryState == transaction.deliveryState
    }

    /// 返回已完成后台交付、等待 StoreKit `finish()` 的记录。
    func markingDelivered() -> PendingTransactionReference {
        PendingTransactionReference(
            transactionID: transactionID,
            signedDate: signedDate,
            jwsDigest: jwsDigest,
            productID: productID,
            transactionPayload: transactionPayload,
            hasBeenDelivered: true
        )
    }

    /// 合并同一签名事件在不同调用保存的信息。
    func merging(_ other: PendingTransactionReference) -> PendingTransactionReference {
        PendingTransactionReference(
            transactionID: transactionID,
            signedDate: signedDate,
            jwsDigest: jwsDigest,
            productID: productID ?? other.productID,
            transactionPayload: transactionPayload ?? other.transactionPayload,
            hasBeenDelivered: isDelivered || other.isDelivered
        )
    }

    static func == (
        lhs: PendingTransactionReference,
        rhs: PendingTransactionReference
    ) -> Bool {
        lhs.transactionID == rhs.transactionID
            && lhs.signedDate == rhs.signedDate
            && lhs.jwsDigest == rhs.jwsDigest
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(transactionID)
        hasher.combine(signedDate)
        hasher.combine(jwsDigest)
    }

    private static func digest(_ value: String) -> String {
        PaymentSignedEventIdentity.jwsDigest(for: value).base64EncodedString()
    }
}

/// 持久化待交付交易索引的内部边界。
internal protocol PendingTransactionStore: Sendable {
    /// 返回当前保存的全部待交付索引。
    func references() async throws -> Set<PendingTransactionReference>

    /// 保存一条待交付索引。
    func insert(_ reference: PendingTransactionReference) async throws

    /// 标记后台已经完成幂等交付，后续只需等待 StoreKit `finish()`。
    func markDelivered(_ reference: PendingTransactionReference) async throws

    /// 删除已经可靠交付的签名事件索引。
    func remove(_ reference: PendingTransactionReference) async throws

    /// 删除已结束签名及同一交易中更早的签名索引。
    ///
    /// 更晚的签名可能表示撤销或其他状态变化，必须继续保留并独立交付。
    func removeCurrentAndOlder(_ reference: PendingTransactionReference) async throws

    /// 返回并清空尚未报告的损坏数据库隔离次数。
    func consumeRecoveryIncidentCount() async -> Int
}

internal extension PendingTransactionStore {
    func consumeRecoveryIncidentCount() async -> Int { 0 }
}

/// 仅保存在内存中的待交付索引存储，供确定性测试使用。
internal actor InMemoryPendingTransactionStore: PendingTransactionStore {
    private var values = Set<PendingTransactionReference>()

    func references() -> Set<PendingTransactionReference> {
        values
    }

    func insert(_ reference: PendingTransactionReference) {
        if let existing = values.first(where: { $0 == reference }) {
            values.remove(existing)
            values.insert(existing.merging(reference))
        } else {
            values.insert(reference)
        }
    }

    func markDelivered(_ reference: PendingTransactionReference) {
        if let existing = values.first(where: { $0 == reference }) {
            values.remove(existing)
            values.insert(existing.merging(reference).markingDelivered())
        } else {
            values.insert(reference.markingDelivered())
        }
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
}
