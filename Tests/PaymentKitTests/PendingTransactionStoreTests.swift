import Foundation
import Darwin
import SQLite3
import Testing
@testable import PaymentKit

@Suite("SQLite 待交付交易存储", .serialized)
struct PendingTransactionStoreTests {
    @Test("SQLite outbox 跨实例持久化交易并应用安全属性")
    func sqliteStorePersistsReplayPayloadWithRestrictedPermissions() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }

        let transaction = PaymentTransaction.storeFixture(
            id: 501,
            jwsRepresentation: "sensitive-jws-payload"
        )
        let reference = PendingTransactionReference(transaction: transaction)
        let firstProcessStore = SQLitePendingTransactionStore(
            databaseURL: fixture.databaseURL
        )
        try await firstProcessStore.insert(reference)

        // 新实例模拟应用重启或另一个扩展进程重新打开同一数据库。
        let restartedProcessStore = SQLitePendingTransactionStore(
            databaseURL: fixture.databaseURL
        )
        let reloaded = try #require(await restartedProcessStore.references().first)
        #expect(reloaded == reference)
        #expect(reloaded.persistedTransaction == transaction)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.databaseURL.path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.directoryURL.path
        )
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let fileValues = try fixture.databaseURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        let directoryValues = try fixture.directoryURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        #expect(fileValues.isExcludedFromBackup == true)
        #expect(directoryValues.isExcludedFromBackup == true)

        try await restartedProcessStore.remove(reference)
        #expect(try await firstProcessStore.references().isEmpty)
    }

    @Test("删除交易后覆写 SQLite 页面中的敏感载荷")
    func removingTransactionSecurelyErasesSensitivePayload() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let store = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)
        let anchor = PendingTransactionReference(transaction: .storeFixture(
            id: 550,
            jwsRepresentation: "non-sensitive-anchor"
        ))
        let sensitiveMarker = "pk-sensitive-\(UUID().uuidString)-"
            + String(repeating: "secret", count: 128)
        let sensitiveReference = PendingTransactionReference(
            transaction: .storeFixture(
                id: 551,
                jwsRepresentation: sensitiveMarker
            )
        )

        // 保留一条记录，避免“删除最后一行”掩盖 B-tree 已释放单元中的载荷残留。
        try await store.insert(anchor)
        try await store.insert(sensitiveReference)
        try await store.remove(sensitiveReference)
        #expect(try await store.references() == [anchor])

        let databaseBytes = try Data(contentsOf: fixture.databaseURL)
        #expect(
            databaseBytes.range(of: Data(sensitiveMarker.utf8)) == nil,
            "逻辑删除后 SQLite 原始页面不得继续保留 JWS"
        )
    }

    @Test("SQLite 使用固定生产 pragma 和表结构")
    func sqliteUsesProductionPragmasAndSchema() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let store = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)
        try await store.insert(PendingTransactionReference(transaction: .storeFixture(
            id: 502,
            jwsRepresentation: "pragma-jws"
        )))

        let database = try fixture.openReadOnlyDatabase()
        defer { sqlite3_close(database) }
        #expect(try scalarText(database, sql: "PRAGMA journal_mode") == "delete")
        #expect(try scalarInt(database, sql: "PRAGMA application_id") == 0x504B4954)
        #expect(try scalarInt(database, sql: "PRAGMA user_version") == 1)
        #expect(try scalarText(database, sql: "PRAGMA quick_check(1)") == "ok")
        let diagnostics = try await store.diagnostics()
        #expect(diagnostics.synchronous == 3)
        #expect(diagnostics.foreignKeysEnabled)
        #expect(diagnostics.temporaryStorage == 2)
        #expect(diagnostics.secureDeleteEnabled)

        let columns = try stringColumn(
            database,
            sql: "SELECT name FROM pragma_table_info('pending_transactions') ORDER BY cid"
        )
        #expect(columns == [
            "event_id",
            "transaction_id",
            "signed_date",
            "jws_digest",
            "product_id",
            "transaction_payload",
            "delivery_state",
            "created_at",
            "updated_at",
        ])
    }

    @Test("UPSERT 不会把已交付状态降级")
    func upsertNeverDowngradesDeliveredState() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let store = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)
        let reference = PendingTransactionReference(transaction: .storeFixture(
            id: 503,
            jwsRepresentation: "monotonic-jws"
        ))

        try await store.markDelivered(reference)
        try await store.insert(reference)

        let restored = try #require(await store.references().first)
        #expect(restored.isDelivered)
        #expect(restored.persistedTransaction != nil)
    }

    @Test("原子清理当前和更旧签名并保留更新状态")
    func removesCurrentAndOlderSignaturesAtomically() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let store = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)
        let older = PendingTransactionReference(transaction: .storeFixture(
            id: 504,
            signedDate: Date(timeIntervalSince1970: 10),
            jwsRepresentation: "older-jws"
        ))
        let current = PendingTransactionReference(transaction: .storeFixture(
            id: 504,
            signedDate: Date(timeIntervalSince1970: 20),
            jwsRepresentation: "current-jws"
        ))
        let newer = PendingTransactionReference(transaction: .storeFixture(
            id: 504,
            signedDate: Date(timeIntervalSince1970: 30),
            jwsRepresentation: "newer-jws"
        ))
        let unrelated = PendingTransactionReference(transaction: .storeFixture(
            id: 505,
            signedDate: Date(timeIntervalSince1970: 5),
            jwsRepresentation: "unrelated-jws"
        ))
        for reference in [older, current, newer, unrelated] {
            try await store.insert(reference)
        }

        try await store.removeCurrentAndOlder(current)

        let remaining = try await SQLitePendingTransactionStore(
            databaseURL: fixture.databaseURL
        ).references()
        #expect(remaining.count == 2)
        #expect(!remaining.contains(older))
        #expect(!remaining.contains(current))
        #expect(remaining.contains(newer))
        #expect(remaining.contains(unrelated))
    }

    @Test("两个独立 store 并发写入不会覆盖或丢失")
    func twoStoresCanMutateConcurrentlyWithoutLostUpdates() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let firstStore = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)
        let secondStore = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)
        let references = (0..<100).map { index in
            PendingTransactionReference(transaction: .storeFixture(
                id: UInt64(10_000 + index),
                signedDate: Date(timeIntervalSince1970: Double(index)),
                jwsRepresentation: "concurrent-jws-\(index)"
            ))
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, reference) in references.enumerated() {
                group.addTask {
                    let store = index.isMultiple(of: 2) ? firstStore : secondStore
                    try await store.insert(reference)
                    if index.isMultiple(of: 3) {
                        try await store.markDelivered(reference)
                    }
                }
            }
            try await group.waitForAll()
        }

        let persisted = try await firstStore.references()
        #expect(persisted.count == references.count)
        for (index, reference) in references.enumerated() {
            let value = try #require(persisted.first(where: { $0 == reference }))
            #expect(value.isDelivered == index.isMultiple(of: 3))
        }
    }

    @Test("损坏数据库会整组隔离并允许 StoreKit 重建")
    func corruptDatabaseIsQuarantinedAndDoesNotBlockNewTransactions() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        try Data("not-a-sqlite-database".utf8).write(to: fixture.databaseURL)
        let store = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)

        #expect(try await store.references().isEmpty)
        #expect(await store.consumeRecoveryIncidentCount() == 1)
        #expect(await store.consumeRecoveryIncidentCount() == 0)

        let quarantineURL = fixture.directoryURL
            .appendingPathComponent("PaymentKit-Quarantine", isDirectory: true)
        let quarantinedFiles = try FileManager.default.contentsOfDirectory(
            at: quarantineURL,
            includingPropertiesForKeys: nil
        )
        #expect(quarantinedFiles.contains { $0.lastPathComponent.hasSuffix(".sqlite3") })

        let reference = PendingTransactionReference(transaction: .storeFixture(
            id: 506,
            jwsRepresentation: "recovered-jws"
        ))
        try await store.insert(reference)
        #expect(try await store.references().contains(reference))
    }

    @Test("当前版本缺少业务表时会隔离并重建")
    func missingOutboxTableIsQuarantined() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let store = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)
        try await store.insert(PendingTransactionReference(transaction: .storeFixture(
            id: 516,
            jwsRepresentation: "missing-table-jws"
        )))
        try fixture.execute("DROP TABLE pending_transactions")

        #expect(try await store.references().isEmpty)
        #expect(await store.consumeRecoveryIncidentCount() == 1)
        let quarantineURL = fixture.directoryURL
            .appendingPathComponent("PaymentKit-Quarantine", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    @Test("当前版本缺少固定索引时会隔离并重建")
    func missingOutboxIndexIsQuarantined() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let store = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)
        try await store.insert(PendingTransactionReference(transaction: .storeFixture(
            id: 517,
            jwsRepresentation: "missing-index-jws"
        )))
        try fixture.execute(
            "DROP INDEX pending_transactions_transaction_signed_date"
        )

        #expect(try await store.references().isEmpty)
        #expect(await store.consumeRecoveryIncidentCount() == 1)
        let quarantineURL = fixture.directoryURL
            .appendingPathComponent("PaymentKit-Quarantine", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    @Test("未来数据库版本会失败且保留原件")
    func futureSchemaVersionFailsWithoutQuarantine() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let store = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)
        try await store.insert(PendingTransactionReference(transaction: .storeFixture(
            id: 507,
            jwsRepresentation: "future-schema-jws"
        )))
        try fixture.execute("PRAGMA user_version = 999")

        let futureStore = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)
        await #expect(throws: (any Error).self) {
            _ = try await futureStore.references()
        }
        #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        let quarantineURL = fixture.directoryURL
            .appendingPathComponent("PaymentKit-Quarantine", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    @Test("单条 payload 和总记录数均受上限保护")
    func payloadAndRecordLimitsAreEnforced() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let store = SQLitePendingTransactionStore(
            databaseURL: fixture.databaseURL,
            limits: .init(
                maximumDatabaseBytes: 8 * 1_024 * 1_024,
                maximumRecordCount: 2,
                maximumPayloadBytes: 512
            )
        )
        let first = PendingTransactionReference(transaction: .storeFixture(
            id: 508,
            jwsRepresentation: "first"
        ))
        let second = PendingTransactionReference(transaction: .storeFixture(
            id: 509,
            jwsRepresentation: "second"
        ))
        try await store.insert(first)
        try await store.insert(second)
        await #expect(throws: (any Error).self) {
            try await store.insert(PendingTransactionReference(transaction: .storeFixture(
                id: 510,
                jwsRepresentation: "third"
            )))
        }
        await #expect(throws: (any Error).self) {
            try await store.insert(PendingTransactionReference(transaction: .storeFixture(
                id: 511,
                jwsRepresentation: String(repeating: "x", count: 2_000)
            )))
        }
        #expect(try await store.references().count == 2)
    }

    @Test("SQLite 磁盘空间耗尽会回滚事务且不留下半条记录")
    func sqliteFullRollsBackWriteWithoutPartialRecord() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let seedStore = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)
        let seed = PendingTransactionReference(transaction: .storeFixture(
            id: 520,
            jwsRepresentation: "seed-jws"
        ))
        try await seedStore.insert(seed)
        try await seedStore.remove(seed)

        let database = try fixture.openReadOnlyDatabase()
        let pageSize = try scalarInt(database, sql: "PRAGMA page_size")
        let pageCount = try scalarInt(database, sql: "PRAGMA page_count")
        sqlite3_close(database)

        // 把 SQLite 页数上限固定为当前文件大小，稳定模拟 ENOSPC/SQLITE_FULL。
        let constrainedStore = SQLitePendingTransactionStore(
            databaseURL: fixture.databaseURL,
            limits: .init(
                maximumDatabaseBytes: pageSize * pageCount,
                maximumRecordCount: 1_000,
                maximumPayloadBytes: 256 * 1_024
            )
        )
        let oversizedForRemainingPages = PendingTransactionReference(
            transaction: .storeFixture(
                id: 521,
                jwsRepresentation: String(repeating: "x", count: 128 * 1_024)
            )
        )

        do {
            try await constrainedStore.insert(oversizedForRemainingPages)
            Issue.record("数据库页数耗尽时写事务不应成功")
        } catch let error as SQLiteStorageError {
            guard case .sqlite(let code) = error else {
                Issue.record("磁盘空间耗尽应返回稳定 SQLite 错误码")
                return
            }
            #expect((code & 0xFF) == SQLITE_FULL)
        }
        #expect(try await seedStore.references().isEmpty)
        let verificationDatabase = try fixture.openReadOnlyDatabase()
        defer { sqlite3_close(verificationDatabase) }
        #expect(
            try scalarText(verificationDatabase, sql: "PRAGMA quick_check(1)") == "ok"
        )
    }

    @Test("文件锁释放后等待中的操作继续执行")
    func operationWaitsForFileLockThenContinues() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let lock = try fixture.acquireExternalLock()
        let store = SQLitePendingTransactionStore(
            databaseURL: fixture.databaseURL,
            lockTimeout: 1,
            lockPollingInterval: 0.01
        )
        let reference = PendingTransactionReference(transaction: .storeFixture(
            id: 512,
            jwsRepresentation: "wait-lock-jws"
        ))
        let insertion = Task {
            try await store.insert(reference)
        }

        try await Task.sleep(for: .milliseconds(80))
        fixture.releaseExternalLock(lock)
        try await insertion.value
        #expect(try await store.references().contains(reference))
    }

    @Test("文件锁超时前不修改数据库")
    func lockTimeoutDoesNotModifyDatabase() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let lock = try fixture.acquireExternalLock()
        defer { fixture.releaseExternalLock(lock) }
        let store = SQLitePendingTransactionStore(
            databaseURL: fixture.databaseURL,
            lockTimeout: 0.08,
            lockPollingInterval: 0.01
        )

        do {
            try await store.insert(PendingTransactionReference(transaction: .storeFixture(
                id: 513,
                jwsRepresentation: "timeout-lock-jws"
            )))
            Issue.record("持锁超过上限时写入不应成功")
        } catch let error as SQLiteStorageError {
            #expect(error == .lockTimedOut)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path))
    }

    @Test("等待文件锁的任务可以取消且不修改数据库")
    func waitingForLockCanBeCancelled() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let lock = try fixture.acquireExternalLock()
        defer { fixture.releaseExternalLock(lock) }
        let store = SQLitePendingTransactionStore(
            databaseURL: fixture.databaseURL,
            lockTimeout: 2,
            lockPollingInterval: 0.01
        )
        let insertion = Task {
            try await store.insert(PendingTransactionReference(transaction: .storeFixture(
                id: 514,
                jwsRepresentation: "cancel-lock-jws"
            )))
        }

        try await Task.sleep(for: .milliseconds(50))
        insertion.cancel()
        do {
            try await insertion.value
            Issue.record("取消的锁等待不应继续写入")
        } catch is CancellationError {
            // 取消必须保持原始 CancellationError 语义。
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path))
    }

    @Test("预取消任务在锁空闲时不创建或修改 SQLite 文件")
    func preCancelledOperationDoesNotAcquireFreeLock() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let store = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)
        let gate = StoreCancellationGate()
        let insertion = Task {
            await gate.wait()
            try await store.insert(PendingTransactionReference(transaction: .storeFixture(
                id: 517,
                jwsRepresentation: "pre-cancelled-jws"
            )))
        }

        await gate.waitUntilBlocked()
        insertion.cancel()
        await gate.resume()

        do {
            try await insertion.value
            Issue.record("预取消任务不应取得空闲文件锁或写入数据库")
        } catch is CancellationError {
            // 必须保留原始取消语义。
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.lockURL.path))
    }

    @Test("连接配置完成后的取消不会执行数据库操作闭包")
    func cancellationAfterConfigurationDoesNotExecuteOperation() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let original = PendingTransactionReference(transaction: .storeFixture(
            id: 518,
            jwsRepresentation: "existing-jws"
        ))
        let seedStore = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)
        try await seedStore.insert(original)

        let barrier = SQLiteOperationBarrier()
        let store = SQLitePendingTransactionStore(
            databaseURL: fixture.databaseURL,
            beforeDatabaseOperation: {
                barrier.blockUntilReleased()
            }
        )
        let insertion = Task {
            try await store.insert(PendingTransactionReference(transaction: .storeFixture(
                id: 519,
                jwsRepresentation: "cancelled-after-configuration-jws"
            )))
        }
        try await waitUntilStoreCondition { barrier.hasEntered }
        insertion.cancel()
        barrier.release()

        do {
            try await insertion.value
            Issue.record("配置完成后取消的操作不应执行写事务")
        } catch is CancellationError {
            // 取消必须在进入调用方数据库闭包前被观察到。
        }
        #expect(try await seedStore.references() == [original])
    }

    @Test("持锁进程被强杀后系统自动释放文件锁")
    func killedLockOwnerDoesNotLeavePermanentLock() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let lockURL = fixture.lockURL
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SQLiteTestError.externalLockFailed
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw SQLiteTestError.externalLockFailed
        }

        // 子进程继承未设置 CLOEXEC 的已加锁描述符，模拟扩展进程持有锁。
        var child: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [
            strdup("sleep"),
            strdup("60"),
            nil,
        ]
        defer {
            free(arguments[0])
            free(arguments[1])
        }
        let spawnResult = arguments.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(
                &child,
                "/bin/sleep",
                nil,
                nil,
                buffer.baseAddress,
                environ
            )
        }
        guard spawnResult == 0 else {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw SQLiteTestError.externalLockFailed
        }
        close(descriptor)

        let contender = open(lockURL.path, O_RDWR | O_CLOEXEC)
        guard contender >= 0 else {
            kill(child, SIGKILL)
            var status: Int32 = 0
            waitpid(child, &status, 0)
            throw SQLiteTestError.externalLockFailed
        }
        guard flock(contender, LOCK_EX | LOCK_NB) != 0 else {
            flock(contender, LOCK_UN)
            close(contender)
            kill(child, SIGKILL)
            var status: Int32 = 0
            waitpid(child, &status, 0)
            throw SQLiteTestError.externalLockFailed
        }

        // 强杀持锁进程后，内核必须自动释放 flock。
        kill(child, SIGKILL)
        var status: Int32 = 0
        waitpid(child, &status, 0)
        guard flock(contender, LOCK_EX | LOCK_NB) == 0 else {
            close(contender)
            throw SQLiteTestError.externalLockFailed
        }
        flock(contender, LOCK_UN)
        close(contender)

        let store = SQLitePendingTransactionStore(
            databaseURL: fixture.databaseURL,
            lockTimeout: 1,
            lockPollingInterval: 0.01
        )
        let reference = PendingTransactionReference(transaction: .storeFixture(
            id: 515,
            jwsRepresentation: "killed-owner-jws"
        ))
        try await store.insert(reference)
        #expect(try await store.references().contains(reference))
    }

    @Test("损坏数据库隔离区最多保留三组")
    func quarantineRetentionIsBounded() async throws {
        let fixture = try SQLiteStoreFixture()
        defer { fixture.remove() }
        let store = SQLitePendingTransactionStore(databaseURL: fixture.databaseURL)

        for index in 0..<5 {
            try Data("corrupt-database-\(index)".utf8).write(
                to: fixture.databaseURL,
                options: .atomic
            )
            #expect(try await store.references().isEmpty)
        }

        let quarantineURL = fixture.directoryURL
            .appendingPathComponent("PaymentKit-Quarantine", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: quarantineURL,
            includingPropertiesForKeys: nil
        )
        let groupIDs = Set(files.map {
            $0.lastPathComponent.components(separatedBy: "--").first ?? ""
        })
        #expect(groupIDs.count == 3)
        #expect(await store.consumeRecoveryIncidentCount() == 5)
    }
}

