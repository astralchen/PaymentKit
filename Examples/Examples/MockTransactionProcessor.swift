import Foundation
import PaymentKit

/// 模拟后台的故障模式。
nonisolated enum MockBackendFaultMode: String, CaseIterable, Identifiable, Sendable {
    /// 请求按正常路径完成。
    case normal

    /// 模拟设备或后台不可联网。
    case offline

    /// 模拟请求超过客户端超时限制。
    case timeout

    /// 模拟后台拒绝当前请求。
    case clientError

    /// 模拟后台暂时不可用。
    case serverError

    /// 后台已幂等提交，但响应在到达应用前断开。
    case successThenDisconnect

    var id: String { rawValue }
}

/// 模拟后台处理结果。
nonisolated enum MockBackendResult: String, Sendable {
    /// 首次接收并完成幂等处理。
    case processed

    /// 签名事件或等价业务状态已经处理过。
    case duplicate

    /// 模拟后台处于离线状态。
    case offline

    /// 模拟请求超时。
    case timeout

    /// 模拟请求被后台拒绝。
    case clientError

    /// 模拟后台暂时不可用。
    case serverError

    /// 后台已提交结果，但连接在响应前断开。
    case successThenDisconnected

    /// 共享 SQLite 幂等账本失败关闭。
    case persistenceFailed
}

/// 模拟后台的一条非敏感处理记录。
nonisolated struct MockBackendRecord: Identifiable, Sendable {
    /// 记录标识符。
    let id = UUID()

    /// 记录产生时间。
    let date: Date

    /// 交易对应的商品标识符。
    let productID: String

    /// 用于诊断的交易标识符后六位。
    let transactionSuffix: String

    /// 模拟处理结果。
    let result: MockBackendResult
}

/// 模拟后台的只读状态。
nonisolated struct MockBackendSnapshot: Sendable {
    /// 后台当前是否具备网络连接。
    let isOnline: Bool

    /// 当前故障注入模式。
    let faultMode: MockBackendFaultMode

    /// 模拟的网络延迟，单位为毫秒。
    let latencyMilliseconds: UInt64

    /// 共享账本记录的签名事件数量。
    let signedEventCount: Int

    /// 共享账本记录的业务交付数量。
    let businessDeliveryCount: Int

    /// 当前进程最近的处理记录。
    let records: [MockBackendRecord]
}

/// 模拟生产后台验签和跨进程幂等交付的交易处理器。
///
/// 主 App 与 Share Extension 通过同一个 App Group SQLite 账本原子判断首次交付。
/// 该处理器不计算金币、会员等级或任何业务权益。
actor MockTransactionProcessor: TransactionProcessor {
    private let latencyMilliseconds: UInt64
    private let ledger: SharedMockBackendLedger
    private var faultMode: MockBackendFaultMode = .normal
    private var lastStatistics = SharedMockBackendStatistics(
        signedEventCount: 0,
        businessDeliveryCount: 0
    )
    private var records: [MockBackendRecord] = []

    /// 创建模拟交易处理器。
    ///
    /// - Parameters:
    ///   - latencyMilliseconds: 每次请求模拟的基础网络延迟。
    ///   - databaseURL: 主 App 与扩展共用的 SQLite 账本地址。
    init(latencyMilliseconds: UInt64 = 350, databaseURL: URL) {
        self.latencyMilliseconds = latencyMilliseconds
        ledger = SharedMockBackendLedger(databaseURL: databaseURL)
    }

    /// 设置模拟后台的联网状态。
    ///
    /// - Parameter isOnline: `true` 恢复正常模式，`false` 切换为离线模式。
    func setOnline(_ isOnline: Bool) {
        faultMode = isOnline ? .normal : .offline
    }

    /// 设置下一阶段请求使用的故障模式。
    ///
    /// - Parameter mode: 新的故障注入模式。
    func setFaultMode(_ mode: MockBackendFaultMode) {
        faultMode = mode
    }

    /// 返回模拟后台当前状态。
    func snapshot() async -> MockBackendSnapshot {
        if let statistics = try? await ledger.statistics() {
            lastStatistics = statistics
        }
        return MockBackendSnapshot(
            isOnline: faultMode != .offline,
            faultMode: faultMode,
            latencyMilliseconds: latencyMilliseconds,
            signedEventCount: lastStatistics.signedEventCount,
            businessDeliveryCount: lastStatistics.businessDeliveryCount,
            records: records
        )
    }

    /// 模拟接收 JWS、独立验签及共享幂等交付。
    ///
    /// - Parameter transaction: 已通过 StoreKit 本地验证的交易。
    /// - Throws: 当前故障模式或共享幂等账本持久化失败时产生的模拟错误。
    func process(_ transaction: PaymentTransaction) async throws {
        // 延迟发生在状态判断之前，用于覆盖请求期间网络状态发生变化的情况。
        try await Task.sleep(nanoseconds: latencyMilliseconds * 1_000_000)

        switch faultMode {
        case .offline:
            appendRecord(for: transaction, result: .offline)
            throw MockBackendError.offline
        case .timeout:
            try await Task.sleep(nanoseconds: 2_000_000_000)
            appendRecord(for: transaction, result: .timeout)
            throw MockBackendError.timeout
        case .clientError:
            appendRecord(for: transaction, result: .clientError)
            throw MockBackendError.clientError
        case .serverError:
            appendRecord(for: transaction, result: .serverError)
            throw MockBackendError.serverError
        case .normal, .successThenDisconnect:
            break
        }

        let acceptance: SharedMockBackendAcceptance
        do {
            // 只有共享账本事务提交成功后，模拟后台才对外报告交付成功。
            acceptance = try await ledger.accept(transaction)
            lastStatistics = try await ledger.statistics()
        } catch {
            appendRecord(for: transaction, result: .persistenceFailed)
            throw MockBackendError.persistenceFailed
        }

        if acceptance == .duplicate {
            appendRecord(for: transaction, result: .duplicate)
            return
        }
        if faultMode == .successThenDisconnect {
            appendRecord(for: transaction, result: .successThenDisconnected)
            throw MockBackendError.connectionLostAfterSuccess
        }
        appendRecord(for: transaction, result: .processed)
    }

    private func appendRecord(
        for transaction: PaymentTransaction,
        result: MockBackendResult
    ) {
        records.insert(
            MockBackendRecord(
                date: Date(),
                productID: transaction.productID,
                transactionSuffix: String(String(transaction.id).suffix(6)),
                result: result
            ),
            at: 0
        )
        records = Array(records.prefix(50))
    }
}

/// 模拟后台错误。
nonisolated enum MockBackendError: LocalizedError {
    /// 模拟后台离线。
    case offline

    /// 模拟请求超时。
    case timeout

    /// 模拟后台返回 4xx。
    case clientError

    /// 模拟后台返回 5xx。
    case serverError

    /// 模拟后台成功后连接断开。
    case connectionLostAfterSuccess

    /// 模拟幂等账本无法可靠落盘。
    case persistenceFailed

    /// 面向示例界面的错误描述。
    var errorDescription: String? {
        switch self {
        case .offline:
            "模拟后台离线，交易保留为待交付"
        case .timeout:
            "模拟后台请求超时，交易保留为待交付"
        case .clientError:
            "模拟后台返回 4xx，交易保留为待交付"
        case .serverError:
            "模拟后台返回 5xx，交易保留为待交付"
        case .connectionLostAfterSuccess:
            "模拟后台已提交但响应断开；重试将验证幂等"
        case .persistenceFailed:
            "共享模拟后台幂等账本写入失败"
        }
    }
}
