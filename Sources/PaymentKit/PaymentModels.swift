import Foundation

/// 订阅周期。
public struct PaymentSubscriptionPeriod: Sendable, Equatable, Hashable {
    /// 订阅周期使用的时间单位。
    public enum Unit: String, Sendable, Equatable, Hashable {
        /// 天。
        case day
        /// 周。
        case week
        /// 月。
        case month
        /// 年。
        case year
        /// 当前版本尚未识别的单位。
        case unknown
    }

    /// 周期单位。
    public let unit: Unit

    /// 周期包含的单位数量。
    public let value: Int

    /// 创建订阅周期。
    ///
    /// - Parameters:
    ///   - unit: 周期单位。
    ///   - value: 单位数量。
    public init(unit: Unit, value: Int) {
        self.unit = unit
        self.value = value
    }
}

/// 订阅优惠的展示信息。
public struct PaymentSubscriptionOffer: Sendable, Equatable {
    /// 订阅优惠的付款方式。
    public enum PaymentMode: Sendable, Equatable, Hashable {
        /// 按周期支付。
        case payAsYouGo
        /// 预先支付全部优惠价格。
        case payUpFront
        /// 免费试用。
        case freeTrial
        /// 当前版本尚未识别的付款方式及其 StoreKit 原始值。
        case unknown(String)
    }

    /// App Store Connect 中配置的优惠标识符。
    public let id: String?

    /// 优惠类型。
    public let type: PaymentOfferType

    /// StoreKit 返回的优惠类型原始值。
    ///
    /// 已知类型也保留此值；由调用方自行构造的模型可以为 `nil`。
    /// 未来系统新增优惠类型时，可使用此字段进行诊断或前向兼容展示。
    public let typeRawValue: String?

    /// 优惠价格。
    public let price: Decimal

    /// App Store 本地化后的优惠价格。
    public let displayPrice: String

    /// 每个优惠周期的长度。
    public let period: PaymentSubscriptionPeriod

    /// 优惠包含的周期数量。
    public let periodCount: Int

    /// 付款方式。
    public let paymentMode: PaymentMode

    /// 创建订阅优惠展示信息。
    public init(
        id: String?,
        type: PaymentOfferType = .introductory,
        typeRawValue: String? = nil,
        price: Decimal,
        displayPrice: String,
        period: PaymentSubscriptionPeriod,
        periodCount: Int,
        paymentMode: PaymentMode
    ) {
        self.id = id
        self.type = type
        self.typeRawValue = typeRawValue
        self.price = price
        self.displayPrice = displayPrice
        self.period = period
        self.periodCount = periodCount
        self.paymentMode = paymentMode
    }
}

/// App Store 实际应用到交易或续订的优惠类型。
public enum PaymentOfferType: Sendable, Equatable, Hashable {
    /// 首购优惠。
    case introductory

    /// 促销优惠。
    case promotional

    /// 优惠代码。
    case offerCode

    /// 回归用户优惠。
    case winBack

    /// 当前版本尚未识别的优惠类型及其 StoreKit 原始值。
    case unknown(Int)
}

/// 自动续期订阅完整承诺期限的价格和周期。
public struct PaymentSubscriptionCommitment: Sendable, Equatable, Hashable {
    /// 完整承诺期限的总价。
    public let price: Decimal

    /// App Store 本地化后的完整承诺总价。
    public let displayPrice: String

    /// 完整承诺期限。
    public let period: PaymentSubscriptionPeriod

    /// 创建订阅承诺信息。
    public init(
        price: Decimal,
        displayPrice: String,
        period: PaymentSubscriptionPeriod
    ) {
        self.price = price
        self.displayPrice = displayPrice
        self.period = period
    }
}

/// 自动续期订阅的一组可购买定价条款。
public struct PaymentSubscriptionPricingTerms: Sendable, Equatable {
    /// 条款对应的账单计划。
    public let billingPlan: PaymentBillingPlan

    /// 每个账单周期收取的价格。
    public let billingPrice: Decimal

    /// App Store 本地化后的每期价格。
    public let billingDisplayPrice: String

    /// 扣款周期。
    public let billingPeriod: PaymentSubscriptionPeriod

