import CloudPlaceholderDomain
import Foundation

typealias SQLiteDestructor = (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: SQLiteDestructor.self)
let SQLITE_OK: Int32 = 0
let SQLITE_ROW: Int32 = 100
let SQLITE_DONE: Int32 = 101
let SQLITE_OPEN_READWRITE: Int32 = 0x00000002
let SQLITE_OPEN_CREATE: Int32 = 0x00000004
let SQLITE_OPEN_FULLMUTEX: Int32 = 0x00010000

@_silgen_name("sqlite3_open_v2")
private func sqlite3_open_v2(
    _ filename: UnsafePointer<CChar>?,
    _ ppDb: UnsafeMutablePointer<OpaquePointer?>?,
    _ flags: Int32,
    _ zVfs: UnsafePointer<CChar>?
) -> Int32

@_silgen_name("sqlite3_close")
private func sqlite3_close(_ db: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_exec")
private func sqlite3_exec(
    _ db: OpaquePointer?,
    _ sql: UnsafePointer<CChar>?,
    _ callback: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32)?,
    _ arg: UnsafeMutableRawPointer?,
    _ errmsg: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("sqlite3_prepare_v2")
private func sqlite3_prepare_v2(
    _ db: OpaquePointer?,
    _ sql: UnsafePointer<CChar>?,
    _ nByte: Int32,
    _ statement: UnsafeMutablePointer<OpaquePointer?>?,
    _ tail: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> Int32

@_silgen_name("sqlite3_step")
private func sqlite3_step(_ statement: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_finalize")
private func sqlite3_finalize(_ statement: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_errmsg")
private func sqlite3_errmsg(_ db: OpaquePointer?) -> UnsafePointer<CChar>?

@_silgen_name("sqlite3_last_insert_rowid")
private func sqlite3_last_insert_rowid(_ db: OpaquePointer?) -> Int64

@_silgen_name("sqlite3_bind_text")
private func sqlite3_bind_text(
    _ statement: OpaquePointer?,
    _ index: Int32,
    _ value: UnsafePointer<CChar>?,
    _ length: Int32,
    _ destructor: SQLiteDestructor
) -> Int32

@_silgen_name("sqlite3_bind_int")
private func sqlite3_bind_int(_ statement: OpaquePointer?, _ index: Int32, _ value: Int32) -> Int32

@_silgen_name("sqlite3_bind_int64")
private func sqlite3_bind_int64(_ statement: OpaquePointer?, _ index: Int32, _ value: Int64) -> Int32

@_silgen_name("sqlite3_bind_null")
private func sqlite3_bind_null(_ statement: OpaquePointer?, _ index: Int32) -> Int32

@_silgen_name("sqlite3_column_text")
private func sqlite3_column_text(_ statement: OpaquePointer?, _ column: Int32) -> UnsafePointer<CChar>?

@_silgen_name("sqlite3_column_int")
private func sqlite3_column_int(_ statement: OpaquePointer?, _ column: Int32) -> Int32

@_silgen_name("sqlite3_column_int64")
private func sqlite3_column_int64(_ statement: OpaquePointer?, _ column: Int32) -> Int64

@_silgen_name("sqlite3_column_type")
private func sqlite3_column_type(_ statement: OpaquePointer?, _ column: Int32) -> Int32

let SQLITE_NULL: Int32 = 5

final class SQLiteConnection {
    private let handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let openResult = path.withCString {
            sqlite3_open_v2($0, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        }
        guard openResult == SQLITE_OK, let db else {
            throw CloudPlaceholderError.sqlite("Unable to open database at \(path)")
        }
        self.handle = db
    }

    deinit {
        _ = sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sql.withCString {
            sqlite3_exec(handle, $0, nil, nil, &errorPointer)
        }
        if result != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? self.message
            throw CloudPlaceholderError.sqlite(message)
        }
    }

    func withStatement<T>(_ sql: String, _ body: (SQLiteStatement) throws -> T) throws -> T {
        var statementPointer: OpaquePointer?
        let prepareResult = sql.withCString {
            sqlite3_prepare_v2(handle, $0, -1, &statementPointer, nil)
        }
        guard prepareResult == SQLITE_OK else {
            throw CloudPlaceholderError.sqlite(message)
        }
        let statement = SQLiteStatement(connection: self, handle: statementPointer)
        defer { _ = sqlite3_finalize(statementPointer) }
        return try body(statement)
    }

    fileprivate var message: String {
        guard let ptr = sqlite3_errmsg(handle) else {
            return "Unknown SQLite error"
        }
        return String(cString: ptr)
    }

    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }
}

final class SQLiteStatement {
    private let connection: SQLiteConnection
    let handle: OpaquePointer?

    init(connection: SQLiteConnection, handle: OpaquePointer?) {
        self.connection = connection
        self.handle = handle
    }

    func bind(_ index: Int32, text: String?) throws {
        if let text {
            let result = text.withCString {
                sqlite3_bind_text(handle, index, $0, -1, SQLITE_TRANSIENT)
            }
            guard result == SQLITE_OK else {
                throw CloudPlaceholderError.sqlite(connection.message)
            }
        } else {
            try bindNull(index)
        }
    }

    func bind(_ index: Int32, int: Int32) throws {
        let result = sqlite3_bind_int(handle, index, int)
        guard result == SQLITE_OK else {
            throw CloudPlaceholderError.sqlite(connection.message)
        }
    }

    func bind(_ index: Int32, int64: Int64) throws {
        let result = sqlite3_bind_int64(handle, index, int64)
        guard result == SQLITE_OK else {
            throw CloudPlaceholderError.sqlite(connection.message)
        }
    }

    func bindNull(_ index: Int32) throws {
        let result = sqlite3_bind_null(handle, index)
        guard result == SQLITE_OK else {
            throw CloudPlaceholderError.sqlite(connection.message)
        }
    }

    @discardableResult
    func step() throws -> Bool {
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw CloudPlaceholderError.sqlite(connection.message)
        }
    }

    func text(at column: Int32) -> String? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL, let value = sqlite3_column_text(handle, column) else {
            return nil
        }
        return String(cString: value)
    }

    func int(at column: Int32) -> Int32 {
        sqlite3_column_int(handle, column)
    }

    func int64(at column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    func isNull(at column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }
}
