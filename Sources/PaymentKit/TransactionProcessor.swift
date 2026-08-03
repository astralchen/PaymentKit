/// 处理已通过 StoreKit 本地验证的交易。
///
/// 生产应用通常在实现中把交易 JWS 发送到自己的后台进行独立验签和幂等交付。
public protocol TransactionProcessor: Sendable {
    /// 处理一笔已验证交易。
    ///
    /// 正常返回表示交易已经安全交付，PaymentKit 随后可以结束交易。抛出错误时，
    /// PaymentKit 会在受保护的 outbox 中保留未完成交易，以便下次启动或显式重试。
    /// StoreKit 可能使用不同 JWS 和签名时间重新签署同一交易业务状态；处理器不应
    /// 仅以 JWS 摘要作为业务交付幂等键，同时必须允许撤销等真实状态变化再次处理。
    ///
    /// - Parameter transaction: 已通过 StoreKit 本地验证的交易快照。
    /// - Throws: 后台验签、持久化或交付失败时产生的错误。
    func process(_ transaction: PaymentTransaction) async throws
}