    /// 完整承诺期限；普通预付订阅同样提供完整周期信息。
    public let commitment: PaymentSubscriptionCommitment

    /// 仅适用于当前账单计划的优惠。
    public let offers: [PaymentSubscriptionOffer]

    /// 创建订阅定价条款。
    public init(
        billingPlan: PaymentBillingPlan,
        billingPrice: Decimal,
        billingDisplayPrice: String,
        billingPeriod: PaymentSubscriptionPeriod,
        commitment: PaymentSubscriptionCommitment,
        offers: [PaymentSubscriptionOffer]
    ) {
        self.billingPlan = billingPlan
        self.billingPrice = billingPrice
        self.billingDisplayPrice = billingDisplayPrice
        self.billingPeriod = billingPeriod
        self.commitment = commitment
        self.offers = offers
    }
}

/// App Store 实际应用到交易或续订的优惠快照。
public struct PaymentAppliedOffer: Sendable, Equatable, Hashable {
    /// App Store Connect 中配置的优惠标识符。
    public let id: String?

    /// 实际应用的优惠类型。
    public let type: PaymentOfferType

    /// 实际应用的付款方式。
    public let paymentMode: PaymentSubscriptionOffer.PaymentMode?

    /// StoreKit 能够结构化表示的优惠周期。
    public let period: PaymentSubscriptionPeriod?

    /// StoreKit 返回的原始 ISO 8601 周期。
    ///
    /// 旧系统或未来新增周期形式无法结构化时，此值仍会保留。
    public let periodRawValue: String?

    /// 创建实际优惠快照。
    ///
    /// - Parameters:
    ///   - id: App Store Connect 中配置的优惠标识符。
    ///   - type: 实际应用的优惠类型。
    ///   - paymentMode: 实际应用的付款方式。
    ///   - period: 已结构化的优惠周期。
    ///   - periodRawValue: StoreKit 返回的原始 ISO 8601 周期。
    public init(
        id: String?,
        type: PaymentOfferType,
        paymentMode: PaymentSubscriptionOffer.PaymentMode?,
        period: PaymentSubscriptionPeriod?,
        periodRawValue: String?
    ) {
        self.id = id
        self.type = type
        self.paymentMode = paymentMode
        self.period = period
        self.periodRawValue = periodRawValue
    }
}

/// 自动续期订阅的商品信息。
public struct PaymentSubscriptionInfo: Sendable, Equatable {
    /// 订阅组标识符。
    public let groupID: String

    /// 标准续订周期。
    public let period: PaymentSubscriptionPeriod

    /// 可用的首购优惠。
    public let introductoryOffer: PaymentSubscriptionOffer?

    /// 当前商品配置的促销优惠。
    ///
    /// 用户资格由调用方生产后台决定，PaymentKit 不在本地推断。
    public let promotionalOffers: [PaymentSubscriptionOffer]

    /// 当前商品配置的回归用户优惠。
    ///
    /// 此数组不代表当前账户一定有资格，调用方必须与续订信息中的
    /// `eligibleWinBackOfferIDs` 交叉匹配。
    public let winBackOffers: [PaymentSubscriptionOffer]

    /// 当前系统可用的全部账单计划及各自优惠。
    public let pricingTerms: [PaymentSubscriptionPricingTerms]

    /// 当前用户是否满足首购优惠资格。
    public let isEligibleForIntroductoryOffer: Bool

    /// 创建订阅商品信息。
    public init(
        groupID: String,
        period: PaymentSubscriptionPeriod,
        introductoryOffer: PaymentSubscriptionOffer?,
        promotionalOffers: [PaymentSubscriptionOffer] = [],
        winBackOffers: [PaymentSubscriptionOffer] = [],
        pricingTerms: [PaymentSubscriptionPricingTerms] = [],
        isEligibleForIntroductoryOffer: Bool
    ) {
        self.groupID = groupID
        self.period = period
        self.introductoryOffer = introductoryOffer
        self.promotionalOffers = promotionalOffers
        self.winBackOffers = winBackOffers
        self.pricingTerms = pricingTerms
        self.isEligibleForIntroductoryOffer = isEligibleForIntroductoryOffer
    }
}

/// 可供购买的 App Store 商品快照。
public struct PaymentProduct: Identifiable, Sendable, Equatable {
    /// 商品标识符。
    public let id: String

