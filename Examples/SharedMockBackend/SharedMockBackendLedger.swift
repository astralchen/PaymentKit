import CryptoKit
import Darwin
import Foundation
import PaymentKit
import SQLite3

/// 共享模拟后台接受一笔签名交易后的幂等结果。
nonisolated enum SharedMockBackendAcceptance: Int, Sendable, Hashable {
    /// 首次看到该业务状态，已记录一次业务交付。
    case processed = 0

    /// 签名事件或等价业务状态已经处理过。
    case duplicate = 1
}

/// 共享模拟后台账本的非敏感统计信息。
nonisolated struct SharedMockBackendStatistics: Sendable, Equatable {
    /// 已记录的不同签名事件数量。
    let signedEventCount: Int

    /// 已记录的不同业务交付状态数量。
    let businessDeliveryCount: Int
}

/// 共享模拟后台当前连接使用的 SQLite 配置。
nonisolated struct SharedMockBackendDiagnostics: Sendable, Equatable {
    /// 当前回滚日志模式。
    let journalMode: String

    /// 当前同步级别。
    let synchronous: Int
}

/// 共享模拟后台使用的稳定存储错误。
///
/// 错误不包含 SQLite 原始消息、JWS、账户令牌或完整交易标识符。
nonisolated enum SharedMockBackendLedgerError: Error, Sendable, Equatable {
    /// App Group 容器不可访问。
    case appGroupUnavailable

    /// Apple 签名数据为空。
    case missingSignedData

    /// SQLite 返回稳定数字错误码。
    case sqlite(code: Int32)

    /// 数据库完整性检查失败。
    case integrityCheckFailed

    /// 数据库不是本模拟后台创建的账本。
    case unexpectedApplicationID

    /// 数据库 schema 版本高于当前实现。
    case unsupportedSchemaVersion(Int)

    /// schema 与当前版本不一致。
    case schemaMismatch

    /// 目录、权限或备份保护配置失败。
    case fileSecurityFailed
}

/// 解析主 App 与 Share Extension 共用的模拟后台数据库位置。
nonisolated enum SharedMockBackendStorage {
    /// 返回指定 App Group 内的模拟后台 SQLite 文件。
    ///
    /// - Parameters:
    ///   - appGroupIdentifier: 主 App 与扩展共同签名的 App Group 标识符。
    ///   - fileManager: 用于解析容器位置的文件管理器。
    /// - Returns: `Library/Application Support/PaymentKitMockBackend` 下的数据库地址。
    /// - Throws: App Group 容器不可访问时抛出错误，不回退到应用私有容器。
    static func databaseURL(
        appGroupIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw SharedMockBackendLedgerError.appGroupUnavailable
        }
        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("PaymentKitMockBackend", isDirectory: true)
            .appendingPathComponent("mock-backend.sqlite3", isDirectory: false)
    }
}

