import Foundation
import PaymentKit
import SQLite3
import Testing
@testable import Examples

@Suite("生产级共享模拟后台", .serialized)
struct MockTransactionProcessorTests {
    @Test("两个独立账本并发提交同一事件只产生一次业务交付")
    func concurrentInstancesDeliverBusinessStateExactlyOnce() async throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        let transaction = PaymentTransaction.mockFixture(
            id: 801,
            appAccountToken: nil,
            jwsRepresentation: "concurrent-sensitive-jws"
        )
        let firstLedger = SharedMockBackendLedger(databaseURL: location.databaseURL)
        let secondLedger = SharedMockBackendLedger(databaseURL: location.databaseURL)

        async let firstResult = firstLedger.accept(transaction)
        async let secondResult = secondLedger.accept(transaction)
        let results = try await [firstResult, secondResult]

        #expect(Set(results) == [.processed, .duplicate])
        let statistics = try await firstLedger.statistics()
        #expect(statistics.signedEventCount == 1)
        #expect(statistics.businessDeliveryCount == 1)
    }

    @Test("同一业务状态重新签名只增加签名事件审计")
    func resignedEquivalentStateDoesNotRepeatBusinessDelivery() async throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        let original = PaymentTransaction.mockFixture(
            id: 802,
            appAccountToken: nil,
            jwsRepresentation: "original-sensitive-jws"
        )
        let resigned = PaymentTransaction.mockFixture(
            id: 802,
            appAccountToken: nil,
            signedDate: Date(timeIntervalSince1970: 3),
            jwsRepresentation: "resigned-sensitive-jws"
        )

        let firstLedger = SharedMockBackendLedger(databaseURL: location.databaseURL)
        #expect(try await firstLedger.accept(original) == .processed)
        let restartedLedger = SharedMockBackendLedger(databaseURL: location.databaseURL)
        #expect(try await restartedLedger.accept(resigned) == .duplicate)

        let statistics = try await restartedLedger.statistics()
        #expect(statistics.signedEventCount == 2)
        #expect(statistics.businessDeliveryCount == 1)
    }

    @Test("撤销等真实状态变化产生新的业务交付")
    func changedTransactionStateCreatesNewBusinessDelivery() async throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        let original = PaymentTransaction.mockFixture(
            id: 803,
            appAccountToken: nil,
            jwsRepresentation: "original-state-sensitive-jws"
        )
        let revoked = PaymentTransaction.mockFixture(
            id: 803,
            appAccountToken: nil,
            revocationDate: Date(timeIntervalSince1970: 4),
            signedDate: Date(timeIntervalSince1970: 5),
            jwsRepresentation: "revoked-state-sensitive-jws"
        )
        let ledger = SharedMockBackendLedger(databaseURL: location.databaseURL)

        #expect(try await ledger.accept(original) == .processed)
        #expect(try await ledger.accept(revoked) == .processed)

        let statistics = try await ledger.statistics()
        #expect(statistics.signedEventCount == 2)
        #expect(statistics.businessDeliveryCount == 2)
    }

    @Test("后台成功后断连并重启仍命中共享幂等账本")
    func successThenDisconnectRemainsIdempotentAfterRestart() async throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        let transaction = PaymentTransaction.mockFixture(
            id: 804,
            appAccountToken: nil,
            jwsRepresentation: "disconnect-sensitive-jws"
        )
        let firstProcessor = MockTransactionProcessor(
            latencyMilliseconds: 0,
            databaseURL: location.databaseURL
        )
        await firstProcessor.setFaultMode(.successThenDisconnect)

        do {
            try await firstProcessor.process(transaction)
            Issue.record("成功后断连模式应向客户端表现为失败")
        } catch MockBackendError.connectionLostAfterSuccess {
            // 共享账本已经先提交，是此用例需要覆盖的崩溃窗口。
        }

        let restartedProcessor = MockTransactionProcessor(
            latencyMilliseconds: 0,
            databaseURL: location.databaseURL
        )
        try await restartedProcessor.process(transaction)

        let snapshot = await restartedProcessor.snapshot()
        #expect(snapshot.records.first?.result == .duplicate)
        #expect(snapshot.signedEventCount == 1)
        #expect(snapshot.businessDeliveryCount == 1)
    }

    @Test("损坏数据库失败关闭且不清空原文件")
    func corruptDatabaseFailsClosedWithoutReset() async throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        try FileManager.default.createDirectory(
            at: location.directoryURL,
            withIntermediateDirectories: true
        )
        let corruptData = Data("not-a-sqlite-database-sensitive-marker".utf8)
        try corruptData.write(to: location.databaseURL)
        let ledger = SharedMockBackendLedger(databaseURL: location.databaseURL)

        do {
            _ = try await ledger.accept(.mockFixture(
                id: 805,
                appAccountToken: nil,
                jwsRepresentation: "unused-sensitive-jws"
            ))
            Issue.record("损坏数据库不应被静默重建")
        } catch {
            // 任意持久化错误均表示账本按预期失败关闭。
        }

        #expect(try Data(contentsOf: location.databaseURL) == corruptData)
    }

    @Test("未来 schema 版本失败关闭且保留既有幂等记录")
    func futureSchemaVersionFailsClosedWithoutDowngrade() async throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        let original = PaymentTransaction.mockFixture(
            id: 806,
            appAccountToken: nil,
            jwsRepresentation: "future-version-original-jws"
        )
        let ledger = SharedMockBackendLedger(databaseURL: location.databaseURL)
        _ = try await ledger.accept(original)
        try executeSQLite(
            at: location.databaseURL,
            sql: "PRAGMA user_version = 2"
        )

        let futureLedger = SharedMockBackendLedger(databaseURL: location.databaseURL)
        do {
            _ = try await futureLedger.accept(.mockFixture(
                id: 807,
                appAccountToken: nil,
                jwsRepresentation: "future-version-new-jws"
            ))
            Issue.record("未来版本数据库不应被降级或清空")
        } catch {
            // 未知高版本必须失败关闭。
        }

        #expect(try sqliteInteger(at: location.databaseURL, sql: "PRAGMA user_version") == 2)
        #expect(
            try sqliteInteger(
                at: location.databaseURL,
                sql: "SELECT COUNT(*) FROM business_deliveries"
            ) == 1
        )
    }

    @Test("当前版本 schema 被篡改时失败关闭且不清空记录")
    func alteredCurrentSchemaFailsClosedWithoutReset() async throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        let ledger = SharedMockBackendLedger(databaseURL: location.databaseURL)
        _ = try await ledger.accept(.mockFixture(
            id: 811,
            appAccountToken: nil,
            jwsRepresentation: "altered-schema-original-jws"
        ))
        try executeSQLite(
            at: location.databaseURL,
            sql: "DROP INDEX signed_events_delivery_digest"
        )

        do {
            _ = try await ledger.accept(.mockFixture(
                id: 812,
                appAccountToken: nil,
                jwsRepresentation: "altered-schema-new-jws"
            ))
            Issue.record("当前版本 schema 缺失固定索引时必须失败关闭")
        } catch SharedMockBackendLedgerError.schemaMismatch {
            // schema 语义不完整时不能继续模拟幂等交付。
        }

        #expect(
            try sqliteInteger(
                at: location.databaseURL,
                sql: "SELECT COUNT(*) FROM business_deliveries"
            ) == 1
        )
    }

    @Test("签名事件关联错误的业务摘要时拒绝幂等命中")
    func mismatchedEventAssociationFailsClosed() async throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        let first = PaymentTransaction.mockFixture(
            id: 813,
            appAccountToken: nil,
            jwsRepresentation: "association-first-jws"
        )
        let second = PaymentTransaction.mockFixture(
            id: 814,
            appAccountToken: nil,
            jwsRepresentation: "association-second-jws"
        )
        let ledger = SharedMockBackendLedger(databaseURL: location.databaseURL)
        _ = try await ledger.accept(first)
        _ = try await ledger.accept(second)
        try executeSQLite(
            at: location.databaseURL,
            sql: """
                UPDATE signed_events
                SET delivery_digest = (
                    SELECT delivery_digest
                    FROM business_deliveries
                    WHERE first_event_digest != signed_events.event_digest
                    LIMIT 1
                )
                WHERE event_digest = (
                    SELECT first_event_digest
                    FROM business_deliveries
                    ORDER BY processed_at
                    LIMIT 1
                )
                """
        )

        do {
            _ = try await ledger.accept(first)
            Issue.record("错误事件关联不能被当作正常幂等命中")
        } catch SharedMockBackendLedgerError.schemaMismatch {
            // 精确事件必须仍关联到当前交易计算出的业务状态摘要。
        }
        #expect(
            try sqliteInteger(
                at: location.databaseURL,
                sql: "SELECT COUNT(*) FROM signed_events"
            ) == 2
        )
        #expect(
            try sqliteInteger(
                at: location.databaseURL,
                sql: "SELECT COUNT(*) FROM business_deliveries"
            ) == 2
        )
    }

    @Test("业务交付缺失首个签名事件反向关联时失败关闭")
    func orphanedBusinessDeliveryFailsClosed() async throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        let original = PaymentTransaction.mockFixture(
            id: 816,
            appAccountToken: nil,
            jwsRepresentation: "orphan-original-jws"
        )
        let resigned = PaymentTransaction.mockFixture(
            id: original.id,
            appAccountToken: nil,
            signedDate: Date(timeIntervalSince1970: 9),
            jwsRepresentation: "orphan-resigned-jws"
        )
        let ledger = SharedMockBackendLedger(databaseURL: location.databaseURL)
        _ = try await ledger.accept(original)
        try executeSQLite(
            at: location.databaseURL,
            sql: "UPDATE business_deliveries SET first_event_digest = zeroblob(32)"
        )

        do {
            _ = try await ledger.accept(resigned)
            Issue.record("孤立业务交付不能抑制一笔新的首次交付")
        } catch SharedMockBackendLedgerError.schemaMismatch {
            // business row 必须反向关联到同一状态且结果为 processed 的首个事件。
        }
        #expect(
            try sqliteInteger(
                at: location.databaseURL,
                sql: "SELECT COUNT(*) FROM signed_events"
            ) == 1
        )
        #expect(
            try sqliteInteger(
                at: location.databaseURL,
                sql: "SELECT COUNT(*) FROM business_deliveries"
            ) == 1
        )
    }

    @Test("错误数据库身份失败时不改变其日志模式或内容")
    func wrongApplicationIDDoesNotMutateUnknownDatabase() async throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        try FileManager.default.createDirectory(
            at: location.directoryURL,
            withIntermediateDirectories: true
        )
        try Data().write(to: location.databaseURL)
        try executeSQLite(
            at: location.databaseURL,
            sql: """
                PRAGMA application_id = 1234;
                PRAGMA user_version = 1;
                PRAGMA journal_mode = WAL;
                CREATE TABLE foreign_records(value TEXT NOT NULL);
                INSERT INTO foreign_records(value) VALUES('preserve-me');
                """
        )
        #expect(try sqliteText(at: location.databaseURL, sql: "PRAGMA journal_mode") == "wal")
        let ledger = SharedMockBackendLedger(databaseURL: location.databaseURL)

        do {
            _ = try await ledger.accept(.mockFixture(
                id: 815,
                appAccountToken: nil,
                jwsRepresentation: "wrong-identity-jws"
            ))
            Issue.record("错误 application_id 的数据库必须失败关闭")
        } catch SharedMockBackendLedgerError.unexpectedApplicationID {
            // 拒绝前不能应用任何持久化 PRAGMA。
        }

        #expect(try sqliteText(at: location.databaseURL, sql: "PRAGMA journal_mode") == "wal")
        #expect(
            try sqliteText(
                at: location.databaseURL,
                sql: "SELECT value FROM foreign_records"
            ) == "preserve-me"
        )
    }

    @Test("只读数据库拒绝新交付且不改变已有记录")
    func readOnlyDatabaseFailsClosed() async throws {
        let location = temporaryDatabaseLocation()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: location.directoryURL.path
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: location.databaseURL.path
            )
            try? FileManager.default.removeItem(at: location.directoryURL)
        }
        let ledger = SharedMockBackendLedger(databaseURL: location.databaseURL)
        _ = try await ledger.accept(.mockFixture(
            id: 808,
            appAccountToken: nil,
            jwsRepresentation: "read-only-original-jws"
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: location.databaseURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: location.directoryURL.path
        )

        let readOnlyLedger = SharedMockBackendLedger(databaseURL: location.databaseURL)
        do {
            _ = try await readOnlyLedger.accept(.mockFixture(
                id: 809,
                appAccountToken: nil,
                jwsRepresentation: "read-only-new-jws"
            ))
            Issue.record("只读数据库不应接受新的业务交付")
        } catch {
            // 无法创建回滚日志时必须失败关闭。
        }

        #expect(
            try sqliteInteger(
                at: location.databaseURL,
                sql: "SELECT COUNT(*) FROM business_deliveries"
            ) == 1
        )
    }

    @Test("SQLite 配置、文件安全和敏感数据扫描符合约束")
    func sqliteConfigurationAndSensitiveDataAreProductionSafe() async throws {
        let location = applicationSupportDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directoryURL) }
        let token = UUID()
        let transaction = PaymentTransaction.mockFixture(
            id: 810,
            appAccountToken: token,
            jwsRepresentation: "database-sensitive-jws-payload"
        )
        try FileManager.default.createDirectory(
            at: location.directoryURL,
            withIntermediateDirectories: true
        )
        // 明确移除目录的备份排除标记，避免临时目录的继承属性形成假绿。
        var initialResourceValues = URLResourceValues()
        initialResourceValues.isExcludedFromBackup = false
        var mutableDirectoryURL = location.directoryURL
        try mutableDirectoryURL.setResourceValues(initialResourceValues)
        let ledger = SharedMockBackendLedger(databaseURL: location.databaseURL)
        _ = try await ledger.accept(transaction)
        let diagnostics = try await ledger.diagnostics()

        #expect(diagnostics.journalMode == "delete")
        #expect(diagnostics.synchronous == 3)
        #expect(
            try sqliteInteger(at: location.databaseURL, sql: "PRAGMA application_id")
                == 0x504B4D42
        )
        #expect(try sqliteInteger(at: location.databaseURL, sql: "PRAGMA user_version") == 1)

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: location.directoryURL.path
        )
        let databaseAttributes = try FileManager.default.attributesOfItem(
            atPath: location.databaseURL.path
        )
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((databaseAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(
            try location.databaseURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup == true
        )
        #expect(
            try location.directoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup == true
        )

        #if os(iOS) && !targetEnvironment(simulator)
        // Simulator 使用宿主文件系统，不会回报 iOS Data Protection 属性。
        #expect(
            databaseAttributes[.protectionKey] as? FileProtectionType
                == .completeUntilFirstUserAuthentication
        )
        #expect(
            directoryAttributes[.protectionKey] as? FileProtectionType
                == .completeUntilFirstUserAuthentication
        )
        #endif

        let databaseData = try Data(contentsOf: location.databaseURL)
        #expect(databaseData.range(of: Data(transaction.jwsRepresentation.utf8)) == nil)
        #expect(databaseData.range(of: Data(token.uuidString.utf8)) == nil)
        #expect(databaseData.range(of: Data(String(transaction.id).utf8)) == nil)
    }

    @Test("共享账本目录显式配置备份排除和 iOS 文件保护")
    func sharedLedgerExplicitlyProtectsItsDirectory() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "SharedMockBackend/SharedMockBackendLedger.swift",
                isDirectory: false
            )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // 目录级属性覆盖短暂出现的 rollback journal 等 sidecar，不能只保护主数据库。
        #expect(source.contains("var mutableDirectoryURL = directoryURL"))
        #expect(source.contains("try mutableDirectoryURL.setResourceValues(resourceValues)"))
        let directoryProtectionStart = try #require(
            source.range(of: "func applyDirectorySecurity(at directoryURL: URL) throws")
        )
        let directoryProtectionEnd = try #require(
            source.range(
                of: "\n    /// 生成与 PaymentKit outbox 相同构造方式的签名事件摘要。",
                range: directoryProtectionStart.lowerBound..<source.endIndex
            )
        )
        let directoryProtection = source[
            directoryProtectionStart.lowerBound..<directoryProtectionEnd.lowerBound
        ]
        #expect(directoryProtection.contains(".protectionKey"))
        #expect(
            directoryProtection.contains(
                "FileProtectionType.completeUntilFirstUserAuthentication"
            )
        )
        #expect(directoryProtection.contains("ofItemAtPath: directoryURL.path"))

        let preparationStart = try #require(
            source.range(of: "func prepareDirectoryAndDatabaseFile() throws")
        )
        let databaseCreation = try #require(
            source.range(
                of: "let descriptor = Darwin.open(",
                range: preparationStart.lowerBound..<source.endIndex
            )
        )
        let beforeDatabaseCreation = source[
            preparationStart.lowerBound..<databaseCreation.lowerBound
        ]
        #expect(
            beforeDatabaseCreation.contains(
                "try applyDirectorySecurity(at: directoryURL)"
            )
        )
    }
}

