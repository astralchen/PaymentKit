import Foundation
import OSLog

/// PaymentKit 日志的严重级别。
public enum PaymentLogLevel: String, Sendable, Equatable {
    /// 用于开发阶段排查问题的详细信息。
    case debug

    /// 正常生命周期信息。
    case info

    /// 可恢复但需要关注的异常状态。
    case warning

    /// 导致当前操作失败的错误。
    case error
}

/// PaymentKit 生成的一条结构化日志。
public struct PaymentLogEntry: Sendable, Equatable {
    /// 日志严重级别。
    public let level: PaymentLogLevel

    /// 日志所属的技术类别。
    public let category: String

    /// 不包含敏感支付载荷的日志消息。
    public let message: String

    /// 可用于筛选和诊断的非敏感元数据。
    public let metadata: [String: String]

    /// 创建一条结构化日志。
    ///
    /// - Parameters:
    ///   - level: 日志严重级别。
    ///   - category: 日志类别。
    ///   - message: 日志消息。
    ///   - metadata: 非敏感元数据。
    public init(
        level: PaymentLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}

/// 接收 PaymentKit 结构化日志的处理器。
public protocol PaymentLogHandler: Sendable {
    /// 记录一条日志。
    ///
    /// - Parameter entry: PaymentKit 生成的结构化日志。
    func log(_ entry: PaymentLogEntry)
}

/// 使用统一日志系统输出 PaymentKit 日志的默认处理器。
public struct OSPaymentLogHandler: PaymentLogHandler {
    private let logger: Logger

    /// 创建统一日志处理器。
    ///
    /// - Parameters:
    ///   - subsystem: 日志子系统。默认使用主 Bundle 标识符。
    ///   - category: 统一日志类别。
    public init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "PaymentKit",
        category: String = "PaymentKit"
    ) {
        logger = Logger(subsystem: subsystem, category: category)
    }

    /// 将结构化日志写入统一日志系统。
    ///
    /// - Parameter entry: PaymentKit 生成的结构化日志。
    public func log(_ entry: PaymentLogEntry) {
        let metadata = entry.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let text = metadata.isEmpty
            ? "[\(entry.category)] \(entry.message)"
            : "[\(entry.category)] \(entry.message) \(metadata)"

        switch entry.level {
        case .debug:
            logger.debug("\(text, privacy: .public)")
        case .info:
            logger.info("\(text, privacy: .public)")
        case .warning:
            logger.warning("\(text, privacy: .public)")
        case .error:
            logger.error("\(text, privacy: .public)")
        }
    }
}

/// 忽略全部日志的处理器。
public struct DisabledPaymentLogHandler: PaymentLogHandler {
    /// 创建关闭的日志处理器。
    public init() {}

    /// 忽略指定日志。
    ///
    /// - Parameter entry: 被忽略的日志。
    public func log(_ entry: PaymentLogEntry) {}
}