/// 使用 SQLite 模拟生产后台幂等提交的共享账本。
///
/// 数据库只保存不可逆摘要、处理结果和时间，不保存 JWS、账户令牌、完整交易 ID
/// 或任何会员、余额等业务权益。每次操作使用短连接和 `BEGIN IMMEDIATE`，使主 App
/// 与 Share Extension 可以跨进程原子判断首次交付与幂等命中。
actor SharedMockBackendLedger {
    private static let applicationID = 0x504B4D42
    private static let schemaVersion = 1
    private static let businessDeliveriesTableSQL = """
        CREATE TABLE business_deliveries (
            delivery_digest BLOB NOT NULL CHECK(length(delivery_digest) = 32) PRIMARY KEY,
            first_event_digest BLOB NOT NULL CHECK(length(first_event_digest) = 32),
            processed_at REAL NOT NULL
        ) WITHOUT ROWID
        """
    private static let signedEventsTableSQL = """
        CREATE TABLE signed_events (
            event_digest BLOB NOT NULL CHECK(length(event_digest) = 32) PRIMARY KEY,
            delivery_digest BLOB NOT NULL CHECK(length(delivery_digest) = 32),
            result INTEGER NOT NULL CHECK(result IN (0, 1)),
            processed_at REAL NOT NULL,
            FOREIGN KEY(delivery_digest) REFERENCES business_deliveries(delivery_digest)
        ) WITHOUT ROWID
        """
    private static let deliveryIndexSQL = """
        CREATE INDEX signed_events_delivery_digest
        ON signed_events(delivery_digest)
        """

    private let databaseURL: URL
    private let fileManager: FileManager

    /// 创建指向指定 SQLite 文件的共享模拟后台账本。
    ///
    /// - Parameters:
    ///   - databaseURL: 主 App 与扩展必须传入同一个 App Group 数据库地址。
    ///   - fileManager: 文件系统入口。
    init(databaseURL: URL, fileManager: FileManager = .default) {
        self.databaseURL = databaseURL
        self.fileManager = fileManager
    }

    /// 原子接受一笔交易并返回首次交付或幂等命中。
    ///
    /// - Parameter transaction: 已通过 StoreKit 本地验签的中立交易快照。
    /// - Returns: 首次业务交付或幂等命中。
    /// - Throws: 签名为空、账本损坏、版本不兼容或持久化失败时抛出错误。
    func accept(_ transaction: PaymentTransaction) throws -> SharedMockBackendAcceptance {
        guard !transaction.jwsRepresentation.isEmpty else {
            throw SharedMockBackendLedgerError.missingSignedData
        }
        let eventDigest = Self.signedEventDigest(for: transaction)
        let deliveryDigest = Self.deliveryStateDigest(for: transaction)
        let now = Date().timeIntervalSince1970

        let acceptance: SharedMockBackendAcceptance = try withConfiguredConnection { connection in
            let result: SharedMockBackendAcceptance = try connection.withImmediateTransaction {
                // 精确签名事件已经存在时直接返回幂等命中，不重复增加审计行。
                let existingEvent = try connection.prepare(
                    """
                    SELECT delivery_digest
                    FROM signed_events
                    WHERE event_digest = ?
                    LIMIT 1
                    """
                )
                try existingEvent.bind(eventDigest, at: 1)
                if try existingEvent.step() == .row {
                    // 同一事件只能关联到当前交易计算出的业务状态，防止逻辑损坏被误判为幂等。
                    guard existingEvent.data(at: 0) == deliveryDigest else {
                        throw SharedMockBackendLedgerError.schemaMismatch
                    }
                    return SharedMockBackendAcceptance.duplicate
                }

                // 业务状态摘要是远端幂等主键。两个进程并发写入时，
                // `BEGIN IMMEDIATE` 与唯一约束共同保证只有一个首次交付。
                let deliveryInsert = try connection.prepare(
                    """
                    INSERT OR IGNORE INTO business_deliveries(
                        delivery_digest, first_event_digest, processed_at
                    ) VALUES(?, ?, ?)
                    """
                )
                try deliveryInsert.bind(deliveryDigest, at: 1)
                try deliveryInsert.bind(eventDigest, at: 2)
                try deliveryInsert.bind(now, at: 3)
                _ = try deliveryInsert.step()
                let result: SharedMockBackendAcceptance = connection.changes == 1
                    ? .processed
                    : .duplicate

                let eventInsert = try connection.prepare(
                    """
                    INSERT INTO signed_events(
                        event_digest, delivery_digest, result, processed_at
                    ) VALUES(?, ?, ?, ?)
                    """
                )
                try eventInsert.bind(eventDigest, at: 1)
                try eventInsert.bind(deliveryDigest, at: 2)
                try eventInsert.bind(Int64(result.rawValue), at: 3)
                try eventInsert.bind(now, at: 4)
                _ = try eventInsert.step()
                return result
            }
            return result
        }
        return acceptance
    }

    /// 返回共享账本中的签名事件和业务交付数量。
    func statistics() throws -> SharedMockBackendStatistics {
        try withConfiguredConnection { connection in
            // 单条 SELECT 在一个 SQLite 读取快照中计算两个计数，避免跨进程提交造成撕裂。
            let statement = try connection.prepare(
                """
                SELECT
                    (SELECT COUNT(*) FROM signed_events),
                    (SELECT COUNT(*) FROM business_deliveries)
                """
            )
            guard try statement.step() == .row else {
                throw SharedMockBackendLedgerError.sqlite(code: SQLITE_ERROR)
            }
            return SharedMockBackendStatistics(
                signedEventCount: Int(statement.int64(at: 0)),
                businessDeliveryCount: Int(statement.int64(at: 1))
            )
        }
    }

    /// 返回当前短连接实际使用的 SQLite 配置。
    func diagnostics() throws -> SharedMockBackendDiagnostics {
        try withConfiguredConnection { connection in
            SharedMockBackendDiagnostics(
                journalMode: try connection.scalarText("PRAGMA journal_mode").lowercased(),
                synchronous: try connection.scalarInt("PRAGMA synchronous")
            )
        }
    }
}

