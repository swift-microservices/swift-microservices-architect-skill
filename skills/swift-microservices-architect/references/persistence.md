# Persistence

The Postgres adapter, database roles and row-level security, migrations, and Valkey.

## Contents
- The Postgres target
- Database roles
- Row-level security
- Binding the tenant
- Repositories and statements
- Paged statements
- Migrations
- Valkey

## The Postgres target

XPostgres implements Core's repositories over swift-persistence-postgres and PostgresNIO:

| Folder | Holds | Access |
|---|---|---|
| `Scopes/` | `Postgres<X>Scope` per database role | `package` |
| `Repositories/<Area>/` | `Postgres<Name>Repository` | internal: only scopes build them |
| `Statements/<Area>/` | A `PostgresPreparedStatement` per query, and `Model+PostgresRow.swift` | internal |
| `Extensions/` | `Enum+PostgresCodable.swift` for Core enums stored as text | `package` |
| `Migrations/<Area>/`, `Migrations/Role/` | A `DatabaseMigration` per change | `package` |

## Database roles

Each service's database has an owner and a role per purpose. A process connects as one or more roles, each through its own `PostgresClient` and `PostgresDatabase`:

| Role | Connects | Sees | Scope |
|---|---|---|---|
| Owner | `serve --migrate-database`, for migrations only | Everything; bypasses row-level security | none |
| `<x>_service` | `serve`, for anyone's and the caller's own RPCs | Tenant tables narrowed to the bound caller; untenanted tables whole | `Postgres<X>Scope` |
| `<x>_internal` | `serve`, for administrators' and internal RPCs, and anyone's that reach tenant rows with no caller bound, such as a webhook | Every row, through its own policy | `Postgres<X>InternalScope` |
| `<x>_worker` | `worker run`, for activities | Every row, through its own policy | `Postgres<X>WorkerScope` |

A service declares only the roles it uses: Catalog has no tenant table and runs everything as `catalog_service`. A use case runs on its role's `PostgresDatabase`: the tenant database (`<x>_service`), the internal database or the worker's database.

The internal and worker roles see every row, so a query on them that acts for one user names that user in its own `WHERE`. A read by id that relies on the tenant policy confines nothing there.

```swift
package import LoansCore
package import Logging
import PersistencePostgres
package import PostgresNIO

/// A unit of work as `loans_service`, whose policy narrows `loans` to the bound caller's rows.
package struct PostgresLoansScope: PostgresScope, BorrowBookUseCaseScope, ReturnBookUseCaseScope, ListLoansUseCaseScope {
    package let loanRepository: any LoanRepository

    package init(connection: PostgresConnection, logger: Logger) {
        self.loanRepository = PostgresLoanRepository(connection: connection, logger: logger)
    }
}
```

- A scope adopts exactly the scope protocols of the use cases that may run as its role. `PostgresLoansInternalScope` adopts `ListAllLoansUseCaseScope` and `ReceiveNoticeEventUseCaseScope`; `PostgresLoansWorkerScope` adopts `MarkLoanOverdueUseCaseScope`. Composing `ListAllLoansUseCase` on the tenant database then fails to compile, so which role a use case runs as is checked by the compiler.
- Several scopes hold the same repository types; each is built on its own role's connection.

## Row-level security

A tenant table's policy decides which rows each statement sees and writes, from the caller bound to the transaction:

```sql
ALTER TABLE loans ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON loans
    USING (user_id = NULLIF(current_setting('app.caller_user_id', true), '')::uuid);

CREATE POLICY internal_all ON loans TO "loans_internal" USING (true);
CREATE POLICY worker_all ON loans TO "loans_worker" USING (true);
```

