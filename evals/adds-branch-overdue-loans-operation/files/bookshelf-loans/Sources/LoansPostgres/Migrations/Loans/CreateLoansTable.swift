package import Logging
package import PostgresMigrations
package import PostgresNIO

/// Creates `loans`, each a member's loan of a book from the branch that lent it.
package struct CreateLoansTable: DatabaseMigration {
    package init() {}

    package func apply(connection: PostgresConnection, logger: Logger) async throws {
        try await connection.query(
            """
            CREATE TABLE loans (
                id UUID PRIMARY KEY DEFAULT uuidv7(),
                idempotency_key TEXT NOT NULL,
                user_id UUID NOT NULL,
                book_id UUID NOT NULL,
                branch_id UUID NOT NULL,
                status TEXT NOT NULL DEFAULT 'active',
                due_date TIMESTAMPTZ NOT NULL,
                creation_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                CONSTRAINT loans_idempotency_key_key UNIQUE (user_id, idempotency_key)
            )
            """,
            logger: logger
        )
        try await connection.query(
            """
            CREATE UNIQUE INDEX loans_active_user_id_book_id_key ON loans (user_id, book_id)
            WHERE status <> 'returned'
            """,
            logger: logger
        )
    }

    package func revert(connection: PostgresConnection, logger: Logger) async throws {
        try await connection.query("DROP TABLE IF EXISTS loans", logger: logger)
    }
}
