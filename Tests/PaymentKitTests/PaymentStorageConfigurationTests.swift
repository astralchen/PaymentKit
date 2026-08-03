import CryptoKit
import Foundation
import Testing
@testable import PaymentKit

@Suite("支付存储配置")
struct PaymentStorageConfigurationTests {
    @Test("应用容器配置按 bundle 隔离默认数据库")
    func applicationContainerBuildsDefaultDatabaseURL() throws {
        let rootURL = URL(fileURLWithPath: "/tmp/application-support", isDirectory: true)
        let url = try PaymentStorageConfiguration.applicationContainer.databaseURL(
            applicationSupportURL: rootURL,
            bundleIdentifier: "com.example.app",
            appGroupContainerProvider: { _ in nil }
        )

        #expect(url == rootURL
            .appendingPathComponent("PaymentKit", isDirectory: true)
            .appendingPathComponent("com.example.app", isDirectory: true)
            .appendingPathComponent("pending-transactions.sqlite3"))
    }

    @Test("App Group namespace 使用 SHA-256 目录且不允许路径穿越")
    func appGroupNamespaceUsesDigestDirectory() throws {
        let groupRoot = URL(fileURLWithPath: "/tmp/group", isDirectory: true)
        let namespace = "../shared/outbox"
        let expectedDigest = Data(SHA256.hash(data: Data(namespace.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
        let url = try PaymentStorageConfiguration.appGroup(
            identifier: "group.com.example",
            namespace: namespace
        ).databaseURL(
            applicationSupportURL: URL(fileURLWithPath: "/unused"),
            bundleIdentifier: "unused",
            appGroupContainerProvider: { identifier in
                #expect(identifier == "group.com.example")
                return groupRoot
            }
        )

        #expect(url == groupRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("PaymentKit", isDirectory: true)
            .appendingPathComponent(expectedDigest, isDirectory: true)
            .appendingPathComponent("pending-transactions.sqlite3"))
        #expect(!url.path.contains("../"))
    }

    @Test("App Group 容器不可访问时明确失败")
    func unavailableAppGroupFails() {
        let configuration = PaymentStorageConfiguration.appGroup(
            identifier: "group.unavailable",
            namespace: "payment"
        )

        #expect(throws: PaymentError.self) {
            _ = try configuration.databaseURL(
                applicationSupportURL: URL(fileURLWithPath: "/unused"),
                bundleIdentifier: "unused",
                appGroupContainerProvider: { _ in nil }
            )
        }
    }

    @Test("PaymentClient 显式 App Group 初始化不会静默回退")
    func paymentClientRejectsUnavailableAppGroup() {
        #expect(throws: PaymentError.self) {
            _ = try PaymentClient(
                configuration: PaymentConfiguration(productIDs: []),
                processor: StorageConfigurationProcessor(),
                storage: .appGroup(
                    identifier: "",
                    namespace: "test"
                ),
                logger: DisabledPaymentLogHandler()
            )
        }
    }
}

private struct StorageConfigurationProcessor: TransactionProcessor {
    func process(_ transaction: PaymentTransaction) async throws {}
}
