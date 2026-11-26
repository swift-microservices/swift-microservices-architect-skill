import LoansCore
import PostgresNIO

/// Creates a loan, or returns the one an earlier request with the same key created for the same book.
struct CreateLoanStatement: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO loans (idempotency_key, user_id, book_id, branch_id, due_date)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT ON CONSTRAINT loans_idempotency_key_key DO UPDATE
            SET idempotency_key = EXCLUDED.idempotency_key
            WHERE loans.book_id = EXCLUDED.book_id
        RETURNING id, user_id, book_id, status, due_date, creation_date
        """

    let command: CreateLoanCommand

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings()
        bindings.append(command.idempotencyKey)
        bindings.append(command.userID)
        bindings.append(command.bookID)
        bindings.append(command.branchID)
        bindings.append(command.dueDate)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Loan {
        try Loan(row: row)
    }
}
