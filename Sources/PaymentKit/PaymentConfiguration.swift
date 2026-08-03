import Foundation

/// PaymentKit 使用的商品配置。
///
/// 配置只描述需要从 App Store 加载的商品标识符，不包含商品排序以外的业务规则。
public struct PaymentConfiguration: Sendable, Equatable {
    /// 按调用方输入顺序排列的唯一商品标识符。
    public let productIDs: [String]

    /// 创建支付配置。
    ///
    /// 重复标识符会保留第一次出现的位置，后续重复项会被移除。
    ///
    /// - Parameter productIDs: 在 App Store Connect 或 StoreKit 配置文件中定义的商品标识符。
    public init(productIDs: [String]) {
        var seen = Set<String>()
        self.productIDs = productIDs.filter { seen.insert($0).inserted }
    }
}

/// 由生产后台签发的首购优惠资格声明。
///
/// PaymentKit 将 compact JWS 作为敏感不透明值直接交给 StoreKit，不解析负载，
/// 也不替代 App Store 验证后台签名。
public struct PaymentIntroductoryOfferEligibility:
    Sendable,
    Equatable,
    CustomDebugStringConvertible
{
    /// 仅供 PaymentKit 的 StoreKit 适配层读取。
    ///
    /// 此值不能进入日志、事件或可靠交付持久记录。
    internal let compactJWS: String

    /// 创建由生产后台签发的首购优惠资格声明。
    ///
    /// 格式和目标商品校验会在购买前执行。签名真实性由 StoreKit 验证。
    ///
    /// - Parameter compactJWS: 使用 compact serialization 的完整 JWS。
    public init(compactJWS: String) {
        self.compactJWS = compactJWS
    }

    /// 返回不包含敏感资格声明的调试描述。
    public var debugDescription: String {
        "<PaymentIntroductoryOfferEligibility: redacted>"
    }
}

/// 由生产后台签发的促销优惠授权。
///
/// PaymentKit 不解析 compact JWS，也不决定用户是否满足业务促销条件。
/// 调用方应从可信后台取得声明，并在一次购买请求内直接传给 StoreKit。
public struct PaymentPromotionalOfferAuthorization:
    Sendable,
    Equatable,
    CustomDebugStringConvertible
{
    /// App Store Connect 中配置的促销优惠标识符。
    public let offerID: String

    /// 仅供 PaymentKit 的 StoreKit 适配层读取。
    ///
    /// 此值不能进入日志、事件或可靠交付持久记录。
    internal let compactJWS: String

    /// 创建促销优惠授权。
    ///
    /// - Parameters:
    ///   - offerID: App Store Connect 中配置的促销优惠标识符。
    ///   - compactJWS: 使用 compact serialization 的完整 JWS。
    public init(offerID: String, compactJWS: String) {
        self.offerID = offerID
        self.compactJWS = compactJWS
    }

    /// 返回不包含敏感促销声明的调试描述。
    public var debugDescription: String {
        "<PaymentPromotionalOfferAuthorization offerID=\(offerID) authorization=redacted>"
    }
}

/// 自动续期订阅使用的账单计划。
public enum PaymentBillingPlan: Sendable, Equatable, Hashable {
    /// 在订阅周期开始时一次性支付完整周期价格。
    case upFront

    /// 按月支付，并承诺完成整个订阅期限。
    case monthlyCommitment

    /// 当前版本尚未识别的 StoreKit 原始值。
    case unknown(String)
}

extension PaymentBillingPlan {
    /// 当前框架能否将账单计划映射为 StoreKit 购买选项。
    internal var isKnown: Bool {
        switch self {
        case .upFront, .monthlyCommitment:
            true
        case .unknown:
            false
        }
    }
}

/// 一次购买明确选择的订阅优惠。
///
/// 枚举保证一次购买最多选择一种优惠。优惠代码由 App Store 系统兑换页处理，
/// 不作为普通生产购买选项。
public enum PaymentPurchaseOffer: Sendable, Equatable {
    /// 使用首购优惠。
    ///
    /// `eligibility` 为 `nil` 时，StoreKit 使用当前 Apple 账户历史判断资格。
    case introductory(eligibility: PaymentIntroductoryOfferEligibility?)

    /// 使用生产后台签发的促销优惠。
    case promotional(authorization: PaymentPromotionalOfferAuthorization)

    /// 使用 App Store 判定当前账户有资格领取的回归用户优惠。
    case winBack(offerID: String)
}

/// 一次购买请求使用的可选参数。
public struct PurchaseOptions: Sendable, Equatable {
    /// 购买数量。
    ///
    /// - Important: 大于 `1` 的数量只适用于支持数量购买的商品。
    public let quantity: Int

    /// 将 App Store 交易关联到应用账户的令牌。
    public let appAccountToken: UUID?

    /// 是否在 sandbox 环境中模拟“购买前询问”。
    public let simulatesAskToBuyInSandbox: Bool

    /// 自动续期订阅使用的账单计划。
    public let billingPlan: PaymentBillingPlan?

    /// 本次购买明确选择的单一优惠。
    public let offer: PaymentPurchaseOffer?

    /// 创建购买选项。
    ///
    /// - Parameters:
    ///   - quantity: 购买数量，默认为 `1`。
    ///   - appAccountToken: 应用账户令牌，默认为 `nil`。
    ///   - simulatesAskToBuyInSandbox: 是否模拟“购买前询问”，默认为 `false`。
    ///   - billingPlan: 订阅账单计划；`nil` 表示 StoreKit 默认计划。
    ///   - offer: 本次购买明确选择的单一优惠。
    public init(
        quantity: Int = 1,
        appAccountToken: UUID? = nil,
        simulatesAskToBuyInSandbox: Bool = false,
        billingPlan: PaymentBillingPlan? = nil,
        offer: PaymentPurchaseOffer? = nil
    ) {
        self.quantity = quantity
        self.appAccountToken = appAccountToken
        self.simulatesAskToBuyInSandbox = simulatesAskToBuyInSandbox
        self.billingPlan = billingPlan
        self.offer = offer
    }
}

extension PurchaseOptions {
    /// 返回购买请求中携带的服务端首购资格声明。
    internal var introductoryOfferEligibility: PaymentIntroductoryOfferEligibility? {
        guard case .introductory(let eligibility) = offer else { return nil }
        return eligibility
    }
}