private extension SharedMockBackendLedger {
    func withConfiguredConnection<Value>(
        _ operation: (SharedMockSQLiteConnection) throws -> Value
    ) throws -> Value {
        try prepareDirectoryAndDatabaseFile()
        let connection = try SharedMockSQLiteConnection(databaseURL: databaseURL)
        try connection.setBusyTimeout(milliseconds: 5_000)
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA temp_store = MEMORY")
        try validateIdentityAndIntegrityBeforePersistentConfiguration(connection)

        // 只有空白新库或已严格验证的本账本才允许改变持久日志配置。
        try connection.execute("PRAGMA journal_mode = DELETE")
        try connection.execute("PRAGMA synchronous = EXTRA")
        try prepareOrValidateSchema(connection)

        let result = try operation(connection)
        try applyFileSecurity()
        return result
    }

    /// 在应用持久化 PRAGMA 前只读校验数据库身份、版本、完整性和固定 schema。
    func validateIdentityAndIntegrityBeforePersistentConfiguration(
        _ connection: SharedMockSQLiteConnection
    ) throws {
        let integrity = try connection.scalarText("PRAGMA quick_check(1)")
        guard integrity.lowercased() == "ok" else {
            throw SharedMockBackendLedgerError.integrityCheckFailed
        }

        let applicationID = try connection.scalarInt("PRAGMA application_id")
        let version = try connection.scalarInt("PRAGMA user_version")
        let userObjectCount = try connection.scalarInt(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE name NOT LIKE 'sqlite_%'
            """
        )
        if applicationID == 0, version == 0, userObjectCount == 0 {
            return
        }
        guard applicationID == Self.applicationID else {
            throw SharedMockBackendLedgerError.unexpectedApplicationID
        }
        guard version <= Self.schemaVersion else {
            throw SharedMockBackendLedgerError.unsupportedSchemaVersion(version)
        }
        guard version == Self.schemaVersion else {
            throw SharedMockBackendLedgerError.schemaMismatch
        }
        try validateCurrentSchema(connection)
    }

    /// 在一个排他事务内重新读取 schema 身份，覆盖两个进程同时首次建库的竞态。
    func prepareOrValidateSchema(_ connection: SharedMockSQLiteConnection) throws {
        try connection.withImmediateTransaction {
            let applicationID = try connection.scalarInt("PRAGMA application_id")
            let version = try connection.scalarInt("PRAGMA user_version")
            let userTableCount = try connection.scalarInt(
                """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                """
            )

            if applicationID == 0, version == 0, userTableCount == 0 {
                try connection.execute("PRAGMA application_id = \(Self.applicationID)")
                try connection.execute(Self.businessDeliveriesTableSQL)
                try connection.execute(Self.signedEventsTableSQL)
                try connection.execute(Self.deliveryIndexSQL)
                try connection.execute("PRAGMA user_version = \(Self.schemaVersion)")
                return
            }

            guard applicationID == Self.applicationID else {
                throw SharedMockBackendLedgerError.unexpectedApplicationID
            }
            guard version <= Self.schemaVersion else {
                throw SharedMockBackendLedgerError.unsupportedSchemaVersion(version)
            }
            guard version == Self.schemaVersion else {
                throw SharedMockBackendLedgerError.schemaMismatch
            }
            try validateCurrentSchema(connection)
        }
    }

    /// 严格校验固定 DDL、索引和外键关系，避免逻辑损坏被当作正常幂等记录。
    func validateCurrentSchema(_ connection: SharedMockSQLiteConnection) throws {
        let expectedObjects: [(type: String, name: String, sql: String)] = [
            ("table", "business_deliveries", Self.businessDeliveriesTableSQL),
            ("table", "signed_events", Self.signedEventsTableSQL),
            ("index", "signed_events_delivery_digest", Self.deliveryIndexSQL),
        ]
        let userObjectCount = try connection.scalarInt(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE name NOT LIKE 'sqlite_%'
            """
        )
        guard userObjectCount == expectedObjects.count else {
            throw SharedMockBackendLedgerError.schemaMismatch
        }
        for object in expectedObjects {
            let statement = try connection.prepare(
                """
                SELECT sql
                FROM sqlite_master
                WHERE type = ? AND name = ?
                LIMIT 1
                """
            )
            try statement.bind(object.type, at: 1)
            try statement.bind(object.name, at: 2)
            guard try statement.step() == .row,
                  let actualSQL = statement.text(at: 0),
                  Self.normalizedSchemaSQL(actualSQL)
                    == Self.normalizedSchemaSQL(object.sql) else {
                throw SharedMockBackendLedgerError.schemaMismatch
            }
        }

        let foreignKeyCheck = try connection.prepare("PRAGMA foreign_key_check")
        guard try foreignKeyCheck.step() == .done else {
            throw SharedMockBackendLedgerError.schemaMismatch
        }

        // 每个业务交付必须反向关联到同一摘要下结果为 processed 的首个签名事件。
        let invalidFirstEventCount = try connection.scalarInt(
            """
            SELECT COUNT(*)
            FROM business_deliveries AS business
            LEFT JOIN signed_events AS event
              ON event.event_digest = business.first_event_digest
            WHERE event.event_digest IS NULL
               OR event.delivery_digest != business.delivery_digest
               OR event.result != 0
            """
        )
        guard invalidFirstEventCount == 0 else {
            throw SharedMockBackendLedgerError.schemaMismatch
        }

        // 首个事件只能标记 processed，其余等价重新签名事件只能标记 duplicate。
        let invalidEventResultCount = try connection.scalarInt(
            """
            SELECT COUNT(*)
            FROM signed_events AS event
            JOIN business_deliveries AS business
              ON business.delivery_digest = event.delivery_digest
            WHERE (
                event.event_digest = business.first_event_digest
                AND event.result != 0
            ) OR (
                event.event_digest != business.first_event_digest
                AND event.result != 1
            )
            """
        )
        guard invalidEventResultCount == 0 else {
            throw SharedMockBackendLedgerError.schemaMismatch
        }
    }

