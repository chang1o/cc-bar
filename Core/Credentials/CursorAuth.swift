import Foundation
import SQLite3

nonisolated struct CursorAuthSession: Sendable, Equatable {
    let accessToken: String
    let subject: String
    let userID: String
    let email: String?
    let expiresAt: Date

    var cookieHeader: String {
        "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)"
    }

    func belongsToSameAccount(as other: CursorAuthSession) -> Bool {
        let lhsSubject = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhsSubject = other.userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !lhsSubject.isEmpty, !rhsSubject.isEmpty {
            return lhsSubject == rhsSubject
        }
        guard let lhsEmail = normalizedEmail(email),
              let rhsEmail = normalizedEmail(other.email)
        else { return false }
        return lhsEmail == rhsEmail
    }

    private func normalizedEmail(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }
}

/// 只读采用 Cursor.app 的当前登录态。
///
/// 第一版只读取 `cursorAuth/accessToken`；不读取 refresh token，不调用 OAuth，
/// 不写 Cursor SQLite，也不把凭据保存到 cc-bar 的 Keychain、设置或缓存。
nonisolated enum CursorAuth {
    private static let accessTokenKey = "cursorAuth/accessToken"
    private static let expirationLeeway: TimeInterval = 60
    private static let sqliteBusyTimeoutMilliseconds: Int32 = 250

    static func defaultDatabaseURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Cursor", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb", isDirectory: false)
    }

    static func load(
        databaseURL: URL = defaultDatabaseURL(),
        now: Date = Date()
    ) throws -> CursorAuthSession? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        guard let token = try CursorSQLiteReader(databaseURL: databaseURL).value(for: accessTokenKey) else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try session(accessToken: trimmed, now: now)
    }

    static func session(accessToken: String, now: Date = Date()) throws -> CursorAuthSession {
        guard let payload = JWT.decodePayload(accessToken) else {
            throw CursorAuthError.invalidToken("access token is not a valid JWT")
        }
        guard let subject = nonEmpty(payload["sub"] as? String),
              let userID = subject.split(separator: "|", omittingEmptySubsequences: true).last.map(String.init),
              !userID.isEmpty
        else {
            throw CursorAuthError.invalidToken("access token is missing a user ID")
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard userID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CursorAuthError.invalidToken("access token contains an unsafe user ID")
        }
        guard let expiration = number(payload["exp"]) else {
            throw CursorAuthError.invalidToken("access token is missing an expiration")
        }

        let expiresAt = Date(timeIntervalSince1970: expiration)
        guard expiresAt.timeIntervalSince(now) > expirationLeeway else {
            throw CursorAuthError.expired
        }

        return CursorAuthSession(
            accessToken: accessToken,
            subject: subject,
            userID: userID,
            email: nonEmpty(payload["email"] as? String),
            expiresAt: expiresAt
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        let parsed: Double?
        switch value {
        case let value as NSNumber:
            parsed = value.doubleValue
        case let value as String:
            parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            parsed = nil
        }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    private struct CursorSQLiteReader {
        let databaseURL: URL

        func value(for key: String) throws -> String? {
            do {
                return try value(for: key, immutable: false)
            } catch let failure as SQLiteReadFailure {
                guard failure.code == SQLITE_CANTOPEN, walSidecarsAreMissing else {
                    throw CursorAuthError.database(failure.message)
                }
                do {
                    return try value(for: key, immutable: true)
                } catch let fallback as SQLiteReadFailure {
                    throw CursorAuthError.database(fallback.message)
                }
            }
        }

        private func value(for key: String, immutable: Bool) throws -> String? {
            var database: OpaquePointer?
            let filename = immutable
                ? "\(databaseURL.absoluteURL.absoluteString)?immutable=1"
                : databaseURL.path
            let flags = immutable
                ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
                : SQLITE_OPEN_READONLY
            let openResult = sqlite3_open_v2(filename, &database, flags, nil)
            guard openResult == SQLITE_OK, let database else {
                let failure = sqliteFailure(database: database, resultCode: openResult)
                if let database { sqlite3_close(database) }
                throw failure
            }
            defer { sqlite3_close(database) }
            sqlite3_busy_timeout(database, CursorAuth.sqliteBusyTimeoutMilliseconds)

            let sql = "SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1;"
            var statement: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            guard prepareResult == SQLITE_OK, let statement else {
                throw sqliteFailure(database: database, resultCode: prepareResult)
            }
            defer { sqlite3_finalize(statement) }

            let bindResult = sqlite3_bind_text(statement, 1, key, -1, CursorAuth.sqliteTransient)
            guard bindResult == SQLITE_OK else {
                throw sqliteFailure(database: database, resultCode: bindResult)
            }

            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return decodeValue(statement: statement, index: 0)
            case SQLITE_DONE:
                return nil
            case let result:
                throw sqliteFailure(database: database, resultCode: result)
            }
        }

        private var walSidecarsAreMissing: Bool {
            !FileManager.default.fileExists(atPath: databaseURL.path + "-wal")
                && !FileManager.default.fileExists(atPath: databaseURL.path + "-shm")
        }

        private func decodeValue(statement: OpaquePointer, index: Int32) -> String? {
            switch sqlite3_column_type(statement, index) {
            case SQLITE_TEXT:
                guard let text = sqlite3_column_text(statement, index) else { return nil }
                return String(cString: text)
            case SQLITE_BLOB:
                guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
                return String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16LittleEndian)
            default:
                return nil
            }
        }

        private func sqliteFailure(
            database: OpaquePointer?,
            resultCode: Int32
        ) -> SQLiteReadFailure {
            let code = database.map(sqlite3_errcode) ?? resultCode
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown SQLite error"
            return SQLiteReadFailure(code: code, message: message)
        }
    }

    private struct SQLiteReadFailure: Error {
        let code: Int32
        let message: String
    }

    private static let sqliteTransient: sqlite3_destructor_type =
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

nonisolated enum CursorAuthError: Error, CustomStringConvertible, Equatable {
    case invalidToken(String)
    case expired
    case database(String)

    var description: String {
        switch self {
        case .invalidToken(let message): return "invalid Cursor credential: \(message)"
        case .expired: return "Cursor credential expired; open Cursor and sign in again"
        case .database(let message): return "Cursor credential database read failed: \(message)"
        }
    }
}
