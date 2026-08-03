import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 自动刷新请求需要覆盖的状态范围。
enum PaymentAutomaticRefreshStrength: Sendable {
    /// 仅刷新权益、未完成交易、订阅状态和支付能力。
    case state

    /// 重新加载商品后刷新全部支付状态。
    case full

    /// 将另一请求合并到当前范围，完整刷新始终覆盖轻量刷新。
    ///
    /// - Parameter other: 需要合并的刷新范围。
    /// - Returns: 同时满足两个请求的最小刷新范围。
    func merging(_ other: PaymentAutomaticRefreshStrength) -> Self {
        switch (self, other) {
        case (.full, _), (_, .full):
            return .full
        case (.state, .state):
            return .state
        }
    }

    /// 用于脱敏结构化日志的固定名称。
    var logName: String {
        switch self {
        case .state:
            return "state"
        case .full:
            return "full"
        }
    }
}

/// 将应用激活通知转换为可注入的异步事件流。
struct PaymentApplicationActivitySource: Sendable {
    private let eventProvider: @Sendable () async -> AsyncStream<Void>

    /// 创建应用活动事件源。
    ///
    /// - Parameter eventProvider: 返回当前监听周期事件流的闭包。
    init(
        _ eventProvider: @escaping @Sendable () async -> AsyncStream<Void>
    ) {
        self.eventProvider = eventProvider
    }

    /// 返回新的应用激活事件流。
    func events() async -> AsyncStream<Void> {
        await eventProvider()
    }

    /// 使用当前平台的应用激活通知创建事件源。
    static var system: PaymentApplicationActivitySource {
        PaymentApplicationActivitySource {
            #if os(iOS)
            let name = UIApplication.didBecomeActiveNotification
            #elseif os(macOS)
            let name = NSApplication.didBecomeActiveNotification
            #else
            return AsyncStream<Void> { $0.finish() }
            #endif

            return AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) {
                continuation in
                let observer = PaymentApplicationActivityObserver(
                    name: name,
                    continuation: continuation
                )
                continuation.onTermination = { _ in
                    observer.invalidate()
                }
            }
        }
    }
}

/// 持有 NotificationCenter observer，并允许并发取消时安全清理。
private final class PaymentApplicationActivityObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter
    private var token: (any NSObjectProtocol)?

    init(
        center: NotificationCenter = .default,
        name: Notification.Name,
        continuation: AsyncStream<Void>.Continuation
    ) {
        self.center = center
        token = center.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { _ in
            continuation.yield()
        }
    }

    func invalidate() {
        let token = lock.withLock {
            let token = self.token
            self.token = nil
            return token
        }
        if let token {
            center.removeObserver(token)
        }
    }

    deinit {
        invalidate()
    }
}

/// 从订阅状态中选择下一次需要自动刷新的时间边界。
enum PaymentAutomaticRefreshDeadline {
    /// 返回快照中严格晚于指定时间的最近订阅边界。
    ///
    /// - Parameters:
    ///   - snapshot: 包含已验证订阅状态的支付快照。
    ///   - now: 用于排除已过去或恰好到达的边界的当前时间。
    /// - Returns: 最近的未来边界；快照没有订阅状态或未来边界时返回 `nil`。
    static func next(in snapshot: PaymentSnapshot, after now: Date) -> Date? {
        nextTarget(in: snapshot, after: now)?.key.date
    }

    /// 返回严格晚于指定时间的最近订阅边界目标。
    static func nextTarget(
        in snapshot: PaymentSnapshot,
        after now: Date
    ) -> PaymentAutomaticRefreshBoundaryState? {
        targets(in: snapshot)
            .filter { $0.key.date > now }
            .min(by: isOrderedBefore)
    }