private struct TemporaryDatabaseLocation {
    let directoryURL: URL
    let databaseURL: URL
}

private func temporaryDatabaseLocation() -> TemporaryDatabaseLocation {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return TemporaryDatabaseLocation(
        directoryURL: directoryURL,
        databaseURL: directoryURL.appendingPathComponent(
            "mock-backend.sqlite3",
            isDirectory: false
        )
    )
}

private func applicationSupportDatabaseLocation() -> TemporaryDatabaseLocation {
    let baseURL = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    let directoryURL = baseURL.appendingPathComponent(
        "PaymentKitMockBackendTests-\(UUID().uuidString)",
        isDirectory: true
    )
    return TemporaryDatabaseLocation(
        directoryURL: directoryURL,
        databaseURL: directoryURL.appendingPathComponent(
            "mock-backend.sqlite3",
            isDirectory: false
        )
    )
}

private func executeSQLite(at databaseURL: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        throw SQLiteTestError.openFailed
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw SQLiteTestError.executeFailed
    }
}

private func sqliteInteger(at databaseURL: URL, sql: String) throws -> Int {
    try sqliteValue(at: databaseURL, sql: sql) { statement in
        Int(sqlite3_column_int64(statement, 0))
    }
}

private func sqliteText(at databaseURL: URL, sql: String) throws -> String {
    try sqliteValue(at: databaseURL, sql: sql) { statement in
        guard let value = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: value)
    }
}