    /// 商品类型。
    public let type: PaymentProductType

    /// App Store 本地化后的商品名称。
    public let displayName: String

    /// App Store 本地化后的商品描述。
    public let description: String

    /// 商品价格。
    public let price: Decimal

    /// App Store 本地化后的商品价格。
    public let displayPrice: String

    /// 商品是否支持家人共享。
    public let isFamilyShareable: Bool

    /// 自动续期订阅信息；其他商品类型为 `nil`。
    public let subscription: PaymentSubscriptionInfo?

    /// 创建商品快照。
    public init(
        id: String,
        type: PaymentProductType,
        displayName: String,
        description: String,
        price: Decimal,
        displayPrice: String,
        isFamilyShareable: Bool,
        subscription: PaymentSubscriptionInfo?
    ) {
        self.id = id
        self.type = type
        self.displayName = displayName
        self.description = description
        self.price = price
        self.displayPrice = displayPrice
        self.isFamilyShareable = isFamilyShareable
        self.subscription = subscription
    }
}

/// 用户在 App Store 或系统回归优惠入口发起、等待应用完成的购买意图。
public struct PaymentPurchaseIntent: Identifiable, Sendable, Equatable {
    /// 由商品和优惠组成的稳定标识。
    public let id: String

    /// 用户选择的商品标识符。
    public let productID: String

    /// 用户从系统入口选择的回归优惠；普通推广购买为 `nil`。
    public let offer: PaymentSubscriptionOffer?

    /// 创建外部购买意图快照。
    ///
    /// 生产实例由 `PaymentClient.purchaseIntents()` 产生。公开初始化方法便于
    /// 调用方保存界面状态和构建测试夹具，但只有当前客户端收到的实例才能购买。
    public init(productID: String, offer: PaymentSubscriptionOffer? = nil) {
        self.productID = productID
        self.offer = offer
        if let offer {
            let type: String
            switch offer.type {
            case .introductory: type = "introductory"
            case .promotional: type = "promotional"
            case .offerCode: type = "offerCode"
            case .winBack: type = "winBack"
            case .unknown(let rawValue): type = "unknown-\(rawValue)"
            }
            id = "\(productID)|\(type)|\(offer.id ?? "unidentified")"
        } else {
            id = "\(productID)|standard"
        }
    }
}

/// 交易商品的所有权类型。
public enum PaymentOwnershipType: Sendable, Equatable, Hashable {
    /// 当前用户直接购买。
    case purchased

    /// 通过家人共享获得。
    case familyShared

    /// 当前版本尚未识别的所有权类型及其 StoreKit 原始值。
    case unknown(String)
}

/// 月付承诺交易在完整承诺期限中的进度。
public struct PaymentTransactionCommitment: Sendable, Equatable, Hashable {
    /// 当前交易对应的账单期序号，从 `1` 开始。
    public let billingPeriodNumber: UInt64

    /// 完整承诺包含的账单期总数。
    public let totalBillingPeriods: UInt64

    /// 当前承诺期限的结束日期。
    public let expirationDate: Date

    /// 当前账单期实际支付的价格。
    public let price: Decimal

    /// 创建交易承诺进度。
    public init(
        billingPeriodNumber: UInt64,
        totalBillingPeriods: UInt64,
        expirationDate: Date,
        price: Decimal
    ) {
        self.billingPeriodNumber = billingPeriodNumber
        self.totalBillingPeriods = totalBillingPeriods
        self.expirationDate = expirationDate
        self.price = price
    }
}

/// 已通过 StoreKit 本地验证的交易快照。
public struct PaymentTransaction: Identifiable, Sendable, Equatable {
    /// 当前交易标识符。
    public let id: UInt64

    /// 原始购买交易标识符。
    public let originalID: UInt64

    /// 商品标识符。
    public let productID: String

    /// 订阅组标识符。
    public let subscriptionGroupID: String?

    /// 商品类型。
    public let productType: PaymentProductType

    /// 当前交易的购买日期。
    public let purchaseDate: Date

    /// 原始购买日期。
    public let originalPurchaseDate: Date

    /// 商品或订阅到期日期。
    public let expirationDate: Date?

