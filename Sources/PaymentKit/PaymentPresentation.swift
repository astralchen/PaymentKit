import StoreKit

#if os(iOS)
import UIKit

/// 展示 StoreKit 系统支付管理界面的入口。
public enum PaymentPresentation {
    /// 展示指定交易的系统退款请求界面。
    ///
    /// - Parameters:
    ///   - transactionID: 需要申请退款的交易标识符。
    ///   - scene: 承载系统退款界面的窗口场景。
    ///   - logger: 结构化日志处理器。
    /// - Returns: 退款请求已提交或用户取消。
    /// - Throws: 系统无法展示或提交退款请求时产生的错误。
    @MainActor
    public static func beginRefund(
        for transactionID: UInt64,
        in scene: UIWindowScene,
        logger: any PaymentLogHandler = OSPaymentLogHandler()
    ) async throws -> PaymentRefundOutcome {
        logger.log(
            PaymentLogEntry(
                level: .info,
                category: "refund",
                message: "开始展示退款请求"
            )
        )
        do {
            let status = try await Transaction.beginRefundRequest(
                for: transactionID,
                in: scene
            )
            switch status {
            case .success:
                logger.log(
                    PaymentLogEntry(
                        level: .info,
                        category: "refund",
                        message: "退款请求已提交"
                    )
                )
                return .submitted
            case .userCancelled:
                logger.log(
                    PaymentLogEntry(
                        level: .info,
                        category: "refund",
                        message: "用户取消退款请求"
                    )
                )
                return .cancelled
            @unknown default:
                throw PaymentError(
                    code: .presentationUnavailable,
                    message: "StoreKit 返回了未知退款请求状态",
                    transactionID: transactionID
                )
            }
        } catch let error as PaymentError {
            throw error
        } catch {
            logger.log(
                PaymentLogEntry(
                    level: .error,
                    category: "refund",
                    message: "退款请求失败"
                )
            )
            throw PaymentError(
                code: .storeKitFailed,
                message: "退款请求失败",
                transactionID: transactionID
            )
        }
    }

    /// 展示系统订阅管理界面。
    ///
    /// - Parameters:
    ///   - scene: 承载订阅管理界面的窗口场景。
    ///   - groupID: 可选订阅组标识符。iOS 17 及更高版本会直接定位对应订阅组；
    ///     iOS 15 和 iOS 16 会展示通用订阅管理界面。
    ///   - logger: 结构化日志处理器。
    /// - Throws: 系统无法展示订阅管理界面时产生的错误。
    @MainActor
    public static func showManageSubscriptions(
        in scene: UIWindowScene,
        groupID: String? = nil,
        logger: any PaymentLogHandler = OSPaymentLogHandler()
    ) async throws {
        logger.log(
            PaymentLogEntry(
                level: .info,
                category: "subscriptions",
                message: "开始展示订阅管理"
            )
        )
        do {
            if #available(iOS 17.0, *), let groupID {
                try await AppStore.showManageSubscriptions(
                    in: scene,
                    subscriptionGroupID: groupID
                )
            } else {
                try await AppStore.showManageSubscriptions(in: scene)
            }
            logger.log(
                PaymentLogEntry(
                    level: .info,
                    category: "subscriptions",
                    message: "订阅管理已关闭"
                )
            )
        } catch {
            logger.log(
                PaymentLogEntry(
                    level: .error,
                    category: "subscriptions",
                    message: "订阅管理展示失败"
                )
            )
            throw PaymentError(
                code: .storeKitFailed,
                message: "订阅管理展示失败"
            )
        }
    }

    /// 展示 App Store 优惠代码兑换界面。
    ///
    /// iOS 16 及更高版本使用 StoreKit 2 场景 API；iOS 15 仅为系统界面兼容
    /// 调用 `SKPaymentQueue` 的兑换页，交易仍由 PaymentKit 的 StoreKit 2 监听处理。
    @MainActor
    public static func presentOfferCodeRedeemSheet(
        in scene: UIWindowScene,
        logger: any PaymentLogHandler = OSPaymentLogHandler()
    ) async throws {
        logger.log(
            PaymentLogEntry(
                level: .info,
                category: "offer-code",
                message: "开始展示优惠代码兑换"
            )
        )
        do {
            if #available(iOS 16.0, *) {
                try await AppStore.presentOfferCodeRedeemSheet(in: scene)
            } else {
                // iOS 15 没有 StoreKit 2 场景入口；此调用只负责展示系统页。
                SKPaymentQueue.default().presentCodeRedemptionSheet()
            }
            logger.log(
                PaymentLogEntry(
                    level: .info,
                    category: "offer-code",
                    message: "优惠代码兑换界面已关闭"
                )
            )
        } catch {
            logger.log(
                PaymentLogEntry(
                    level: .error,
                    category: "offer-code",
                    message: "优惠代码兑换界面展示失败"
                )
            )
            throw PaymentError(
                code: .storeKitFailed,
                message: "优惠代码兑换界面展示失败"
            )
        }
    }

    /// 展示调用方从 `PaymentClient.storeMessages()` 收到的系统消息。
    ///
    /// - Important: 只有框架返回、仍包含 StoreKit 原始值的消息可以展示。
    @MainActor
    public static func displayStoreMessage(
        _ message: PaymentStoreMessage,
        in scene: UIWindowScene,
        logger: any PaymentLogHandler = OSPaymentLogHandler()
    ) throws {
        guard #available(iOS 16.0, *) else {
            throw PaymentError(
                code: .unsupportedFeature,
                message: "当前系统不支持应用接管 StoreKit 系统消息"
            )
        }
        guard let rawMessage = message.rawValue as? Message else {
            throw PaymentError(
                code: .presentationUnavailable,
                message: "系统消息已经失效或不是由当前 StoreKit 会话产生"
            )
        }
        do {
            try rawMessage.display(in: scene)
            logger.log(
                PaymentLogEntry(
                    level: .info,
                    category: "store-message",
                    message: "App Store 系统消息已展示"
                )
            )
        } catch {
            logger.log(
                PaymentLogEntry(
                    level: .error,
                    category: "store-message",
                    message: "App Store 系统消息展示失败"
                )
            )
            throw PaymentError(
                code: .storeKitFailed,
                message: "App Store 系统消息展示失败"
            )
        }
    }
}
#elseif os(macOS)
import AppKit

