package import Logging
package import PostgresMigrations
package import PostgresNIO

/// Confines `loans` to the bound caller: a member's own loans, and the loans of the branch a session acts for.
///
/// The internal role sees every row through its own policy.
package struct CreateLoansRLSPolicy: DatabaseMigration {
    private let internalRole: String

    package init(internalRole: String) {
        self.internalRole = internalRole
    }

    package func apply(connection: PostgresConnection, logger: Logger) async throws {
        let escapedInternalRole = internalRole.replacing("\"", with: "\"\"")
        let quotedInternalRole = "\"\(escapedInternalRole)\""
        let statements = [
            "ALTER TABLE loans ENABLE ROW LEVEL SECURITY",
            """
            CREATE POLICY tenant_isolation ON loans
                USING (user_id = (SELECT NULLIF(current_setting('app.caller_user_id', true), '')::uuid))
            """,
            """
            CREATE POLICY organization_isolation ON loans FOR SELECT
                USING (branch_id = (SELECT NULLIF(current_setting('app.caller_organization_id', true), '')::uuid))
            """,
            "CREATE POLICY internal_all ON loans TO \(quotedInternalRole) USING (true)",
        ]

        for sql in statements {
            let query = PostgresQuery(unsafeSQL: sql)
            try await connection.query(query, logger: logger)
        }
    }

    package func revert(connection: PostgresConnection, logger: Logger) async throws {
        let statements = [
            "DROP POLICY IF EXISTS internal_all ON loans",
            "DROP POLICY IF EXISTS organization_isolation ON loans",
            "DROP POLICY IF EXISTS tenant_isolation ON loans",
            "ALTER TABLE loans DISABLE ROW LEVEL SECURITY",
        ]

        for sql in statements {
            let query = PostgresQuery(unsafeSQL: sql)
            try await connection.query(query, logger: logger)
        }
    }
}