    /// 返回已经到达但订阅状态仍未收敛的最近目标边界。
    ///
    /// 有效订阅跨过到期、续订或承诺边界，以及宽限期跨过结束边界时，
    /// StoreKit 可能短暂返回旧状态。已过期、账单重试或已撤销状态不会被误判为陈旧。
    ///
    /// - Parameters:
    ///   - snapshot: 刚刚提交的支付快照。
    ///   - now: 用于判断边界是否已经到达的当前时间。
    ///   - exhaustedTargets: 当前生命周期已经耗尽有限重试的目标。
    /// - Returns: 最近的陈旧目标；状态已经收敛时返回 `nil`。
    static func unconvergedTarget(
        in snapshot: PaymentSnapshot,
        at now: Date,
        excluding exhaustedTargets: [PaymentAutomaticRefreshBoundaryState]
    ) -> PaymentAutomaticRefreshBoundaryState? {
        targets(in: snapshot)
            .filter { target in
                target.key.date <= now
                    && isUnconverged(target)
                    && !exhaustedTargets.contains(target)
            }
            .max(by: isOrderedBefore)
    }

    /// 返回快照中的全部归一化订阅边界目标。
    ///
    /// 目标只包含稳定订阅标识、实际日期、续订状态和必要收敛语义；
    /// 同日的边界种类、其他日期、签名内容、签名时间和数组顺序不会重置退避进度。
    static func targets(
        in snapshot: PaymentSnapshot
    ) -> [PaymentAutomaticRefreshBoundaryState] {
        snapshot.subscriptionStatuses.flatMap { status in
            let groupedBoundaries = Dictionary(
                grouping: boundaries(in: status),
                by: \.date
            )
            return groupedBoundaries.map { date, boundaries in
                let kinds = Set(boundaries.map(\.kind))
                return PaymentAutomaticRefreshBoundaryState(
                    key: PaymentAutomaticRefreshBoundaryKey(
                        id: status.id,
                        date: date
                    ),
                    state: status.state,
                    convergence: convergence(
                        for: status.state,
                        boundaryKinds: kinds
                    )
                )
            }
        }
    }

    /// 返回与指定稳定边界键匹配的当前目标状态。
    static func target(
        matching key: PaymentAutomaticRefreshBoundaryKey,
        in snapshot: PaymentSnapshot
    ) -> PaymentAutomaticRefreshBoundaryState? {
        targets(in: snapshot).first { $0.key == key }
    }

    private static func boundaries(
        in status: PaymentSubscriptionStatus
    ) -> [(kind: PaymentAutomaticRefreshBoundaryKind, date: Date)] {
        // StoreKit 的四类订阅时间都可能触发状态收敛。
        [
            status.transaction.expirationDate.map {
                (.expiration, $0)
            },
            status.renewalInfo.renewalDate.map {
                (.renewal, $0)
            },
            status.renewalInfo.gracePeriodExpirationDate.map {
                (.gracePeriodExpiration, $0)
            },
            (status.renewalInfo.commitment?.renewalDate).map {
                (.commitmentRenewal, $0)
            },
        ].compactMap { $0 }
    }

    private static func isUnconverged(
        _ target: PaymentAutomaticRefreshBoundaryState
    ) -> Bool {
        target.convergence != .none
    }

    private static func convergence(
        for state: PaymentRenewalState,
        boundaryKinds: Set<PaymentAutomaticRefreshBoundaryKind>
    ) -> PaymentAutomaticRefreshBoundaryConvergence {
        switch state {
        case .subscribed:
            if boundaryKinds.contains(.expiration)
                || boundaryKinds.contains(.renewal)
                || boundaryKinds.contains(.commitmentRenewal) {
                return .subscribed
            }
        case .inGracePeriod:
            if boundaryKinds.contains(.gracePeriodExpiration) {
                return .gracePeriod
            }
        case .expired, .inBillingRetryPeriod, .revoked, .unknown:
            break
        }
        return .none
    }

    private static func isOrderedBefore(
        _ lhs: PaymentAutomaticRefreshBoundaryState,
        _ rhs: PaymentAutomaticRefreshBoundaryState
    ) -> Bool {
        if lhs.key.date != rhs.key.date {
            return lhs.key.date < rhs.key.date
        }
        if lhs.key.id != rhs.key.id {
            return lhs.key.id < rhs.key.id
        }
        return false
    }
}