- `CreateLoansRLSPolicy(internalRole:workerRole:)` takes the role names from configuration, as `CreateServiceRole(role:database:)` does ([migrations](#migrations)), and quotes each as an identifier.
- The tenant policy is a predicate on the tenant and nothing else. Whether a caller is an administrator is decided in the use case, which runs on the internal role; a policy that reads a role is authorization in SQL, where the domain's rules can't see it.
- `NULLIF(…, '')` is required: once a pooled connection has carried the setting, reading it in a later transaction yields `''` rather than `NULL`, and `''::uuid` is an error rather than a non-match.
- Policies combine with `OR`, so a role's `USING (true)` widens only that role.
- Nothing bound means nothing visible: with no caller set, the tenant policy matches no row. A service running as its owner or a superuser bypasses every policy, so processes always connect as their roles.
- Untenanted tables carry no policy: public data (`books`) and rows found by a secret on anonymous paths, where no caller is bound yet (refresh tokens by digest).

## Binding the tenant

The swift-microservices libraries and the org core carry the caller from the token to the transaction:

1. `BearerAuthenticationInterceptor` binds the token's `Principal<UserIdentity, String>` in `OperationContext`.
2. `UserSettingsInterceptor` from `<Org>Persistence`, applied after it to the same descriptors, binds `OperationContext.postgresSettings = .user(identity)`, which is `["app.caller_user_id": "<lowercased user id>"]`.
3. `PostgresDatabase.withTransaction` reads the settings from `OperationContext` as each transaction begins, applies them over its constant settings with `set_config(name, value, true)`, and only then builds the scope.
4. The setting is transaction-local: it ends with the transaction, by commit or rollback, so a pooled connection never carries one caller's setting into the next caller's transaction.

```swift
public struct UserSettingsInterceptor: ServerInterceptor {
    public init() {}

    public func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next: @concurrent @Sendable (
            _ request: StreamingServerRequest<Input>,
            _ context: ServerContext
        ) async throws -> StreamingServerResponse<Output>
    ) async throws -> StreamingServerResponse<Output> {
        var operationContext = OperationContext.current
        guard let user = operationContext.user else {
            return try await next(request, context)
        }

        operationContext.postgresSettings = .user(user.identity)
        return try await OperationContext.withContext(operationContext) {
            try await next(request, context)
        }
    }
}
```

A service without tenant tables applies no `UserSettingsInterceptor`.

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

struct CreateLoanStatement: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO loans (idempotency_key, user_id, book_id, due_date)
        VALUES ($1, $2, $3, $4)
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
- An idempotency key is unique with its user, `UNIQUE (user_id, idempotency_key)`, and its insert is plain: the use case finds a retry by its key first ([transactions](use-cases.md#transactions)).
- A unique violation the use case acts on is mapped by constraint name: `catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505"`, then a `switch` on `error.serverInfo?[.constraintName]` that throws the repository's case or rethrows.
- A value unique only while its row is active, such as a member's one active loan of a book, is a partial unique index over the active states: `CREATE UNIQUE INDEX loans_active_user_id_book_id_key ON loans (user_id, book_id) WHERE status <> 'returned'`. Its violation is mapped by name like any other; a check, then an insert, never stands in for it.
- A state transition is one statement whose `WHERE` names the states the row may leave: `UPDATE loans SET status = 'returned' WHERE id = $1 AND status <> 'returned' RETURNING …`. No row back means the row isn't in a state it may leave, such as a loan another transaction returned first, and the repository returns `nil` (`markReturned(id:) -> Loan?`). The method or command names only the destination; a read, a decision in Swift and an unconditional write never stand in for it.
- A Core enum stored as text conforms to `PostgresNonThrowingEncodable` and `PostgresDecodable` through its raw value, in `Extensions/`.
- Ids default in the database (`uuidv7()` on Postgres 18 and later), as do creation and update dates; commands carry neither.

## Paged statements

A numbered page is two statements on the transaction's connection, the page and the count ([lists and pages](grpc.md#lists-and-pages)):

```swift
struct LoansByUserIDStatement: PostgresPreparedStatement {
    static let sql = """
        SELECT id, user_id, book_id, status, due_date, creation_date
        FROM loans
        WHERE user_id = $1
        ORDER BY id DESC
        LIMIT $2 OFFSET ($3 - 1) * $2
        """

    let userID: UUID
    let page: Int
    let pageSize: Int

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings()
        bindings.append(userID)
        bindings.append(pageSize)
        bindings.append(page)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Loan {
        try Loan(row: row)
    }
}
```

- `CountLoansByUserIDStatement` is `SELECT count(*) FROM loans WHERE user_id = $1`, decoding an `Int`. The repository runs both and returns `Page(items:page:pageSize:totalCount:)`.
- A page by key reads one row more than the page size, so the repository knows whether another page follows: `WHERE $1::uuid IS NULL OR id < $1 ORDER BY id DESC LIMIT $2 + 1`. It returns `KeyedPage(items:nextCursor:)` without the extra row and, when that row came back, the last kept item's id as the cursor.
- Both order by `id DESC`, so the primary key's index serves every page, and the statement, not Swift, turns a page number into an offset.

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
                UNIQUE (user_id, idempotency_key)
            )
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
- One SQL statement per `connection.query`: PostgresNIO sends every query as a prepared statement, and Postgres refuses several commands in one. `CreateLoansRLSPolicy` runs four.
- A migration keeps the schema usable by the image before it, since a rollback runs that image on the current schema ([deployment](delivery.md#a-services-ci-workflows)): it expands now and contracts in a later deploy, and a change that renames or moves data ships with code that reads both shapes.
- Migrations create the roles, since the database and its owner exist before the service first deploys; the owner has `CREATEROLE` for them. Role names are cluster-wide, so they carry the service's name (`loans_service`). `CreateServiceRole(role:database:)` creates the login role and grants it `CONNECT`, schema usage, `SELECT, INSERT, UPDATE, DELETE` on tables and `USAGE` on sequences, and the same for future tables through default privileges; never `ALL`, since `TRUNCATE` ignores row-level security. A migration runs once, so `Migrations.apply()` runs the list and then sets each role's password from configuration (`ALTER ROLE … PASSWORD`), and rotating one is a configuration change and a deploy. Role names and passwords come from configuration and are quoted into `PostgresQuery(unsafeSQL:)`, since a statement that names a role takes no bindings.
- The executable's `Database/Migrations.swift` lists them in applied order. The list is append-only: postgres-migrations refuses a reordered list, and an applied migration is never edited or renamed.
- `serve --migrate-database` applies them as the owner over a short-lived client, `PostgresClient.withClient(configuration:logger:operation:)`, before the role clients and the `ServiceGroup` are built ([commands](composition.md#commands)).
- One process migrates, before the serving replicas start: postgres-migrations takes no lock, so replicas that apply at once race and all but one fail. `serve --migrate-database` runs in one process, deployed first ([a service's CI workflows](delivery.md#a-services-ci-workflows)); every other serve replica runs without the flag.

## Valkey

Valkey holds short-lived values with an expiry: one-time codes, challenges, rate counters, caches. It is never part of a database transaction, and never holds data that must survive a restart of the store.

Identity keeps password reset codes there:

```swift
package import IdentityCore
package import Valkey

/// A reset code from the moment it's sent until it's redeemed or expires.
package struct ValkeyResetCodeRepository<Client: ValkeyClientProtocol>: ResetCodeRepository {
    private let client: Client

    package init(client: Client) {
        self.client = client
    }

    package func store(_ code: ResetCode, lifetime: Duration) async throws {
        …  // SET with an expiry, under identity:reset-code:<code>
    }

    /// `GETDEL`, so a code is redeemed once even when two requests race.
    package func redeem(_ code: String) async throws -> UUID? {
        …
    }
}
```

- The repository is generic over `ValkeyClientProtocol`, takes the client in its initializer, and lives in XValkey; the use case holds it as a port.
- Keys are `<x>:<purpose>:<id>` (`identity:reset-code:…`), so services sharing an instance never collide.
- Every write sets its expiry, passed by the use case from its policy, never configured in the store.
- A read that must happen once is atomic: `GETDEL`, not a read followed by a delete. Several commands that must apply together go in a transaction (`client.transaction(…)`); several independent ones in a pipeline (`client.execute(…)`).
- A rate limit is `INCR` and `EXPIRE … NX` in one transaction, so the first increment opens the window and no counter outlives it.
- A cache is never the source of truth and never holds a decision. Its expiry is the use case's staleness budget, and its read answers `nil` on a miss and on a Valkey error, which the repository logs as a warning, so the use case reads the database and carries on.
- A value for one user is keyed by that user too, since Valkey has no row-level security.
- The executable reads `ValkeyClientConfiguration(configReader:)` into a `let`, builds one `ValkeyClient(.hostname(host, port: port), configuration: valkeyConfiguration, logger: logger)` from it, and runs it in the `ServiceGroup` ([composition](composition.md#the-composition-root)).