    /// App Store 撤销交易的日期。
    public let revocationDate: Date?

    /// App Store 签署当前交易状态的日期。
    public let signedDate: Date

    /// 交易商品的所有权类型。
    public let ownershipType: PaymentOwnershipType

    /// 购买数量。
    public let purchasedQuantity: Int

    /// 购买时提供的应用账户令牌。
    public let appAccountToken: UUID?

    /// 当前订阅交易是否已被升级交易替代。
    public let isUpgraded: Bool

    /// App Store 签署的原始 JWS。
    ///
    /// - Important: 此值可能包含支付标识信息，不应写入日志。
    public let jwsRepresentation: String

    /// App Store 实际应用到当前交易的优惠。
    public let appliedOffer: PaymentAppliedOffer?

    /// 当前交易使用的订阅账单计划。
    public let billingPlan: PaymentBillingPlan?

    /// 当前交易的月付承诺进度。
    public let commitment: PaymentTransactionCommitment?

    /// 创建已验证交易快照。
    public init(
        id: UInt64,
        originalID: UInt64,
        productID: String,
        subscriptionGroupID: String?,
        productType: PaymentProductType,
        purchaseDate: Date,
        originalPurchaseDate: Date,
        expirationDate: Date?,
        revocationDate: Date?,
        signedDate: Date,
        ownershipType: PaymentOwnershipType,
        purchasedQuantity: Int,
        appAccountToken: UUID?,
        isUpgraded: Bool,
        jwsRepresentation: String,
        appliedOffer: PaymentAppliedOffer? = nil,
        billingPlan: PaymentBillingPlan? = nil,
        commitment: PaymentTransactionCommitment? = nil
    ) {
        self.id = id
        self.originalID = originalID
        self.productID = productID
        self.subscriptionGroupID = subscriptionGroupID
        self.productType = productType
        self.purchaseDate = purchaseDate
        self.originalPurchaseDate = originalPurchaseDate
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.signedDate = signedDate
        self.ownershipType = ownershipType
        self.purchasedQuantity = purchasedQuantity
        self.appAccountToken = appAccountToken
        self.isUpgraded = isUpgraded
        self.jwsRepresentation = jwsRepresentation
        self.appliedOffer = appliedOffer
        self.billingPlan = billingPlan
        self.commitment = commitment
    }
}

extension PaymentTransaction {
    /// 返回仅替换实际优惠元数据的交易快照。
    ///
    /// 可靠交付业务状态不包含优惠字段，因此该补全不会形成新的业务交付。
    internal func replacingAppliedOffer(_ appliedOffer: PaymentAppliedOffer?) -> Self {
        PaymentTransaction(
            id: id,
            originalID: originalID,
            productID: productID,
            subscriptionGroupID: subscriptionGroupID,
            productType: productType,
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
            billingPlan: billingPlan,
            commitment: commitment
        )
    }

    /// 同一次 App Store 签名状态的进程内去重标识。
    internal var signedEventIdentifier: String {
        PaymentSignedEventIdentity.identifier(for: self)
    }

    /// 不受 App Store 重新签名影响的交易业务状态。
    ///
    /// 签名时间和 JWS 不参与比较；撤销、到期、升级和所有权等真实状态变化仍会形成新状态。
    internal var deliveryState: PaymentTransactionDeliveryState {
        PaymentTransactionDeliveryState(
            id: id,
            originalID: originalID,
            productID: productID,
            subscriptionGroupID: subscriptionGroupID,
            productType: productType,
            purchaseDate: purchaseDate,
            originalPurchaseDate: originalPurchaseDate,
            expirationDate: expirationDate,
            revocationDate: revocationDate,
            ownershipType: ownershipType,
            purchasedQuantity: purchasedQuantity,
            appAccountToken: appAccountToken,
            isUpgraded: isUpgraded
        )
    }
}

/// 用于抑制同一交易仅重新签名所产生重复交付的内部状态键。
internal struct PaymentTransactionDeliveryState: Hashable, Sendable {
    let id: UInt64
    let originalID: UInt64
    let productID: String
    let subscriptionGroupID: String?
    let productType: PaymentProductType
    let purchaseDate: Date
    let originalPurchaseDate: Date
    let expirationDate: Date?
    let revocationDate: Date?
    let ownershipType: PaymentOwnershipType
    let purchasedQuantity: Int
    let appAccountToken: UUID?
    let isUpgraded: Bool
}

