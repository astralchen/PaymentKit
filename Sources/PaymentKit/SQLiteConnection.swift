import Foundation
import SQLite3

/// SQLite outbox 使用的稳定内部错误。
///
/// 错误只保留 SQLite 数字错误码，不拼接数据库内容或底层错误文本，避免日志意外带出签名载荷。
internal enum SQLiteStorageError: Error, Sendable, Equatable {
    case sqlite(code: Int32)
    case integrityCheckFailed
    case schemaMismatch
    case unsupportedSchemaVersion(Int)
    case unexpectedApplicationID(Int)
    case invalidPayload
    case payloadTooLarge
    case recordLimitReached
    case lockTimedOut
    case fileSecurityFailed

    /// 可安全写入结构化日志的稳定错误码。
    var stableCode: String {
        switch self {
        case .sqlite(let code):
            return "sqlite-\(code)"
        case .integrityCheckFailed:
            return "integrity-check"
        case .schemaMismatch:
            return "schema-mismatch"
        case .unsupportedSchemaVersion:
            return "schema-version"
        case .unexpectedApplicationID:
            return "application-id"
        case .invalidPayload:
            return "payload"
        case .payloadTooLarge:
            return "payload-limit"
        case .recordLimitReached:
            return "record-limit"
        case .lockTimedOut:
            return "lock-timeout"
        case .fileSecurityFailed:
            return "file-security"
        }
    }

    /// 当前错误是否表示数据库内容不能继续信任。
    var requiresQuarantine: Bool {
        switch self {
        case .integrityCheckFailed, .schemaMismatch,
             .unexpectedApplicationID, .invalidPayload:
            return true
        case .sqlite(let code):
            let primaryCode = code & 0xFF
            return primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB
        default:
            return false
        }
    }
}

/// 一次短生命周期 SQLite 连接。
///
/// 连接只在 `SQLitePendingTransactionStore` actor 持有跨进程文件锁期间使用，
/// 不跨 actor 或任务边界传递。
internal final class SQLiteConnection {
    private(set) var handle: OpaquePointer
    private var isClosed = false

    init(databaseURL: URL, readOnly: Bool = false) throws {
        var database: OpaquePointer?
        let access = readOnly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            access | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database {
                let code = sqlite3_extended_errcode(database)
                sqlite3_close(database)
                throw SQLiteStorageError.sqlite(code: code)
            }
            throw SQLiteStorageError.sqlite(code: result)
        }
        handle = database
        sqlite3_extended_result_codes(database, 1)
    }

    deinit {
        close()
    }

    /// 立即关闭连接，使损坏数据库可以在仍持有文件锁时安全隔离。
    func close() {
        guard !isClosed else { return }
        sqlite3_close_v2(handle)
        isClosed = true
    }

    /// 配置连接级超时。
    func setBusyTimeout(milliseconds: Int32) throws {
        try check(sqlite3_busy_timeout(handle, milliseconds))
    }

    /// 执行不返回结果行的 SQL。
    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    /// 创建预编译语句。
    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw currentError(fallback: result)
        }
        return SQLiteStatement(connection: self, handle: statement)
    }

    /// 返回查询第一行第一列的整数。
    func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        guard try statement.step() == .row else {
            throw SQLiteStorageError.sqlite(code: SQLITE_ERROR)
        }
        return Int(statement.int64(at: 0))
    }

    /// 返回查询第一行第一列的文本。
    func scalarText(_ sql: String) throws -> String {
        let statement = try prepare(sql)
        guard try statement.step() == .row,
              let value = statement.text(at: 0) else {
            throw SQLiteStorageError.sqlite(code: SQLITE_ERROR)
        }
        return value
    }

    /// 在 `BEGIN IMMEDIATE` 事务中执行写操作。
    func withImmediateTransaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            // 回滚失败不能覆盖触发回滚的原始错误。
            try? execute("ROLLBACK")
            throw error
        }
    }

    fileprivate func check(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw currentError(fallback: result)
        }
    }

    fileprivate func currentError(fallback: Int32) -> SQLiteStorageError {
        let code = sqlite3_extended_errcode(handle)
        return .sqlite(code: code == SQLITE_OK ? fallback : code)
    }
}

/// SQLite 预编译语句的轻量封装。
internal final class SQLiteStatement {
    enum StepResult {
        case row
        case done
    }

    private unowned let connection: SQLiteConnection
    private let handle: OpaquePointer

    fileprivate init(connection: SQLiteConnection, handle: OpaquePointer) {
        self.connection = connection
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    /// 绑定二进制数据。
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

    /// 绑定文本。
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

    /// 绑定浮点值。
    func bind(_ value: Double, at index: Int32) throws {
        try connection.check(sqlite3_bind_double(handle, index, value))
    }

    /// 绑定整数值。
    func bind(_ value: Int64, at index: Int32) throws {
        try connection.check(sqlite3_bind_int64(handle, index, value))
    }

    /// 推进语句并返回是否产生结果行。
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

    /// 读取二进制列。
    func data(at index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(handle, index))
        guard count > 0, let bytes = sqlite3_column_blob(handle, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: count)
    }

    /// 读取文本列。
    func text(at index: Int32) -> String? {
        guard let text = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: text)
    }

    /// 读取整数列。
    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    /// 读取浮点列。
    func double(at index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    private static var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
