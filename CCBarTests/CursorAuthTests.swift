import XCTest
import SQLite3
@testable import CCBar

final class CursorAuthTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-auth-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        databaseURL = temporaryDirectory.appendingPathComponent("state.vscdb")
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testDefaultDatabaseURLUsesCursorGlobalStorage() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            CursorAuth.defaultDatabaseURL(homeDirectory: home).path,
            "/Users/tester/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
    }

    func testLoadReadsAccessTokenAndBuildsCookie() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let token = makeJWT(
            subject: "auth0|user-123",
            email: "cursor@example.com",
            expiration: 2_000
        )
        let database = try createDatabase()
        insert(database, key: "cursorAuth/accessToken", value: token)
        insert(database, key: "cursorAuth/refreshToken", value: "must-not-be-read")
        sqlite3_close(database)

        let session = try XCTUnwrap(CursorAuth.load(databaseURL: databaseURL, now: now))

        XCTAssertEqual(session.accessToken, token)
        XCTAssertEqual(session.subject, "auth0|user-123")
        XCTAssertEqual(session.userID, "user-123")
        XCTAssertEqual(session.email, "cursor@example.com")
        XCTAssertEqual(session.expiresAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(
            session.cookieHeader,
            "WorkosCursorSessionToken=user-123%3A%3A\(token)"
        )
        XCTAssertFalse(session.cookieHeader.contains(" "))
    }

    func testLoadReadsUncheckpointedWALState() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let token = makeJWT(subject: "workos|wal-user", expiration: 3_000)
        let database = try createDatabase(journalMode: "WAL")
        defer { sqlite3_close(database) }
        insert(database, key: "cursorAuth/accessToken", value: token)

        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        let session = try CursorAuth.load(databaseURL: databaseURL, now: now)

        XCTAssertEqual(session?.userID, "wal-user")
    }

    func testRefreshTokenAloneDoesNotCreateSession() throws {
        let database = try createDatabase()
        insert(database, key: "cursorAuth/refreshToken", value: "refresh-secret")
        sqlite3_close(database)

        XCTAssertNil(try CursorAuth.load(databaseURL: databaseURL))
    }

    func testMissingDatabaseIsTreatedAsCursorNotInstalled() throws {
        XCTAssertNil(try CursorAuth.load(databaseURL: databaseURL))
    }

    func testExpiredTokenIsRejectedWithSixtySecondLeeway() {
        let now = Date(timeIntervalSince1970: 1_000)
        let token = makeJWT(subject: "auth0|user-123", expiration: 1_060)

        XCTAssertThrowsError(try CursorAuth.session(accessToken: token, now: now)) { error in
            XCTAssertEqual(error as? CursorAuthError, .expired)
        }
    }

    func testUnsafeUserIDIsRejectedBeforeCookieConstruction() {
        let token = makeJWT(subject: "auth0|unsafe/user", expiration: 2_000)

        XCTAssertThrowsError(
            try CursorAuth.session(
                accessToken: token,
                now: Date(timeIntervalSince1970: 1_000)
            )
        ) { error in
            guard let authError = error as? CursorAuthError,
                  case .invalidToken = authError
            else {
                return XCTFail("expected invalidToken, got \(error)")
            }
        }
    }

    func testAccountIdentityUsesSubjectBeforeEmail() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = try CursorAuth.session(
            accessToken: makeJWT(subject: "auth0|same-user", email: "old@example.com", expiration: 2_000),
            now: now
        )
        let sameSubject = try CursorAuth.session(
            accessToken: makeJWT(subject: "workos|same-user", email: "new@example.com", expiration: 2_000),
            now: now
        )
        let otherSubject = try CursorAuth.session(
            accessToken: makeJWT(subject: "auth0|other-user", email: "old@example.com", expiration: 2_000),
            now: now
        )

        XCTAssertTrue(first.belongsToSameAccount(as: sameSubject))
        XCTAssertFalse(first.belongsToSameAccount(as: otherSubject))
    }

    @discardableResult
    private func createDatabase(journalMode: String = "DELETE") throws -> OpaquePointer {
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                databaseURL.path,
                &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                nil
            ),
            SQLITE_OK
        )
        let opened = try XCTUnwrap(database)
        execute(opened, "PRAGMA journal_mode=\(journalMode)")
        if journalMode == "WAL" {
            execute(opened, "PRAGMA wal_autocheckpoint=0")
        }
        execute(opened, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)")
        return opened
    }

    private func insert(_ database: OpaquePointer, key: String, value: String) {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database,
                "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        guard let statement else { return XCTFail("failed to prepare insert") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private func execute(_ database: OpaquePointer, _ sql: String) {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        let message = errorMessage.map { String(cString: $0) }
        sqlite3_free(errorMessage)
        XCTAssertEqual(result, SQLITE_OK, message ?? sql)
    }

    private func makeJWT(
        subject: String,
        email: String? = nil,
        expiration: Double
    ) -> String {
        var payload: [String: Any] = [
            "sub": subject,
            "exp": expiration,
        ]
        if let email { payload["email"] = email }
        let header: [String: Any] = ["alg": "none", "typ": "JWT"]
        return "\(base64URL(header)).\(base64URL(payload)).signature"
    }

    private func base64URL(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