/// 自动续期订阅当前所处的状态。
public enum PaymentRenewalState: Sendable, Equatable {
    /// 订阅有效。
    case subscribed
    /// 订阅已过期。
    case expired
    /// 订阅处于账单重试期。
    case inBillingRetryPeriod
    /// 订阅处于账单宽限期。
    case inGracePeriod
    /// 订阅已被撤销。
    case revoked
    /// 当前版本尚未识别的状态及其 StoreKit 原始值。
    case unknown(Int)
}

/// 自动续期订阅的到期原因。
public enum PaymentExpirationReason: Sendable, Equatable {
    /// 用户关闭了自动续订。
    case autoRenewDisabled

    /// App Store 无法完成续订扣款。
    case billingError

    /// 用户没有同意订阅价格上涨。
    case didNotConsentToPriceIncrease

    /// 续订商品已不可用。
    case productUnavailable

    /// 当前版本尚未识别的到期原因及其 StoreKit 原始值。
    case unknown(Int)
}

/// 自动续期订阅的价格上涨状态。
public enum PaymentPriceIncreaseStatus: String, Sendable, Equatable {
    /// 当前没有等待处理的价格上涨。
    case noIncreasePending

    /// 价格上涨正在等待用户同意。
    case pending

    /// 用户已经同意价格上涨。
    case agreed

    /// 当前版本尚未识别的价格上涨状态。
    case unknown
}

/// 自动续期订阅在当前承诺结束后的续订安排。
public struct PaymentRenewalCommitment: Sendable, Equatable, Hashable {
    /// 当前承诺结束后首选续订的商品标识符。
    public let autoRenewPreference: String

    /// 下一承诺期限使用的账单计划。
    public let renewalBillingPlan: PaymentBillingPlan

    /// 下一承诺期限开始日期。
    public let renewalDate: Date

    /// 下一承诺期限每个账单周期的价格。
    public let renewalPrice: Decimal

    /// 完整承诺期限结束后是否继续自动续订。
    public let willAutoRenew: Bool

    /// 创建承诺续订安排。
    public init(
        autoRenewPreference: String,
        renewalBillingPlan: PaymentBillingPlan,
        renewalDate: Date,
        renewalPrice: Decimal,
        willAutoRenew: Bool
    ) {
        self.autoRenewPreference = autoRenewPreference
        self.renewalBillingPlan = renewalBillingPlan
        self.renewalDate = renewalDate
        self.renewalPrice = renewalPrice
        self.willAutoRenew = willAutoRenew
    }
}

/// 自动续期订阅的下一次续订信息。
public struct PaymentRenewalInfo: Sendable, Equatable {
    /// 订阅最初购买时的交易标识符。
    public let originalTransactionID: UInt64

    /// 用户当前订阅的商品标识符。
    public let currentProductID: String

    /// 订阅是否会在下一个账单周期自动续订。
    ///
    /// 对月付承诺订阅，此值描述当前承诺内的下一笔月付，不表示当前承诺
    /// 结束后是否开始新的承诺。后一状态应读取 `commitment.willAutoRenew`。
    public let willAutoRenew: Bool

    /// 当前订阅周期结束后将自动续订的商品标识符。
    ///
    /// 继续订阅同一商品时与 `currentProductID` 相同，切换商品时为目标商品，
    /// 不再自动续订时通常为 `nil`。调用方应先检查 `willAutoRenew`，不应仅凭
    /// 此值非空推断订阅一定会续订。
    public let autoRenewPreference: String?

    /// 订阅到期原因；仍有效时通常为 `nil`。
    public let expirationReason: PaymentExpirationReason?

    /// 订阅价格上涨的处理状态。
    public let priceIncreaseStatus: PaymentPriceIncreaseStatus

    /// 订阅当前是否处于账单重试期。
    public let isInBillingRetry: Bool

    /// 账单宽限期结束时间。
    public let gracePeriodExpirationDate: Date?

    /// App Store 预计执行下一次续订的时间。
    public let renewalDate: Date?