    /// 先以 `0600` 创建空文件，避免 SQLite 首次打开到权限收紧之间出现宽权限窗口。
    func prepareDirectoryAndDatabaseFile() throws {
        let directoryURL = databaseURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            // 在创建数据库前先保护目录，避免首次事务或进程崩溃留下宽权限 sidecar。
            try applyDirectorySecurity(at: directoryURL)
        } catch {
            throw SharedMockBackendLedgerError.fileSecurityFailed
        }

        guard !fileManager.fileExists(atPath: databaseURL.path) else { return }
        let descriptor = Darwin.open(
            databaseURL.path,
            O_CREAT | O_EXCL | O_WRONLY,
            S_IRUSR | S_IWUSR
        )
        if descriptor >= 0 {
            Darwin.close(descriptor)
            return
        }
        // 另一个进程可能在检查后先创建了文件；其余错误均失败关闭。
        guard errno == EEXIST else {
            throw SharedMockBackendLedgerError.fileSecurityFailed
        }
    }

    func applyFileSecurity() throws {
        let directoryURL = databaseURL.deletingLastPathComponent()
        do {
            try applyDirectorySecurity(at: directoryURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path
            )

            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDatabaseURL = databaseURL
            try mutableDatabaseURL.setResourceValues(resourceValues)

            #if os(iOS)
            try fileManager.setAttributes(
                [
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication,
                ],
                ofItemAtPath: databaseURL.path
            )
            #endif
        } catch {
            throw SharedMockBackendLedgerError.fileSecurityFailed
        }
    }

    func applyDirectorySecurity(at directoryURL: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectoryURL = directoryURL
        try mutableDirectoryURL.setResourceValues(resourceValues)

        #if os(iOS)
        // 目录级保护同时覆盖事务期间短暂出现的 rollback journal。
        try fileManager.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: directoryURL.path
        )
        #endif
    }

    /// 生成与 PaymentKit outbox 相同构造方式的签名事件摘要。
    static func signedEventDigest(for transaction: PaymentTransaction) -> Data {
        let jwsDigest = Data(SHA256.hash(data: Data(transaction.jwsRepresentation.utf8)))
        var input = Data()
        appendField(uint64Data(transaction.id), to: &input)
        appendField(uint64Data(transaction.signedDate.timeIntervalSince1970.bitPattern), to: &input)
        appendField(jwsDigest, to: &input)
        return Data(SHA256.hash(data: input))
    }

    /// 生成不包含签名时间和 JWS 的稳定业务状态摘要。
    static func deliveryStateDigest(for transaction: PaymentTransaction) -> Data {
        var input = Data()
        appendField(uint64Data(transaction.id), to: &input)
        appendField(uint64Data(transaction.originalID), to: &input)
        appendField(Data(transaction.productID.utf8), to: &input)
        appendOptionalField(transaction.subscriptionGroupID.map { Data($0.utf8) }, to: &input)
        appendField(Data(transaction.productType.rawValue.utf8), to: &input)
        appendField(uint64Data(transaction.purchaseDate.timeIntervalSince1970.bitPattern), to: &input)
        appendField(
            uint64Data(transaction.originalPurchaseDate.timeIntervalSince1970.bitPattern),
            to: &input
        )
        appendOptionalField(
            transaction.expirationDate.map { uint64Data($0.timeIntervalSince1970.bitPattern) },
            to: &input
        )
        appendOptionalField(
            transaction.revocationDate.map { uint64Data($0.timeIntervalSince1970.bitPattern) },
            to: &input
        )
        appendField(Data(ownershipRawValue(transaction.ownershipType).utf8), to: &input)
        appendField(uint64Data(UInt64(transaction.purchasedQuantity)), to: &input)
        appendOptionalField(
            transaction.appAccountToken.map { Data($0.uuidString.lowercased().utf8) },
            to: &input
        )
        appendField(Data([transaction.isUpgraded ? 1 : 0]), to: &input)
        return Data(SHA256.hash(data: input))
    }

    static func ownershipRawValue(_ ownershipType: PaymentOwnershipType) -> String {
        switch ownershipType {
        case .purchased:
            return "purchased"
        case .familyShared:
            return "familyShared"
        case .unknown(let rawValue):
            return rawValue
        }
    }

    static func appendField(_ field: Data, to input: inout Data) {
        input.append(uint64Data(UInt64(field.count)))
        input.append(field)
    }

    static func appendOptionalField(_ field: Data?, to input: inout Data) {
        guard let field else {
            input.append(uint64Data(UInt64.max))
            return
        }
        appendField(field, to: &input)
    }

    static func uint64Data(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    static func normalizedSchemaSQL(_ sql: String) -> String {
        sql.lowercased().filter { character in
            !character.isWhitespace && character != ";"
        }
    }
}