/// 展示 StoreKit 系统支付管理界面的入口。
public enum PaymentPresentation {
    /// 展示指定交易的系统退款请求界面。
    ///
    /// - Parameters:
    ///   - transactionID: 需要申请退款的交易标识符。
    ///   - viewController: 承载系统退款界面的视图控制器。
    ///   - logger: 结构化日志处理器。
    /// - Returns: 退款请求已提交或用户取消。
    /// - Throws: 系统无法展示或提交退款请求时产生的错误。
    @MainActor
    public static func beginRefund(
        for transactionID: UInt64,
        in viewController: NSViewController,
        logger: any PaymentLogHandler = OSPaymentLogHandler()
    ) async throws -> PaymentRefundOutcome {
        logger.log(
            PaymentLogEntry(
                level: .info,
                category: "refund",
                message: "开始展示退款请求"
            )
        )
        do {
            let status = try await Transaction.beginRefundRequest(
                for: transactionID,
                in: viewController
            )
            switch status {
            case .success:
                logger.log(
                    PaymentLogEntry(
                        level: .info,
                        category: "refund",
                        message: "退款请求已提交"
                    )
                )
                return .submitted
            case .userCancelled:
                logger.log(
                    PaymentLogEntry(
                        level: .info,
                        category: "refund",
                        message: "用户取消退款请求"
                    )
                )
                return .cancelled
            @unknown default:
                throw PaymentError(
                    code: .presentationUnavailable,
                    message: "StoreKit 返回了未知退款请求状态",
                    transactionID: transactionID
                )
            }
        } catch let error as PaymentError {
            throw error
        } catch {
            logger.log(
                PaymentLogEntry(
                    level: .error,
                    category: "refund",
                    message: "退款请求失败"
                )
            )
            throw PaymentError(
                code: .storeKitFailed,
                message: "退款请求失败",
                transactionID: transactionID
            )
        }
    }

    /// 展示 App Store 优惠代码兑换界面。
    ///
    /// macOS 15 以前没有对应的 StoreKit 系统界面；用户仍可在 App Store 外部
    /// 兑换，PaymentKit 会通过交易监听处理兑换结果。
    @MainActor
    public static func presentOfferCodeRedeemSheet(
        in viewController: NSViewController,
        logger: any PaymentLogHandler = OSPaymentLogHandler()
    ) async throws {
        guard #available(macOS 15.0, *) else {
            throw PaymentError(
                code: .unsupportedFeature,
                message: "当前 macOS 版本不支持应用内优惠代码兑换"
            )
        }
        logger.log(
            PaymentLogEntry(
                level: .info,
                category: "offer-code",
                message: "开始展示优惠代码兑换"
            )
        )
        do {
            try await AppStore.presentOfferCodeRedeemSheet(from: viewController)
            logger.log(
                PaymentLogEntry(
                    level: .info,
                    category: "offer-code",
                    message: "优惠代码兑换界面已关闭"
                )
            )
        } catch {
            logger.log(
                PaymentLogEntry(
                    level: .error,
                    category: "offer-code",
                    message: "优惠代码兑换界面展示失败"
                )
            )
            throw PaymentError(
                code: .storeKitFailed,
                message: "优惠代码兑换界面展示失败"
            )
        }
    }
}
#endif