    /// 下一次续订价格。
    public let renewalPrice: Decimal?

    /// 下一次续订价格使用的 ISO 4217 货币代码。
    public let currencyCode: String?

    /// App Store 签署的续订信息 JWS。
    ///
    /// - Important: 此值可能包含支付标识信息，不应写入日志。
    public let jwsRepresentation: String

    /// App Store 实际应用到当前续订周期的优惠。
    public let appliedOffer: PaymentAppliedOffer?

    /// 当前账户有资格领取的回归用户优惠标识符。
    ///
    /// App Store 按最优优惠优先排序。此数组只应用于当前续订信息对应的订阅组。
    public let eligibleWinBackOfferIDs: [String]

    /// 下一次续订使用的账单计划。
    public let renewalBillingPlan: PaymentBillingPlan?

    /// 当前承诺结束后的续订安排。
    ///
    /// 此值与 `willAutoRenew` 分属不同层级：`willAutoRenew` 描述当前承诺内
    /// 的下一笔账单，`commitment.willAutoRenew` 描述是否开始新的完整承诺。
    public let commitment: PaymentRenewalCommitment?

    /// 创建订阅续订信息。
    public init(
        originalTransactionID: UInt64,
        currentProductID: String,
        willAutoRenew: Bool,
        autoRenewPreference: String?,
        expirationReason: PaymentExpirationReason?,
        priceIncreaseStatus: PaymentPriceIncreaseStatus,
        isInBillingRetry: Bool,
        gracePeriodExpirationDate: Date?,
        renewalDate: Date?,
        renewalPrice: Decimal?,
        currencyCode: String?,
        jwsRepresentation: String,
        appliedOffer: PaymentAppliedOffer? = nil,
        eligibleWinBackOfferIDs: [String] = [],
        renewalBillingPlan: PaymentBillingPlan? = nil,
        commitment: PaymentRenewalCommitment? = nil
    ) {
        self.originalTransactionID = originalTransactionID
        self.currentProductID = currentProductID
        self.willAutoRenew = willAutoRenew
        self.autoRenewPreference = autoRenewPreference
        self.expirationReason = expirationReason
        self.priceIncreaseStatus = priceIncreaseStatus
        self.isInBillingRetry = isInBillingRetry
        self.gracePeriodExpirationDate = gracePeriodExpirationDate
        self.renewalDate = renewalDate
        self.renewalPrice = renewalPrice
        self.currencyCode = currencyCode
        self.jwsRepresentation = jwsRepresentation
        self.appliedOffer = appliedOffer
        self.eligibleWinBackOfferIDs = eligibleWinBackOfferIDs
        self.renewalBillingPlan = renewalBillingPlan
        self.commitment = commitment
    }
}

extension PaymentRenewalInfo {
    /// 返回仅替换实际优惠元数据的续订信息快照。
    internal func replacingAppliedOffer(_ appliedOffer: PaymentAppliedOffer?) -> Self {
        PaymentRenewalInfo(
            originalTransactionID: originalTransactionID,
            currentProductID: currentProductID,
            willAutoRenew: willAutoRenew,
            autoRenewPreference: autoRenewPreference,
            expirationReason: expirationReason,
            priceIncreaseStatus: priceIncreaseStatus,
            isInBillingRetry: isInBillingRetry,
            gracePeriodExpirationDate: gracePeriodExpirationDate,
            renewalDate: renewalDate,
            renewalPrice: renewalPrice,
            currencyCode: currencyCode,
            jwsRepresentation: jwsRepresentation,
            appliedOffer: appliedOffer,
            eligibleWinBackOfferIDs: eligibleWinBackOfferIDs,
            renewalBillingPlan: renewalBillingPlan,
            commitment: commitment
        )
    }
}

/// 自动续期订阅组的一项状态。
public struct PaymentSubscriptionStatus: Identifiable, Sendable, Equatable {
    /// 由订阅组和原始交易组成的稳定标识符。
    public let id: String

    /// App Store Connect 中的订阅组标识符。
    public let groupID: String

    /// 当前订阅状态。
    public let state: PaymentRenewalState

    /// 通过本地验证的当前订阅交易。
    public let transaction: PaymentTransaction

