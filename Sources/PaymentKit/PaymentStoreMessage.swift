import Foundation

/// App Store 需要应用决定展示时机的系统消息原因。
public enum PaymentStoreMessageReason: Sendable, Equatable, Hashable {
    /// 通用 App Store 消息。
    case generic

    /// 订阅价格上涨需要用户同意。
    case priceIncreaseConsent

    /// 订阅存在账单问题。
    case billingIssue

    /// App Store 提供回归用户优惠。
    case winBack

    /// 当前版本尚未识别的 StoreKit 原始值。
    case unknown(Int)
}

/// 由调用方明确订阅并负责展示的 App Store 系统消息。
public struct PaymentStoreMessage: Identifiable, Sendable, Equatable {
    /// 当前消息在进程内的唯一标识符。
    public let id: UUID

    /// 消息原因。
    public let reason: PaymentStoreMessageReason

    /// StoreKit 原始消息的类型擦除值。
    ///
    /// 该值只在框架内部用于系统展示，不出现在日志、事件或持久存储中。
    internal let rawValue: (any Sendable)?

    /// 创建不含 StoreKit 原始值的消息快照。
    ///
    /// 此初始化方法主要用于界面状态和测试。只有 `storeMessages()` 返回且包含
    /// StoreKit 原始值的消息才能交给系统展示入口。
    public init(id: UUID = UUID(), reason: PaymentStoreMessageReason) {
        self.id = id
        self.reason = reason
        rawValue = nil
    }

    /// 创建包含 StoreKit 原始值的内部消息。
    internal init(
        id: UUID = UUID(),
        reason: PaymentStoreMessageReason,
        rawValue: any Sendable
    ) {
        self.id = id
        self.reason = reason
        self.rawValue = rawValue
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.reason == rhs.reason
    }
}
