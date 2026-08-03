/// App Store 商品的类型。
public enum PaymentProductType: Sendable, Equatable, Hashable {
    /// 消耗型商品。
    case consumable

    /// 非消耗型商品。
    case nonConsumable

    /// 非续期订阅。
    case nonRenewingSubscription

    /// 自动续期订阅。
    case autoRenewableSubscription

    /// 当前版本尚未识别的商品类型。
    case unknown(String)

    /// 根据持久化的原始值创建商品类型。
    ///
    /// 未识别的值会被完整保留，便于兼容未来 StoreKit 新增的商品类型。
    ///
    /// - Parameter rawValue: 商品类型的原始字符串。
    public init(rawValue: String) {
        switch rawValue {
        case "consumable": self = .consumable
        case "nonConsumable": self = .nonConsumable
        case "nonRenewingSubscription": self = .nonRenewingSubscription
        case "autoRenewableSubscription": self = .autoRenewableSubscription
        default: self = .unknown(rawValue)
        }
    }

    /// 可用于持久化或诊断的原始值。
    public var rawValue: String {
        switch self {
        case .consumable: "consumable"
        case .nonConsumable: "nonConsumable"
        case .nonRenewingSubscription: "nonRenewingSubscription"
        case .autoRenewableSubscription: "autoRenewableSubscription"
        case .unknown(let rawValue): rawValue
        }
    }
}
