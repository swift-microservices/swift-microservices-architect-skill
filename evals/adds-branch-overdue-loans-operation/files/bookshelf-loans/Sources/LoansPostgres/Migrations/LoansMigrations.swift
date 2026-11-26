package import PostgresMigrations

/// Every migration of Loans' database, in applied order. Append only.
package enum LoansMigrations {
    package static func all(
        database: String,
        serviceRole: String,
        internalRole: String
    ) -> [any DatabaseMigration] {
        let createServiceRole = CreateServiceRole(role: serviceRole, database: database)
        let createInternalRole = CreateInternalRole(role: internalRole, database: database)
        let createLoansTable = CreateLoansTable()
        let createLoansRLSPolicy = CreateLoansRLSPolicy(internalRole: internalRole)
        return [createServiceRole, createInternalRole, createLoansTable, createLoansRLSPolicy]
    }
}
