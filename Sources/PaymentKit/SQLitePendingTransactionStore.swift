import Darwin
import Dispatch
import Foundation
import SQLite3

/// SQLite outbox 的容量限制。
internal struct SQLitePendingTransactionStoreLimits: Sendable, Equatable {
    let maximumDatabaseBytes: Int
    let maximumRecordCount: Int
    let maximumPayloadBytes: Int

    static let production = SQLitePendingTransactionStoreLimits(
        maximumDatabaseBytes: 8 * 1_024 * 1_024,
        maximumRecordCount: 1_000,
        maximumPayloadBytes: 256 * 1_024
    )

    init(
        maximumDatabaseBytes: Int,
        maximumRecordCount: Int,
        maximumPayloadBytes: Int
    ) {
        self.maximumDatabaseBytes = maximumDatabaseBytes
        self.maximumRecordCount = maximumRecordCount
        self.maximumPayloadBytes = maximumPayloadBytes
    }
}

/// SQLite 连接级配置的诊断快照。
internal struct SQLitePendingTransactionStoreDiagnostics: Sendable, Equatable {
    let synchronous: Int
    let foreignKeysEnabled: Bool
    let temporaryStorage: Int
    let secureDeleteEnabled: Bool
}

/// 使用系统 SQLite3 持久化待交付交易的生产实现。
///
/// 每个操作都先取得独立锁文件上的跨进程排他锁，再打开一个短生命周期连接。
/// SQLite 事务只保证本地 outbox 状态一致；交易处理器仍须在后台按签名事件实现幂等。
internal actor SQLitePendingTransactionStore: PendingTransactionStore {
    private static let applicationID = 0x504B4954
    private static let schemaVersion = 1
    private static let maximumQuarantineGroupCount = 3
    private static let maximumQuarantineBytes = 32 * 1_024 * 1_024
    private static let tableSQL = """
        CREATE TABLE pending_transactions (
            event_id BLOB NOT NULL CHECK(length(event_id) = 32) PRIMARY KEY,
            transaction_id BLOB NOT NULL CHECK(length(transaction_id) = 8),
            signed_date REAL NOT NULL,
            jws_digest BLOB NOT NULL CHECK(length(jws_digest) = 32),
            product_id TEXT NOT NULL,
            transaction_payload BLOB NOT NULL,
            delivery_state INTEGER NOT NULL CHECK(delivery_state IN (0, 1)),
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        ) WITHOUT ROWID
        """
    private static let transactionSignedDateIndexSQL = """
        CREATE INDEX pending_transactions_transaction_signed_date
        ON pending_transactions(transaction_id, signed_date)
        """

    private let databaseURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let limits: SQLitePendingTransactionStoreLimits
    private let lockTimeoutNanoseconds: UInt64
    private let lockPollingNanoseconds: UInt64
    private let logger: any PaymentLogHandler
    private let beforeDatabaseOperation: @Sendable () -> Void
    private var recoveryIncidentCount = 0

    /// 创建指向指定 SQLite 文件的存储。
    ///
    /// - Parameters:
    ///   - databaseURL: outbox 数据库文件地址。
    ///   - fileManager: 文件系统入口。
    ///   - limits: 数据库、记录数和单条载荷限制。
    ///   - lockTimeout: 跨进程锁最长等待时间。
    ///   - lockPollingInterval: 非阻塞文件锁的轮询间隔。
    ///   - logger: 仅接收脱敏后的存储诊断。
    ///   - beforeDatabaseOperation: 测试取消竞态使用的同步钩子；生产保持默认空实现。
    init(
        databaseURL: URL,
        fileManager: FileManager = .default,
        limits: SQLitePendingTransactionStoreLimits = .production,
        lockTimeout: TimeInterval = 5,
        lockPollingInterval: TimeInterval = 0.05,
        logger: any PaymentLogHandler = DisabledPaymentLogHandler(),
        beforeDatabaseOperation: @escaping @Sendable () -> Void = {}
    ) {
        self.databaseURL = databaseURL
        lockURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("pending-transactions.lock", isDirectory: false)
        self.fileManager = fileManager
        self.limits = limits
        lockTimeoutNanoseconds = UInt64(max(0, lockTimeout) * 1_000_000_000)
        lockPollingNanoseconds = UInt64(
            max(0.001, lockPollingInterval) * 1_000_000_000
        )
        self.logger = logger
        self.beforeDatabaseOperation = beforeDatabaseOperation
    }

    func references() async throws -> Set<PendingTransactionReference> {
        try await withLockedConnection { connection in
            let statement = try connection.prepare(
                """
                SELECT event_id, transaction_id, signed_date, jws_digest,
                       product_id, transaction_payload, delivery_state
                FROM pending_transactions
                ORDER BY created_at, event_id
                """
            )
            var values = Set<PendingTransactionReference>()
            while try statement.step() == .row {
                let payload = statement.data(at: 5)
                guard payload.count <= limits.maximumPayloadBytes,
                      var reference = try? JSONDecoder().decode(
                        PendingTransactionReference.self,
                        from: payload
                      ) else {
                    throw SQLiteStorageError.invalidPayload
                }
                let deliveryState = statement.int64(at: 6)
                guard deliveryState == 0 || deliveryState == 1 else {
                    throw SQLiteStorageError.invalidPayload
                }
                if deliveryState == 1 {
                    reference = reference.markingDelivered()
                }

                // quick_check 只验证 SQLite 页面结构；这里继续验证冗余索引与载荷语义一致。
                guard statement.data(at: 0) == Self.eventID(for: reference),
                      statement.data(at: 1) == Self.transactionIDData(
                        reference.transactionID
                      ),
                      statement.data(at: 3) == Self.jwsDigestData(reference.jwsDigest),
                      statement.text(at: 4) == (reference.productID ?? ""),
                      statement.double(at: 2) == reference.signedDate
                        .timeIntervalSince1970 else {
                    throw SQLiteStorageError.invalidPayload
                }
                values.insert(reference)
            }
            return values
        }
    }

    func insert(_ reference: PendingTransactionReference) async throws {
        try await write(reference)
    }

    func markDelivered(_ reference: PendingTransactionReference) async throws {
        // 标记阶段即使找不到旧记录也执行 UPSERT，覆盖后台成功期间文件被外部清理的恢复窗口。
        try await write(reference.markingDelivered())
    }

    func remove(_ reference: PendingTransactionReference) async throws {
        try await withLockedConnection { connection in
            try connection.withImmediateTransaction {
                let statement = try connection.prepare(
                    "DELETE FROM pending_transactions WHERE event_id = ?1"
                )
                try statement.bind(Self.eventID(for: reference), at: 1)
                _ = try statement.step()
            }
        }
    }

    func removeCurrentAndOlder(
        _ reference: PendingTransactionReference
    ) async throws {
        try await withLockedConnection { connection in
            try connection.withImmediateTransaction {
                let statement = try connection.prepare(
                    """
                    DELETE FROM pending_transactions
                    WHERE transaction_id = ?1
                      AND (signed_date < ?2 OR event_id = ?3)
                    """
                )
                try statement.bind(
                    Self.transactionIDData(reference.transactionID),
                    at: 1
                )
                try statement.bind(reference.signedDate.timeIntervalSince1970, at: 2)
                try statement.bind(Self.eventID(for: reference), at: 3)
                _ = try statement.step()
            }
        }
    }

    func consumeRecoveryIncidentCount() async -> Int {
        let count = recoveryIncidentCount
        recoveryIncidentCount = 0
        return count
    }

    /// 返回实际连接采用的关键 pragma，供包内验收使用。
    func diagnostics() async throws -> SQLitePendingTransactionStoreDiagnostics {
        try await withLockedConnection { connection in
            SQLitePendingTransactionStoreDiagnostics(
                synchronous: try connection.scalarInt("PRAGMA synchronous"),
                foreignKeysEnabled: try connection.scalarInt("PRAGMA foreign_keys") == 1,
                temporaryStorage: try connection.scalarInt("PRAGMA temp_store"),
                secureDeleteEnabled: try connection.scalarInt(
                    "PRAGMA secure_delete"
                ) == 1
            )
        }
    }

    private func write(_ reference: PendingTransactionReference) async throws {
        let payload = try JSONEncoder().encode(reference)
        guard payload.count <= limits.maximumPayloadBytes else {
            throw SQLiteStorageError.payloadTooLarge
        }
        let eventID = Self.eventID(for: reference)
        let deliveryState: Int64 = reference.isDelivered ? 1 : 0
        let now = Date().timeIntervalSince1970

        try await withLockedConnection { connection in
            try connection.withImmediateTransaction {
                let existing = try connection.prepare(
                    "SELECT COUNT(*) FROM pending_transactions WHERE event_id = ?1"
                )
                try existing.bind(eventID, at: 1)
                guard try existing.step() == .row else {
                    throw SQLiteStorageError.sqlite(code: SQLITE_ERROR)
                }
                let eventAlreadyExists = existing.int64(at: 0) > 0
                if !eventAlreadyExists {
                    let recordCount = try connection.scalarInt(
                        "SELECT COUNT(*) FROM pending_transactions"
                    )
                    guard recordCount < limits.maximumRecordCount else {
                        throw SQLiteStorageError.recordLimitReached
                    }
                }

                let statement = try connection.prepare(
                    """
                    INSERT INTO pending_transactions (
                        event_id, transaction_id, signed_date, jws_digest,
                        product_id, transaction_payload, delivery_state,
                        created_at, updated_at
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
                    ON CONFLICT(event_id) DO UPDATE SET
                        product_id = CASE
                            WHEN pending_transactions.product_id = ''
                            THEN excluded.product_id
                            ELSE pending_transactions.product_id
                        END,
                        transaction_payload = CASE
                            WHEN excluded.delivery_state >= pending_transactions.delivery_state
                            THEN excluded.transaction_payload
                            ELSE pending_transactions.transaction_payload
                        END,
                        delivery_state = MAX(
                            pending_transactions.delivery_state,
                            excluded.delivery_state
                        ),
                        updated_at = excluded.updated_at
                    """
                )
                try statement.bind(eventID, at: 1)
                try statement.bind(
                    Self.transactionIDData(reference.transactionID),
                    at: 2
                )
                try statement.bind(reference.signedDate.timeIntervalSince1970, at: 3)
                try statement.bind(Self.jwsDigestData(reference.jwsDigest), at: 4)
                try statement.bind(reference.productID ?? "", at: 5)
                try statement.bind(payload, at: 6)
                try statement.bind(deliveryState, at: 7)
                try statement.bind(now, at: 8)
                _ = try statement.step()
            }
        }
    }

    /// 在跨进程锁内打开、校验并关闭一次短连接。
    private func withLockedConnection<T>(
        _ operation: (SQLiteConnection) throws -> T
    ) async throws -> T {
        // 预取消任务不能创建目录、锁文件或数据库。
        try Task.checkCancellation()
        try prepareDirectory()
        let lockFileDescriptor = try await acquireFileLock()
        defer {
            flock(lockFileDescriptor, LOCK_UN)
            close(lockFileDescriptor)
        }

        do {
            // 取得锁后到执行同步数据库闭包前仍可能收到取消。
            try Task.checkCancellation()
            let result = try performWithConnection(operation)
            try protectDatabaseArtifacts()
            return result
        } catch let error as SQLiteStorageError where error.requiresQuarantine {
            // 连接已在 performWithConnection 返回前关闭；仍持有文件锁，可安全移动全部 sidecar。
            try quarantineDatabase()
            recoveryIncidentCount += 1
            log(
                .warning,
                message: "SQLite outbox 已隔离并重建",
                metadata: ["sqliteCode": error.stableCode]
            )
            let result = try performWithConnection(operation)
            try protectDatabaseArtifacts()
            return result
        } catch let error as SQLiteStorageError {
            log(
                .error,
                message: "SQLite outbox 操作失败",
                metadata: ["sqliteCode": error.stableCode]
            )
            throw error
        }
    }

    private func performWithConnection<T>(
        _ operation: (SQLiteConnection) throws -> T
    ) throws -> T {
        try validateDatabaseFileSize()
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        do {
            try configure(connection)
            // 测试钩子只用于稳定覆盖“连接配置完成到业务 SQL 执行前”的取消窗口。
            beforeDatabaseOperation()
            try Task.checkCancellation()
            let result = try operation(connection)
            connection.close()
            return result
        } catch {
            connection.close()
            throw error
        }
    }

    /// 校验身份和完整性后，应用每次连接都必须设置的生产 pragma。
    private func configure(_ connection: SQLiteConnection) throws {
        try connection.setBusyTimeout(milliseconds: 5_000)

        let version = try connection.scalarInt("PRAGMA user_version")
        guard version <= Self.schemaVersion else {
            throw SQLiteStorageError.unsupportedSchemaVersion(version)
        }
        let applicationID = try connection.scalarInt("PRAGMA application_id")
        if version == Self.schemaVersion,
           applicationID != Self.applicationID {
            throw SQLiteStorageError.unexpectedApplicationID(applicationID)
        }
        if version == 0 {
            let objectCount = try connection.scalarInt(
                """
                SELECT COUNT(*) FROM sqlite_master
                WHERE name NOT LIKE 'sqlite_%'
                """
            )
            guard objectCount == 0, applicationID == 0 else {
                throw SQLiteStorageError.unexpectedApplicationID(applicationID)
            }
        }
        guard try connection.scalarText("PRAGMA quick_check(1)") == "ok" else {
            throw SQLiteStorageError.integrityCheckFailed
        }
        if version == Self.schemaVersion {
            try validateSchema(connection)
        }

        // 回滚日志避免旧系统 SQLite 多连接 WAL checkpoint 风险。
        try connection.execute("PRAGMA journal_mode = DELETE")
        try connection.execute("PRAGMA synchronous = EXTRA")
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA temp_store = MEMORY")
        // outbox 载荷包含交易 JWS；逻辑删除时必须同步覆写 B-tree 页面中的旧内容。
        try connection.execute("PRAGMA secure_delete = ON")
        guard try connection.scalarInt("PRAGMA secure_delete") == 1 else {
            throw SQLiteStorageError.sqlite(code: SQLITE_ERROR)
        }

        let pageSize = try connection.scalarInt("PRAGMA page_size")
        let maximumPageCount = max(1, limits.maximumDatabaseBytes / max(1, pageSize))
        let effectiveMaximum = try connection.scalarInt(
            "PRAGMA max_page_count = \(maximumPageCount)"
        )
        guard effectiveMaximum <= maximumPageCount else {
            throw SQLiteStorageError.payloadTooLarge
        }

        if version == 0 {
            try connection.withImmediateTransaction {
                try connection.execute(Self.tableSQL)
                try connection.execute(Self.transactionSignedDateIndexSQL)
                try connection.execute(
                    "PRAGMA application_id = \(Self.applicationID)"
                )
                try connection.execute(
                    "PRAGMA user_version = \(Self.schemaVersion)"
                )
            }
        }
    }

    /// 校验当前版本的业务 schema，避免逻辑损坏以普通 SQL 错误永久阻塞 outbox。
    private func validateSchema(_ connection: SQLiteConnection) throws {
        let tableSQL = try connection.scalarText(
            """
            SELECT COALESCE((
                SELECT sql FROM sqlite_master
                WHERE type = 'table' AND name = 'pending_transactions'
            ), '')
            """
        )
        let indexSQL = try connection.scalarText(
            """
            SELECT COALESCE((
                SELECT sql FROM sqlite_master
                WHERE type = 'index'
                  AND name = 'pending_transactions_transaction_signed_date'
                  AND tbl_name = 'pending_transactions'
            ), '')
            """
        )
        guard Self.normalizedSQL(tableSQL) == Self.normalizedSQL(Self.tableSQL),
              Self.normalizedSQL(indexSQL)
                == Self.normalizedSQL(Self.transactionSignedDateIndexSQL) else {
            throw SQLiteStorageError.schemaMismatch
        }
    }

    /// SQLite 会保留建表语句的空白；比较时只忽略无业务含义的大小写和空白差异。
    private static func normalizedSQL(_ sql: String) -> String {
        sql.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// 创建并保护数据库目录和锁文件。
    private func prepareDirectory() throws {
        let directoryURL = databaseURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try secureDirectory(at: directoryURL)
        } catch {
            throw SQLiteStorageError.fileSecurityFailed
        }
    }

    /// 非阻塞轮询 `flock`，确保取消和超时不会修改数据库。
    private func acquireFileLock() async throws -> Int32 {
        try Task.checkCancellation()
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SQLiteStorageError.fileSecurityFailed
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            close(descriptor)
            throw SQLiteStorageError.fileSecurityFailed
        }
        do {
            try protectFile(at: lockURL)
        } catch {
            close(descriptor)
            throw SQLiteStorageError.fileSecurityFailed
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        while true {
            do {
                try Task.checkCancellation()
            } catch {
                close(descriptor)
                throw error
            }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                do {
                    // 取消可能与成功取得锁同时发生；此时必须立即释放锁。
                    try Task.checkCancellation()
                    return descriptor
                } catch {
                    flock(descriptor, LOCK_UN)
                    close(descriptor)
                    throw error
                }
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
            guard elapsed < lockTimeoutNanoseconds else {
                close(descriptor)
                log(
                    .error,
                    message: "等待 SQLite outbox 文件锁超时",
                    metadata: ["sqliteCode": SQLiteStorageError.lockTimedOut.stableCode]
                )
                throw SQLiteStorageError.lockTimedOut
            }
            do {
                try await Task.sleep(nanoseconds: lockPollingNanoseconds)
            } catch {
                close(descriptor)
                throw error
            }
        }
    }

    private func validateDatabaseFileSize() throws {
        guard fileManager.fileExists(atPath: databaseURL.path) else { return }
        let attributes = try? fileManager.attributesOfItem(atPath: databaseURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= limits.maximumDatabaseBytes else {
            throw SQLiteStorageError.payloadTooLarge
        }
    }

    /// 将损坏数据库及可能遗留的 sidecar 作为同一组隔离。
    private func quarantineDatabase() throws {
        let quarantineURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("PaymentKit-Quarantine", isDirectory: true)
        try fileManager.createDirectory(
            at: quarantineURL,
            withIntermediateDirectories: true
        )
        try secureDirectory(at: quarantineURL)

        let groupID = "\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString)"
        let candidates = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-journal"),
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
        for sourceURL in candidates where fileManager.fileExists(atPath: sourceURL.path) {
            let destinationURL = quarantineURL.appendingPathComponent(
                "\(groupID)--\(sourceURL.lastPathComponent)",
                isDirectory: false
            )
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            try protectFile(at: destinationURL)
        }
        try pruneQuarantine(at: quarantineURL)
    }

    /// 隔离区最多保留三组且总计不超过 32 MiB。
    private func pruneQuarantine(at quarantineURL: URL) throws {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
        ]
        let files = try fileManager.contentsOfDirectory(
            at: quarantineURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        var groups: [String: (date: Date, bytes: Int, files: [URL])] = [:]
        for fileURL in files {
            let groupID = fileURL.lastPathComponent
                .components(separatedBy: "--")
                .first ?? fileURL.lastPathComponent
            let values = try fileURL.resourceValues(forKeys: keys)
            var group = groups[groupID] ?? (.distantPast, 0, [])
            group.date = max(group.date, values.contentModificationDate ?? .distantPast)
            group.bytes += values.fileSize ?? 0
            group.files.append(fileURL)
            groups[groupID] = group
        }

        var totalBytes = groups.values.reduce(0) { $0 + $1.bytes }
        let ordered = groups.sorted {
            if $0.value.date != $1.value.date {
                return $0.value.date < $1.value.date
            }
            return $0.key < $1.key
        }
        var remainingGroupCount = groups.count
        for (_, group) in ordered {
            guard remainingGroupCount > Self.maximumQuarantineGroupCount
                    || totalBytes > Self.maximumQuarantineBytes else {
                break
            }
            for fileURL in group.files {
                try fileManager.removeItem(at: fileURL)
            }
            remainingGroupCount -= 1
            totalBytes -= group.bytes
        }
    }

    private func protectDatabaseArtifacts() throws {
        let candidates = [
            databaseURL,
            lockURL,
            URL(fileURLWithPath: databaseURL.path + "-journal"),
        ]
        do {
            for fileURL in candidates where fileManager.fileExists(atPath: fileURL.path) {
                try protectFile(at: fileURL)
            }
        } catch {
            throw SQLiteStorageError.fileSecurityFailed
        }
    }

    private func secureDirectory(at directoryURL: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = directoryURL
        try mutableURL.setResourceValues(values)

        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // 首次解锁后允许后台补偿，同时在设备重启前保持系统级文件加密。
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.path
        )
        #endif
    }

    private func protectFile(at fileURL: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try mutableURL.setResourceValues(values)

        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        #endif
    }

    private func log(
        _ level: PaymentLogLevel,
        message: String,
        metadata: [String: String]
    ) {
        logger.log(
            PaymentLogEntry(
                level: level,
                category: "sqlite-outbox",
                message: message,
                metadata: metadata
            )
        )
    }

    /// 使用长度前缀输入生成稳定签名事件主键。
    private static func eventID(for reference: PendingTransactionReference) -> Data {
        PaymentSignedEventIdentity.digest(
            transactionID: reference.transactionID,
            signedDate: reference.signedDate,
            jwsDigest: jwsDigestData(reference.jwsDigest)
        )
    }

    private static func transactionIDData(_ transactionID: UInt64) -> Data {
        PaymentSignedEventIdentity.transactionIDData(transactionID)
    }

    private static func jwsDigestData(_ base64Digest: String) -> Data {
        Data(base64Encoded: base64Digest) ?? Data()
    }

}
