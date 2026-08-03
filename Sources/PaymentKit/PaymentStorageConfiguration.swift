import CryptoKit
import Foundation

/// PaymentKit 可靠交付队列的存储位置。
///
/// 存储配置只决定 outbox 所在容器，不包含商品、权益或其他业务规则。
public struct PaymentStorageConfiguration: Sendable, Hashable {
    private enum Location: Sendable, Hashable {
        case applicationContainer
        case appGroup(identifier: String, namespace: String)
    }

    private let location: Location

    /// 使用当前应用容器中的 SQLite 数据库。
    public static let applicationContainer = PaymentStorageConfiguration(
        location: .applicationContainer
    )

    private init(location: Location) {
        self.location = location
    }

    /// 使用 App Group 容器中的共享 SQLite 数据库。
    ///
    /// 主应用和扩展必须传入完全相同的 App Group 标识符、命名空间和 PaymentKit 版本。
    /// 命名空间只用于隔离不同模块，PaymentKit 会先对它计算 SHA-256，原始值不会进入路径。
    ///
    /// - Parameters:
    ///   - identifier: 已写入应用签名 entitlement 的 App Group 标识符。
    ///   - namespace: 主应用和扩展共同约定的非空命名空间。
    /// - Returns: 使用指定 App Group 的存储配置。
    public static func appGroup(
        identifier: String,
        namespace: String
    ) -> Self {
        PaymentStorageConfiguration(
            location: .appGroup(identifier: identifier, namespace: namespace)
        )
    }
}

internal extension PaymentStorageConfiguration {
    typealias AppGroupContainerProvider = (String) -> URL?

    /// 解析配置对应的 SQLite 数据库地址。
    ///
    /// App Group 不可访问时必须立即失败，不能回退到应用容器，否则主应用与扩展会形成两份 outbox。
    func databaseURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "unknown.application"
    ) throws -> URL {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return try databaseURL(
            applicationSupportURL: applicationSupportURL,
            bundleIdentifier: bundleIdentifier,
            appGroupContainerProvider: { identifier in
                fileManager.containerURL(
                    forSecurityApplicationGroupIdentifier: identifier
                )
            }
        )
    }

    /// 返回应用容器的默认 SQLite 地址。
    static func applicationContainerDatabaseURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "unknown.application"
    ) -> URL {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return applicationSupportURL
            .appendingPathComponent("PaymentKit", isDirectory: true)
            .appendingPathComponent(
                bundleIdentifier.isEmpty ? "unknown.application" : bundleIdentifier,
                isDirectory: true
            )
            .appendingPathComponent("pending-transactions.sqlite3", isDirectory: false)
    }

    /// 注入容器解析器的地址计算入口，供包内确定性测试使用。
    func databaseURL(
        applicationSupportURL: URL,
        bundleIdentifier: String,
        appGroupContainerProvider: AppGroupContainerProvider
    ) throws -> URL {
        let rootURL: URL
        let directoryName: String

        switch location {
        case .applicationContainer:
            rootURL = applicationSupportURL
            directoryName = bundleIdentifier.isEmpty
                ? "unknown.application"
                : bundleIdentifier
        case .appGroup(let identifier, let namespace):
            guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PaymentError(
                    code: .invalidConfiguration,
                    message: "App Group 标识符和存储命名空间不能为空"
                )
            }
            guard let containerURL = appGroupContainerProvider(identifier) else {
                throw PaymentError(
                    code: .invalidConfiguration,
                    message: "无法访问指定的 App Group 容器"
                )
            }
            rootURL = containerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
            directoryName = Self.sha256Hex(namespace)
        }

        return rootURL
            .appendingPathComponent("PaymentKit", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("pending-transactions.sqlite3", isDirectory: false)
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