private struct SQLiteStoreFixture {
    let directoryURL: URL
    let databaseURL: URL
    var lockURL: URL {
        directoryURL.appendingPathComponent("pending-transactions.lock")
    }

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent(
            "pending-transactions.sqlite3",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func openReadOnlyDatabase() throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SQLiteTestError.openFailed(result)
        }
        return database
    }

    func execute(_ sql: String) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SQLiteTestError.openFailed(result)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteTestError.executeFailed
        }
    }

    func acquireExternalLock() throws -> Int32 {
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            throw SQLiteTestError.externalLockFailed
        }
        return descriptor
    }

    func releaseExternalLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

private enum SQLiteTestError: Error {
    case openFailed(Int32)
    case executeFailed
    case prepareFailed
    case noValue
    case externalLockFailed
}

private actor StoreCancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            blockedWaiters.forEach { $0.resume() }
            blockedWaiters.removeAll()
        }
    }

    func waitUntilBlocked() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private final class SQLiteOperationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var entered = false

    var hasEntered: Bool {
        lock.withLock { entered }
    }

    func blockUntilReleased() {
        lock.withLock { entered = true }
        releaseSemaphore.wait()
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private func waitUntilStoreCondition(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("等待 SQLite 测试条件超时")
}

private func scalarText(_ database: OpaquePointer, sql: String) throws -> String {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw SQLiteTestError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let value = sqlite3_column_text(statement, 0) else {
        throw SQLiteTestError.noValue
    }
    return String(cString: value)
}

private func scalarInt(_ database: OpaquePointer, sql: String) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw SQLiteTestError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw SQLiteTestError.noValue
    }
    return Int(sqlite3_column_int64(statement, 0))
}

private func stringColumn(_ database: OpaquePointer, sql: String) throws -> [String] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw SQLiteTestError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        guard let value = sqlite3_column_text(statement, 0) else {
            throw SQLiteTestError.noValue
        }
        values.append(String(cString: value))
    }
    return values
}

private extension PaymentTransaction {
    static func storeFixture(
        id: UInt64,
        signedDate: Date = Date(timeIntervalSince1970: 1),
        jwsRepresentation: String
    ) -> PaymentTransaction {
        PaymentTransaction(
            id: id,
            originalID: id,
            productID: "premium",
            subscriptionGroupID: nil,
            productType: .nonConsumable,
            purchaseDate: Date(timeIntervalSince1970: 0),
            originalPurchaseDate: Date(timeIntervalSince1970: 0),
            expirationDate: nil,
            revocationDate: nil,
            signedDate: signedDate,
            ownershipType: .purchased,
            purchasedQuantity: 1,
            appAccountToken: nil,
            isUpgraded: false,
            jwsRepresentation: jwsRepresentation
        )
    }
}