/// 示例目标内使用的一次短生命周期 SQLite 连接。
private nonisolated final class SharedMockSQLiteConnection {
    private(set) var handle: OpaquePointer

    var changes: Int {
        Int(sqlite3_changes(handle))
    }

    init(databaseURL: URL) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database {
                let code = sqlite3_extended_errcode(database)
                sqlite3_close(database)
                throw SharedMockBackendLedgerError.sqlite(code: code)
            }
            throw SharedMockBackendLedgerError.sqlite(code: result)
        }
        handle = database
        sqlite3_extended_result_codes(database, 1)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func setBusyTimeout(milliseconds: Int32) throws {
        try check(sqlite3_busy_timeout(handle, milliseconds))
    }

    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func prepare(_ sql: String) throws -> SharedMockSQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw currentError(fallback: result)
        }
        return SharedMockSQLiteStatement(connection: self, handle: statement)
    }

    func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        guard try statement.step() == .row else {
            throw SharedMockBackendLedgerError.sqlite(code: SQLITE_ERROR)
        }
        return Int(statement.int64(at: 0))
    }

    func scalarText(_ sql: String) throws -> String {
        let statement = try prepare(sql)
        guard try statement.step() == .row,
              let value = statement.text(at: 0) else {
            throw SharedMockBackendLedgerError.sqlite(code: SQLITE_ERROR)
        }
        return value
    }

    func withImmediateTransaction<Value>(
        _ operation: () throws -> Value
    ) throws -> Value {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try operation()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    fileprivate func check(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw currentError(fallback: result)
        }
    }

    fileprivate func currentError(fallback: Int32) -> SharedMockBackendLedgerError {
        let code = sqlite3_extended_errcode(handle)
        return .sqlite(code: code == SQLITE_OK ? fallback : code)
    }
}

/// 示例目标内使用的 SQLite 预编译语句。
private nonisolated final class SharedMockSQLiteStatement {
    enum StepResult {
        case row
        case done
    }

    private unowned let connection: SharedMockSQLiteConnection
    private let handle: OpaquePointer

    init(connection: SharedMockSQLiteConnection, handle: OpaquePointer) {
        self.connection = connection
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(_ value: Data, at index: Int32) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                handle,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                Self.transientDestructor
            )
        }
        try connection.check(result)
    }

    func bind(_ value: Double, at index: Int32) throws {
        try connection.check(sqlite3_bind_double(handle, index, value))
    }

    func bind(_ value: Int64, at index: Int32) throws {
        try connection.check(sqlite3_bind_int64(handle, index, value))
    }

    func bind(_ value: String, at index: Int32) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(
                handle,
                index,
                pointer,
                -1,
                Self.transientDestructor
            )
        }
        try connection.check(result)
    }

    func step() throws -> StepResult {
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW:
            return .row
        case SQLITE_DONE:
            return .done
        default:
            throw connection.currentError(fallback: result)
        }
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    func text(at index: Int32) -> String? {
        guard let text = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: text)
    }

    func data(at index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(handle, index) else { return Data() }
        return Data(
            bytes: bytes,
            count: Int(sqlite3_column_bytes(handle, index))
        )
    }

    private static var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