    /// 通过本地验证的续订信息。
    public let renewalInfo: PaymentRenewalInfo

    /// 创建订阅状态。
    public init(
        groupID: String,
        state: PaymentRenewalState,
        transaction: PaymentTransaction,
        renewalInfo: PaymentRenewalInfo
    ) {
        id = "\(groupID)|\(transaction.originalID)"
        self.groupID = groupID
        self.state = state
        self.transaction = transaction
        self.renewalInfo = renewalInfo
    }
}

/// StoreKit 交易结束操作的当前状态。
public enum PaymentFinishState: Sendable, Equatable {
    /// 已完成 StoreKit `finish()`，交易不会再次出现在未完成交易序列中。
    case finished

    /// 已完成后台交付，但尚未取得可执行 `finish()` 的 StoreKit 原始交易。
    case awaitingStoreKit
}

/// 一笔待处理交易所处的可靠交付阶段。
public enum PaymentPendingState: Sendable, Equatable {
    /// 交易尚未完成处理器交付。
    case awaitingDelivery

    /// 处理器已完成幂等交付，正在等待 StoreKit `finish()`。
    case deliveredAwaitingFinish
}

/// PaymentKit 尚未完成全部可靠交付流程的交易。
public struct PaymentPendingTransaction: Identifiable, Sendable, Equatable {
    /// 由交易签名事件生成的不透明稳定摘要。
    ///
    /// 调用方只能把此值用于 identity，不应解析或持久依赖其具体格式。
    public let id: String

    /// 已通过本地验证的交易快照。
    public let transaction: PaymentTransaction

    /// 当前可靠交付阶段。
    public let state: PaymentPendingState

    /// 创建待处理交易。
    public init(transaction: PaymentTransaction, state: PaymentPendingState) {
        id = transaction.signedEventIdentifier
        self.transaction = transaction
        self.state = state
    }
}

/// 重试未完成交易后的统计报告。
public struct PaymentRetryReport: Sendable, Equatable {
    /// 本次进入处理流程的签名事件数量，包括验签失败事件。
    public let attemptedCount: Int

    /// 本次新完成处理器交付的数量。
    public let deliveredCount: Int

    /// 本次完成 StoreKit `finish()` 的数量。
    public let finishedCount: Int

    /// 已交付但仍等待 StoreKit 原始交易的数量。
    public let awaitingFinishCount: Int

    /// 本次处理失败或验签失败的数量。
    public let failureCount: Int

    /// 旧持久记录无法重建为已验证交易的数量。
    public let unresolvedCount: Int

    /// 重试结束后的 PaymentKit 状态快照。
    public let snapshot: PaymentSnapshot

    /// 创建重试报告。
    public init(
        attemptedCount: Int,
        deliveredCount: Int,
        finishedCount: Int,
        awaitingFinishCount: Int,
        failureCount: Int,
        unresolvedCount: Int,
        snapshot: PaymentSnapshot
    ) {
        self.attemptedCount = attemptedCount
        self.deliveredCount = deliveredCount
        self.finishedCount = finishedCount
        self.awaitingFinishCount = awaitingFinishCount
        self.failureCount = failureCount
        self.unresolvedCount = unresolvedCount
        self.snapshot = snapshot
    }
}

/// PaymentKit 当前持有的只读状态快照。
public struct PaymentSnapshot: Sendable, Equatable {
    /// 当前设备和账户是否允许发起购买。
    public let canMakePayments: Bool

    /// 按配置顺序排列的可用商品。
    public let products: [PaymentProduct]

    /// StoreKit 没有返回的配置商品标识符。
    public let unavailableProductIDs: [String]

    /// StoreKit 当前权益序列中的已验证交易。
    public let currentEntitlements: [PaymentTransaction]

    /// 自动续期订阅组的已验证状态。
    public let subscriptionStatuses: [PaymentSubscriptionStatus]

    /// 尚未完成可靠交付或 StoreKit `finish()` 的已验证交易。
    public let pendingTransactions: [PaymentPendingTransaction]

