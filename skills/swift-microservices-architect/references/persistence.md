# Persistence

The Postgres adapter, database roles and row-level security, migrations, and Valkey.

This file gives the shapes: the roles, how the caller is bound, scopes, repositories, statements, pages and where migrations live. The SQL inside them follows `supabase-postgres-best-practices`: the grants and policy a table needs, the index under a policy's or a filter's columns, a column's type, what a migration locks. Where that skill differs, this file stands: its roles, the transaction-local binding rather than `auth.uid()` or a session's `SET`, UUID ids, and both kinds of page.

## Contents
- The Postgres target
- Database roles
- Connections and timeouts
- Row-level security
- Binding the tenant
- Organization tenants
- Repositories and statements
- Paged statements
- Migrations
- Valkey

## The Postgres target

XPostgres implements Core's repositories over swift-persistence-postgres and PostgresNIO. Folders are as [folders](conventions.md#folders) gives them. Scopes, `Extensions/` and migrations are `package`; repositories and statements are internal, since only scopes build them.

## Database roles

Each service's database has an owner and a role per purpose ([data placement](system.md#data-placement)). A process connects as one or more roles, each through its own `PostgresClient` and `PostgresDatabase`:

| Role | Connects | Sees | Scope |
|---|---|---|---|
| Owner | `migrate` and `build-indexes`, for migrations and indexes only ([Postgres](security.md#postgres)) | Everything; bypasses row-level security | none |
| `<x>_service` | `serve`, for anyone's and the caller's own RPCs | Tenant tables narrowed to the bound caller; untenanted tables whole | `Postgres<X>Scope` |
| `<x>_internal` | `serve`, for administrators' and internal RPCs, anyone's that reach tenant rows with no caller bound, such as a webhook, and a caller's that must reach rows outside the caller's tenant, such as adding someone who isn't a member yet | Every row, through its own policy | `Postgres<X>InternalScope` |
| `<x>_worker` | `worker run`, for [system use cases](use-cases.md#system-use-cases) | Every row, through its own policy | `Postgres<X>WorkerScope` |

`internal` in a role's name says no single tenant is bound: the use case confines the work, where a policy can't. It isn't the `Internal` of `XInternalService`, which says who calls; an administrators' RPC and a webhook run on the internal role too.

A service declares only the roles it uses ([data placement](system.md#data-placement)): Catalog has no tenant table and runs everything as `catalog_service`; its worker connects as that role too, so that role's scope also adopts the scope protocols of its system use cases. A use case runs on its role's `PostgresDatabase`: the tenant database (`<x>_service`), the internal database or the worker's database.

Row-level security holds while the role a caller's transaction runs as isn't a superuser, has no `BYPASSRLS` and doesn't own the table, and the caller is bound per transaction ([binding the tenant](#binding-the-tenant)). `CreateServiceRole` creates such roles; [Postgres](security.md#postgres) names the commands that log in as the owner.

The internal and worker roles see every row, so a query on them that acts for one user, a system use case's read for one user included, names that user in its own `WHERE`, and a write there names the tenant the same way, in its `WHERE` or its values. A read by id that relies on the tenant policy confines nothing there.

```swift
package import LoansCore
package import Logging
package import PersistencePostgres
package import PostgresNIO

/// A unit of work as `loans_service`, whose policy narrows `loans` to the bound caller's rows.
package struct PostgresLoansScope:
    PostgresScope, BorrowBookUseCaseScope, ReturnBookUseCaseScope, ListLoansUseCaseScope
{
    package let loanRepository: any LoanRepository

    package init(connection: PostgresConnection, logger: Logger) {
        self.loanRepository = PostgresLoanRepository(connection: connection, logger: logger)
    }
}
```

- A scope adopts exactly the scope protocols of the use cases that may run as its role. `PostgresLoansInternalScope` adopts `ListAllLoansUseCaseScope` and `ReceiveNoticeEventUseCaseScope`; `PostgresLoansWorkerScope` adopts `MarkLoanOverdueUseCaseScope`. Composing `ListAllLoansUseCase` on the tenant database then fails to compile, so which role a use case runs as is checked by the compiler.
- Several scopes hold the same repository types; each is built on its own role's connection.

## Connections and timeouts

Every role's `PostgresClient` is built from `<Project>Persistence`'s reader, `PostgresClient.Configuration(config:role:)`, which logs in as the plan's answer sets ([Postgres](security.md#postgres)):

- Each role's pool is bounded, and the pools of every process on one instance stay within its `max_connections`.
- A role that serves requests or runs activities starts each connection with `statement_timeout` and `idle_in_transaction_session_timeout`, so a slow statement fails before the caller's deadline and a stalled transaction releases its locks. The owner sets only `lock_timeout`, so a migration waits a bounded time for a table's lock, then runs as long as it needs.

## Row-level security

A tenant table's policy decides which rows each statement sees and writes, from the caller bound to the transaction:

```sql
ALTER TABLE loans ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON loans
    USING (user_id = (SELECT NULLIF(current_setting('app.caller_user_id', true), '')::uuid));

CREATE POLICY internal_all ON loans TO "loans_internal" USING (true);
CREATE POLICY worker_all ON loans TO "loans_worker" USING (true);
```

- `CreateLoansRLSPolicy(internalRole:workerRole:)` takes the role names from configuration, as `CreateServiceRole(role:database:)` does ([migrations](#migrations)), and quotes each as an identifier.
- The tenant policy is a predicate on the tenant and nothing else. Whether a caller is an administrator is decided in the use case, which runs on the internal role; a policy that reads a role is authorization in SQL, where the domain's rules can't see it.
- `NULLIF(…, '')` is required: once a pooled connection has carried the setting, reading it in a later transaction yields `''` rather than `NULL`, and `''::uuid` is an error rather than a non-match.
- Nothing bound means nothing visible: with no caller set, the tenant policy matches no row.
- Untenanted tables carry no policy: public data (`books`) and rows found by a secret on anonymous paths, where no caller is bound yet (refresh tokens by digest).

## Binding the tenant

The swift-microservices libraries and `<project>-core` carry the caller from the token to the transaction:

1. `BearerAuthenticationInterceptor` binds the token's `Principal<UserIdentity, String>` in `OperationContext`.
2. `UserSettingsInterceptor` from `<Project>Persistence`, applied after it to the same descriptors, binds `OperationContext.postgresSettings = .user(identity)`, which is `["app.caller_user_id": "<lowercased user id>"]`; with no user bound it binds nothing.
3. `PostgresDatabase.withTransaction` reads the settings from `OperationContext` as each transaction begins, applies them over its constant settings with `set_config(name, value, true)`, and only then builds the scope.
4. The setting is transaction-local: it ends with the transaction, by commit or rollback, so a pooled connection never carries one caller's setting into the next caller's transaction.

```swift
public struct UserSettingsInterceptor: ServerInterceptor {
    public init() {}

    public func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next:
            @concurrent @Sendable (
                _ request: StreamingServerRequest<Input>,
                _ context: ServerContext
            ) async throws -> StreamingServerResponse<Output>
    ) async throws -> StreamingServerResponse<Output> {
        …
    }
}
```

A service without tenant tables applies no `UserSettingsInterceptor`.

## Organization tenants

When rows belong to an organization the caller acts for, the organization is a second tenant beside the user. Bookshelf's librarians act for a branch, reading the loans it made:

```sql
CREATE POLICY organization_isolation ON loans FOR SELECT
    USING (branch_id = (SELECT NULLIF(current_setting('app.caller_organization_id', true), '')::uuid));
```

- The token names the organization its session acts for in `org`, an optional `organizationID` on `UserIdentity`; a session that acts for none carries none ([user tokens](security.md#user-tokens)). Acting for another organization takes a new token from Identity, proved by the refresh token.
- `PostgresSettings.user(_:)` binds `app.caller_organization_id` beside `app.caller_user_id`, only when the identity names an organization.
- The table's policy is `organization_isolation`, the tenant policy's predicate over the column that names the organization (`branch_id`). A table that users and organizations both own rows of, as `loans` is a member's and a branch's, carries both policies.
- A policy may reach its tenant through the table that links them, with the state that makes the link one: `USING (EXISTS (SELECT 1 FROM memberships WHERE … AND status = 'active'))`. It still reads no role.
- `USING` alone also checks what a statement writes, so a tenant writes only its own rows. A policy that only lets a tenant read is `FOR SELECT`. A table every caller reads and one organization writes carries `everyone_read FOR SELECT USING (true)` beside its tenant policy.
- Policies combine with `OR`: a role's `USING (true)` widens only that role, and a session acting for an organization reaches the organization's rows through the caller's own use cases too. A caller's own list names the user in its `WHERE` (`LoansByUserIDStatement`), and where the organization's policy lets it write, so does each of the caller's own writes.
- The use case reads the organization from `subject`, never from its input ([authorization](use-cases.md#authorization)).

## Repositories and statements

```swift
struct PostgresLoanRepository: LoanRepository {
    let connection: PostgresConnection
    let logger: Logger

    func activeLoans(userID: UUID) async throws -> [Loan] {
        let statement = ActiveLoansByUserIDStatement(userID: userID)
        let rows = try await connection.execute(statement, logger: logger)
        return try await Array(rows)
    }

    …
}

/// Creates a loan, or returns the one an earlier request with the same key created for the same book.
struct CreateLoanStatement: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO loans (idempotency_key, user_id, book_id, due_date)
        VALUES ($1, $2, $3, $4)
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
        bindings.append(command.dueDate)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Loan {
        try Loan(row: row)
    }
}
```

- Every query is a prepared statement with bindings; SQL is never built by interpolating values.
- A statement lists its columns, in the order `Model+PostgresRow.swift` decodes them as one tuple (`row.decode((UUID, UUID, …).self)`).
- An idempotent create is one statement. Its key is unique with its owner, as the constraint `<table>_idempotency_key_key` (`UNIQUE (user_id, idempotency_key)`), and its insert ends `ON CONFLICT ON CONSTRAINT <table>_idempotency_key_key DO UPDATE SET idempotency_key = EXCLUDED.idempotency_key WHERE` the stored values match the request's, then `RETURNING` the row. A retry gets back the row its first request created; a key reused for another request returns no row, which the repository throws as `LoanRepositoryError.idempotencyConflict`. The no-op `SET` is what makes the existing row come back, which `DO NOTHING` doesn't return.
- A rule over a count no constraint can state, such as the loan limit, takes a transaction-scoped advisory lock on what it counts, and nothing else takes one: `lockLoans(userID:)` runs `SELECT pg_advisory_xact_lock(hashtextextended('loans:' || $1::text, 0))`. The key starts with what it guards, so locks on different things for the same id don't wait on each other.
- Any other unique violation the use case acts on is mapped by constraint name: `catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505"`, then a `switch` on `error.serverInfo?[.constraintName]` that throws the repository's case or rethrows.
- A value unique only while its row is active, such as a member's one active loan of a book, is a partial unique index over the active states, `loans_active_user_id_book_id_key` in `CreateLoansTable` ([migrations](#migrations)). Its violation is mapped by name like any other, here to `LoanRepositoryError.alreadyBorrowed`; a check, then an insert, never stands in for it.
- A state transition is one statement whose `WHERE` names the states the row may leave: `UPDATE loans SET status = 'returned' WHERE id = $1 AND status <> 'returned' RETURNING …`. No row back means the row isn't in a state it may leave, such as a loan another transaction returned first, and the repository returns `nil` (`markReturned(id:) -> Loan?`). The method or command names only the destination; a read, a decision in Swift and an unconditional write never stand in for it.
- The `WHERE` names the source states, never the destination, so a repeat of the same transition finds no row. A transition that a stored value guards names that value too: `markOverdue(id:)` runs `UPDATE loans SET status = 'overdue' WHERE id = $1 AND status = 'active' AND due_date <= now() RETURNING …`, so a loan extended after its run woke stays active.
- A transition that also writes other columns, or that returns the row to a state it may leave again, keeps each of those writes repeat-safe on its own: it sets a value, never adds to one.
- A write that returns its row takes the first of `RETURNING`'s rows. A stored value its type refuses to decode throws the decoding error, which propagates like a driver's ([errors](use-cases.md#errors)).
- A delete is conditional like any transition: its `WHERE` names the row and, on a role that sees every row, its tenant, and it returns the deleted row or `nil`. A read, an ownership check in Swift and a delete by id never stand in for it.
- Ids default in the database (`uuidv7()` on Postgres 18 and later), as do creation and update dates; commands carry neither.

## Paged statements

A page by page number is two statements on the transaction's connection, the page and the count ([lists and pages](grpc.md#lists-and-pages)):

```swift
struct LoansByUserIDStatement: PostgresPreparedStatement {
    static let sql = """
        SELECT id, user_id, book_id, status, due_date, creation_date
        FROM loans
        WHERE user_id = $1
        ORDER BY id DESC
        LIMIT $2 OFFSET ($3 - 1) * $2
        """

    …
}
```

- `CountLoansByUserIDStatement` is `SELECT count(*) FROM loans WHERE user_id = $1`, decoding an `Int`. The repository runs both and returns `Page(items:page:pageSize:totalCount:)`.
- A page by key reads one row more than the page size, so the repository knows whether another page follows: `WHERE id < COALESCE($1, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid) ORDER BY id DESC LIMIT $2 + 1`, the greatest UUID standing for no cursor, never `$1 IS NULL OR id < $1`. It returns `KeyedPage(items:nextCursor:)` without the extra row and, when that row came back, the last kept item's id as the cursor.
- Both order by `id DESC`, so the primary key's index serves every page, and the statement, not Swift, turns a page number into an offset.
- A list with an order of its own, such as a book's loans by due date, pages by number and orders by its columns, then `id`, so the order is total. An order the client chooses is a Core enum the statement maps to a fixed `ORDER BY` with a `CASE` over the bound raw value; a column name is never interpolated.
- A read with more than two or three filters takes them as one value, `<Resource>Query` ([folders](conventions.md#folders)). A search's predicate uses the operator its index serves, and its threshold is the policy's.

## Migrations

```swift
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
```

- One migration per change, each its own type named for what it does, since postgres-migrations records a migration by its type's name: `CreateServiceRole`, `CreateInternalRole`, `CreateWorkerRole`, `CreateLoansTable`, `CreateLoansRLSPolicy`, `AddLoansReturnDate`. The roles come first, since a policy's `TO` names them.
- A migration keeps the schema usable by the image before it, since a rollback runs that image on the current schema ([the deployment contract](delivery.md#the-deployment-contract)): it expands now and contracts in a later deploy, and a change that renames or moves data ships with code that reads both shapes.
- Migrations create the roles, since the database and its owner exist before the service first deploys; the owner has `CREATEROLE` for them. Role names are cluster-wide, so they carry the service's name (`loans_service`). `CreateServiceRole(role:database:)` creates the login role and grants it `CONNECT`, schema usage, `SELECT, INSERT, UPDATE, DELETE` on tables and `USAGE` on sequences, and the same for future tables through default privileges; never `ALL`, since `TRUNCATE` ignores row-level security. How a role logs in is the plan's answer ([Postgres](security.md#postgres)); when it's a password, `Migrations.apply()` runs the list and then sets each role's password from its file (`ALTER ROLE … PASSWORD`), since a migration runs once, and rotating one is a configuration change and a deploy. Role names, and any passwords, come from configuration and are quoted into `PostgresQuery(unsafeSQL:)`, since a statement that names a role takes no bindings.
- XPostgres states the order once, in `Migrations/LoansMigrations.swift`, so the executable and `XPostgresTests` apply the same list:

```swift
/// Every migration of Loans' database, in applied order. Append only.
package enum LoansMigrations {
    package static func all(
        database: String,
        serviceRole: String,
        internalRole: String,
        workerRole: String
    ) -> [any DatabaseMigration] {
        let createServiceRole = CreateServiceRole(role: serviceRole, database: database)
        …
        let createLoansTable = CreateLoansTable()
        let createLoansRLSPolicy = CreateLoansRLSPolicy(internalRole: internalRole, workerRole: workerRole)
        return [createServiceRole, …, createLoansTable, createLoansRLSPolicy]
    }
}
```

- The executable's `Database/Migrations.swift` reads the names from configuration, adds the list with `add(contentsOf:)` and applies it with `options: .ignoreUnknownMigrations`, so a rolled-back image starts on a schema holding migrations its list lacks instead of refusing to start. The list is append-only: postgres-migrations refuses a reordered list, and an applied migration is never edited or renamed.
- `migrate` applies them over a short-lived client, `PostgresClient.withClient(configuration:logger:operation:)` ([commands](composition.md#commands)).
- Every pending migration applies in one transaction, which holds each lock it takes until the last migration commits. An index on a table that already holds many rows is built with `CREATE INDEX CONCURRENTLY`, which can't run in a transaction and doesn't block writes: XPostgres lists those in `Migrations/LoansIndexes.swift`, and `loans build-indexes` runs each as `CREATE INDEX CONCURRENTLY IF NOT EXISTS`, first dropping one that an interrupted build left invalid ([commands](composition.md#commands)).
- A backfill of existing rows is never a migration: it's a short-lived command on the internal role ([commands](composition.md#commands)) that updates in batches by id, each batch its own transaction, between the deploy that adds the column and the one that relies on it.
- One process migrates, before serve and the worker start: postgres-migrations takes no lock, so processes that apply at once race and all but one fail ([the deployment contract](delivery.md#the-deployment-contract)).

## Valkey

Valkey holds short-lived values with an expiry: one-time codes, challenges, rate counters, caches. It is never part of a database transaction, and never holds data that must survive a restart of the store. The repository's shape is this section's; which command an operation takes, with its expiry and atomicity, follows `valkey`.

Identity keeps password reset codes there:

```swift
package import IdentityCore
package import Valkey

#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

/// A user's reset code, as its digest, from the moment it's sent until it's redeemed or expires.
package struct ValkeyResetCodeRepository<Client: ValkeyClientProtocol>: ResetCodeRepository {
    private let client: Client

    package init(client: Client) {
        self.client = client
    }

    /// `SET` with an expiry under `identity:reset-code:<user id>`, replacing the user's last code.
    package func store(_ resetCode: ResetCode, lifetime: Duration) async throws {
        …
    }

    /// `DELIFEQ`, so the code is redeemed once even when two requests race, and a wrong one stays stored.
    package func redeem(userID: UUID, digest: String) async throws -> Bool {
        …
    }
}
```

- The repository is generic over `ValkeyClientProtocol`, takes the client in its initializer, and lives in XValkey; the use case holds it as a port.
- A reset code is keyed by its user and stored as its digest ([secrets](security.md#secrets)).
- Keys are as [naming](conventions.md#naming) gives them, so services sharing an instance never collide, and each service's ACL user reaches only its own ([the trust model](security.md#the-trust-model)).
- Every write sets its expiry, passed by the use case from its policy, never configured in the store.
- A cache is never the source of truth and never holds a decision. Its expiry is the use case's staleness budget, and its read answers `nil` on a miss and on a Valkey error, which the repository logs as a warning, so the use case reads the database and carries on.
- A use case that changes a cached value's source deletes its key after the transaction commits, never before, so no read refills it from the old row; a delete that fails is logged as a warning, and the expiry bounds how long the value stays stale.
- A value for one user is keyed by that user too, since Valkey has no row-level security.
- The executable builds one `ValkeyClient` over TLS ([configuration](composition.md#configuration)).
