/// The indexes `loans build-indexes` builds with `CREATE INDEX CONCURRENTLY`, outside the migrations'
/// transaction, so building one on a table that already holds many rows blocks no writes. Append only.
package enum LoansIndexes {
    /// Each index's name, and its definition after `CREATE INDEX CONCURRENTLY IF NOT EXISTS <name>`.
    package static let all: [(name: String, definition: String)] = [
        (name: "loans_user_id_id_idx", definition: "ON loans (user_id, id DESC)")
    ]
}