    /// 创建状态快照。
    public init(
        canMakePayments: Bool = true,
        products: [PaymentProduct] = [],
        unavailableProductIDs: [String] = [],
        currentEntitlements: [PaymentTransaction] = [],
        subscriptionStatuses: [PaymentSubscriptionStatus] = [],
        pendingTransactions: [PaymentPendingTransaction] = []
    ) {
        self.canMakePayments = canMakePayments
        self.products = products
        self.unavailableProductIDs = unavailableProductIDs
        self.currentEntitlements = currentEntitlements
        self.subscriptionStatuses = subscriptionStatuses
        self.pendingTransactions = pendingTransactions
    }

    /// 尚未加载 App Store 数据的空快照。
    public static let empty = PaymentSnapshot()
}

/// 一次购买请求的最终状态。
public enum PurchaseOutcome: Sendable, Equatable {
    /// 交易已验证、交付并结束。
    case completed(PaymentTransaction)
    /// 交易需要外部批准或其他用户操作。
    case pending
    /// 用户取消购买。
    case cancelled
}

/// 系统退款请求界面的结果。
public enum PaymentRefundOutcome: Sendable, Equatable {
    /// 用户已向 App Store 提交退款请求。
    case submitted

    /// 用户取消退款请求。
    case cancelled
}

/// PaymentKit 错误代码。
public enum PaymentErrorCode: String, Sendable, Equatable {
    /// 支付配置不符合当前操作要求。
    case invalidConfiguration

    /// 当前购买选项不适用于目标商品或格式无效。
    case invalidPurchaseOptions

    /// 当前系统版本不支持请求的 StoreKit 功能。
    case unsupportedFeature

    /// 目标商品没有配置请求的优惠。
    case offerNotFound

    /// 当前 Apple 账户不满足请求优惠的 App Store 资格。
    case offerNotEligible

    /// 服务端签发的优惠授权格式无效。
    case offerAuthorizationInvalid

    /// 目标商品没有提供请求的账单计划。
    case billingPlanUnavailable

    /// 购买数量无效。
    case invalidQuantity

    /// 商品尚未加载或 StoreKit 没有返回该商品。
    case productNotFound

    /// 当前设备或账户不允许发起购买。
    case purchasesNotAllowed

    /// StoreKit 返回的数据没有通过本地验证。
    case verificationFailed

    /// StoreKit 操作失败。
    case storeKitFailed

    /// 注入的交易处理器没有完成可靠交付。
    case processingFailed

    /// 可靠交付状态无法安全写入持久存储。
    case persistenceFailed

    /// 持久记录无法恢复为可处理的已验证交易。
    case recoveryFailed

    /// 当前平台没有可用于展示系统界面的场景或控制器。
    case presentationUnavailable
}

/// PaymentKit 返回的稳定错误信息。
public struct PaymentError: Error, LocalizedError, Sendable, Equatable {
    /// 稳定的错误代码。
    public let code: PaymentErrorCode

    /// 可用于诊断和展示的错误消息。
    public let message: String

    /// 与错误关联的商品标识符。
    public let productID: String?

    /// 与错误关联的交易标识符。
    public let transactionID: UInt64?

    /// 创建 PaymentKit 错误。
    public init(
        code: PaymentErrorCode,
        message: String,
        productID: String? = nil,
        transactionID: UInt64? = nil
    ) {
        self.code = code
        self.message = message
        self.productID = productID
        self.transactionID = transactionID
    }

    /// `LocalizedError` 使用的本地化描述。
    public var errorDescription: String? { message }
}

/// PaymentKit 生命周期产生的观察事件。
///
/// - Important: 事件仅用于更新界面与诊断，不承担可靠的商品交付职责。
public enum PaymentEvent: Sendable, Equatable {
    /// 客户端生成了新的只读状态快照。
    case snapshotUpdated(PaymentSnapshot)

    /// 指定商品的购买正在等待外部批准。
    case purchasePending(productID: String)

    /// 交易已经通过处理器交付，并报告 StoreKit 结束状态。
    case transactionDelivered(PaymentTransaction, finishState: PaymentFinishState)

    /// 交易处理失败并保持未完成。
    case transactionProcessingFailed(transaction: PaymentTransaction, error: PaymentError)

    /// StoreKit 数据没有通过本地验证。
    case verificationFailed(transactionID: UInt64?, message: String)

    /// 用户发起的恢复流程已经完成。
    case restoreCompleted(PaymentSnapshot)
}
