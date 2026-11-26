package import Logging
package import PostgresMigrations
package import PostgresNIO

/// Creates `loans_internal`, the role `serve` connects as for administrators' RPCs.
///
/// It sees every loan through its own policy, since no single tenant is bound, so its use cases
/// confine the work. Like the service role, it owns nothing and has no `BYPASSRLS` or `TRUNCATE`.
package struct CreateInternalRole: DatabaseMigration {
    private let role: String
    private let database: String

    package init(role: String, database: String) {
        self.role = role
        self.database = database
    }

    package func apply(connection: PostgresConnection, logger: Logger) async throws {
        let escapedRole = role.replacing("\"", with: "\"\"")
        let quotedRole = "\"\(escapedRole)\""
        let escapedDatabase = database.replacing("\"", with: "\"\"")
        let quotedDatabase = "\"\(escapedDatabase)\""
        let statements = [
            "CREATE ROLE \(quotedRole) LOGIN NOSUPERUSER NOBYPASSRLS",
            "GRANT CONNECT ON DATABASE \(quotedDatabase) TO \(quotedRole)",
            "GRANT USAGE ON SCHEMA public TO \(quotedRole)",
            "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \(quotedRole)",
            "GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO \(quotedRole)",
            "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \(quotedRole)",
            "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE ON SEQUENCES TO \(quotedRole)",
        ]

        for sql in statements {
            let query = PostgresQuery(unsafeSQL: sql)
            try await connection.query(query, logger: logger)
        }
    }

    package func revert(connection: PostgresConnection, logger: Logger) async throws {
        let escapedRole = role.replacing("\"", with: "\"\"")
        let quotedRole = "\"\(escapedRole)\""
        let statements = [
            "DROP OWNED BY \(quotedRole)",
            "DROP ROLE IF EXISTS \(quotedRole)",
        ]

        for sql in statements {
            let query = PostgresQuery(unsafeSQL: sql)
            try await connection.query(query, logger: logger)
        }
    }
}