private func sqliteValue<Value>(
    at databaseURL: URL,
    sql: String,
    transform: (OpaquePointer) -> Value
) throws -> Value {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        throw SQLiteTestError.openFailed
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw SQLiteTestError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw SQLiteTestError.executeFailed
    }
    return transform(statement)
}

private enum SQLiteTestError: Error {
    case openFailed
    case prepareFailed
    case executeFailed
}

private extension PaymentTransaction {
    static func mockFixture(
        id: UInt64,
        appAccountToken: UUID?,
        revocationDate: Date? = nil,
        signedDate: Date = Date(timeIntervalSince1970: 2),
        jwsRepresentation: String
    ) -> PaymentTransaction {
        PaymentTransaction(
            id: id,
            originalID: id,
            productID: "paymentkit.demo.lifetime",
            subscriptionGroupID: nil,
            productType: .nonConsumable,
            purchaseDate: Date(timeIntervalSince1970: 1),
            originalPurchaseDate: Date(timeIntervalSince1970: 1),
            expirationDate: nil,
            revocationDate: revocationDate,
            signedDate: signedDate,
            ownershipType: .purchased,
            purchasedQuantity: 1,
            appAccountToken: appAccountToken,
            isUpgraded: false,
            jwsRepresentation: jwsRepresentation
        )
    }
}