/// 订阅时间边界的种类。
enum PaymentAutomaticRefreshBoundaryKind: Sendable, Hashable {
    case expiration
    case renewal
    case gracePeriodExpiration
    case commitmentRenewal
}

/// 一个订阅时间边界的稳定键。
struct PaymentAutomaticRefreshBoundaryKey: Sendable, Hashable {
    /// 订阅组和原始交易组成的稳定标识符。
    let id: String

    /// 当前收敛目标的精确日期。
    let date: Date
}

/// 一个实际边界组在当前续订状态下需要使用的收敛语义。
enum PaymentAutomaticRefreshBoundaryConvergence: Sendable, Equatable {
    case subscribed
    case gracePeriod
    case none
}

/// 用于时间边界收敛判断的稳定目标状态。
struct PaymentAutomaticRefreshBoundaryState: Sendable, Equatable {
    /// 目标订阅和实际日期组成的稳定键。
    let key: PaymentAutomaticRefreshBoundaryKey

    /// 目标边界触发前的续订状态。
    let state: PaymentRenewalState

    /// 当前状态下用于判断边界是否仍未收敛的归一化语义。
    let convergence: PaymentAutomaticRefreshBoundaryConvergence
}

/// 一次订阅时间边界刷新需要保留的收敛上下文。
struct PaymentAutomaticRefreshBoundaryContext: Sendable {
    /// 触发本轮刷新的归一化目标。
    let target: PaymentAutomaticRefreshBoundaryState

    /// 下一次可使用的固定重试延迟索引。
    let nextRetryDelayIndex: Int
}

/// StoreKit 在订阅边界后仍返回旧状态时使用的有限重试序列。
enum PaymentAutomaticRefreshBoundaryRetry {
    /// 最多四次收敛重试，避免将边界刷新退化为永久轮询。
    static let delays: [TimeInterval] = [1, 2, 5, 15]
}

/// 自动刷新使用的可注入时钟。
///
/// 测试可提供确定性的当前时间和睡眠实现，避免依赖真实时间流逝。
struct PaymentAutomaticRefreshClock: Sendable {
    /// 返回当前时间。
    let now: @Sendable () -> Date

    /// 挂起至给定截止时间；调用方取消任务时会向上传播取消错误。
    let sleep: @Sendable (Date) async throws -> Void

    /// 按严格截止时间挂起收敛重试，不附加首次边界使用的容差。
    let retrySleep: @Sendable (Date) async throws -> Void

    /// 创建自动刷新时钟。
    ///
    /// 默认睡眠会在截止时间后额外等待一秒，为 StoreKit 状态收敛保留容差。
    /// - Parameters:
    ///   - now: 返回当前时间的闭包。
    ///   - sleep: 挂起至截止时间的闭包。
    ///   - retrySleep: 按严格截止时间挂起收敛重试的闭包。
    init(
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Date) async throws -> Void = { deadline in
            try await sleepUntilAutomaticRefreshDeadline(
                deadline,
                tolerance: 1
            )
        },
        retrySleep: @escaping @Sendable (Date) async throws -> Void = { deadline in
            try await sleepUntilAutomaticRefreshDeadline(
                deadline,
                tolerance: 0
            )
        }
    ) {
        self.now = now
        self.sleep = sleep
        self.retrySleep = retrySleep
    }
}

/// 使用 iOS 15 可用的纳秒接口挂起至自动刷新截止时间。
private func sleepUntilAutomaticRefreshDeadline(
    _ deadline: Date,
    tolerance: TimeInterval
) async throws {
    let delay = deadline.timeIntervalSinceNow + tolerance
    guard delay > 0 else { return }

    // 先限制上界，避免 Double 转换溢出。
    let maximumNanoseconds = UInt64.max
    let maximumDelay = TimeInterval(maximumNanoseconds / 1_000_000_000)
    let nanoseconds = delay >= maximumDelay
        ? maximumNanoseconds
        : UInt64(delay * 1_000_000_000)
    try await Task.sleep(nanoseconds: nanoseconds)
}
