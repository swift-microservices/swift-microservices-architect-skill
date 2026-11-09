# The application layer

XCore is the service: what it knows (domain models), what it decides (use cases), how it plays out over time ([workflows](workflows.md)), and what it needs from outside (repositories and ports), with no knowledge of how any of them is reached.

## Contents
- Domain models
- Errors
- Repositories and commands
- Ports
- A use case
- The body of a use case
- System use cases
- Transactions
- Authorization
- Logging

Its folders, an area per resource, `Workflows/` and `Ports/`, are in [the folder layout](packages.md#folder-layout).

## Domain models

```swift
package struct Loan: Equatable, Sendable {
    package let id: UUID
    package let userID: UUID
    package let bookID: UUID
    package let status: LoanStatus
    package let dueDate: Date
    package let creationDate: Date

    package init(id: UUID, userID: UUID, bookID: UUID, status: LoanStatus, dueDate: Date, creationDate: Date) {
        …
    }
}

package enum LoanStatus: String, Equatable, Sendable {
    case active
    case overdue
    case returned
}
```

- A model is a `package struct` of `let` properties, `Equatable` and `Sendable`, with an explicit `package init`.
- It's named for what it is in the service's language ([naming](conventions.md#naming)).
- Its values follow [types and values](style.md#types-and-values); a string only where the domain has free text.
- A rule more than one use case applies lives on a model or a policy, never in a use case for another to copy: `LoanPolicy.dueDate(borrowedAt:)`, a throwing `EmailAddress(_:)` that normalizes and validates.
- Tunable rules are a policy value (`LoanPolicy`, with `maximumActiveLoans` and `loanPeriod`), passed to the use cases that apply it and read from configuration by the executable ([configuration](composition.md#configuration)).
- What the service knows about another service's data is its own model, in `Ports/`, beside the port that returns it: Loans' `Book` holds an id and a title, not Catalog's whole book.

## Errors

| Error | Thrown by | Cases |
|---|---|---|
| `XRepositoryError` | A repository adapter | Reasons the store reports that a use case acts on: `duplicateEmail` |
| `<Service>ClientError` and other port errors | A port adapter | Reasons the remote side reports that a use case acts on: `unavailable` |
| `XUseCaseError` | The use case | Every outcome its caller handles differently, then `unknown` |

```swift
package enum BorrowBookUseCaseError: Error, Equatable {
    case invalidIdempotencyKey
    case bookNotFound
    case loanLimitReached
    case idempotencyConflict
    case catalogUnavailable
    case unknown
}
```

- Each error is an enum, `Error, Equatable`, with no associated values unless the caller acts on them, and without messages: a transport writes the message its caller reads ([status codes](grpc.md#status-codes)).
- A case names an outcome in the domain's terms (`bookNotFound`, `loanLimitReached`), never the failure that caused it (`queryFailed`).
- `unknown` is the use case's last case: everything it can't name, logged where it's thrown.
- A repository or port adapter raises only reasons it can detect, such as a constraint or a status code, and lets every other error propagate unchanged. A cache's read is the one exception ([Valkey](persistence.md#valkey)).

## Repositories and commands

```swift
package protocol LoanRepository: Sendable {
    func lockLoans(userID: UUID) async throws
    func create(_ command: CreateLoanCommand) async throws -> Loan
    func loan(id: UUID) async throws -> Loan?
    func loan(userID: UUID, idempotencyKey: String) async throws -> Loan?
    func activeLoans(userID: UUID) async throws -> [Loan]
    func loans(userID: UUID, page: Int, pageSize: Int) async throws -> Page<Loan>
    func loans(startingAfter: UUID?, pageSize: Int) async throws -> KeyedPage<Loan>
    func markReturned(id: UUID) async throws -> Loan?
    func markOverdue(id: UUID) async throws -> Loan?
}

package struct CreateLoanCommand: Sendable {
    package let userID: UUID
    package let bookID: UUID
    package let dueDate: Date
    package let idempotencyKey: String

    package init(userID: UUID, bookID: UUID, dueDate: Date, idempotencyKey: String) {
        …
    }
}
```

- A repository is the persistence of one area, in Core's terms ([naming](conventions.md#naming)). A read of one row returns an optional (`loan(id:)`), of several an array (`activeLoans(userID:)`).
- A write that takes more than an id takes a command.
- Methods use untyped `async throws`: a driver throws errors the domain doesn't name, and `XRepositoryError` carries the few it does.
- A scope builds the repository on its transaction's connection ([database roles](persistence.md#database-roles)); nothing keeps one past the transaction.

A read of a list that can grow large returns one page, with its metadata, as one of Core's page types in `Paging/` ([lists and pages](grpc.md#lists-and-pages)):

```swift
/// One numbered page of a list, and where it sits in the whole list.
package struct Page<Item: Sendable>: Sendable {
    package let items: [Item]
    package let page: Int
    package let pageSize: Int
    package let totalCount: Int

    package var totalPages: Int { … }

    …
}

/// One page of a list read by key, and the id the next page starts after, if another follows.
package struct KeyedPage<Item: Sendable>: Sendable {
    package let items: [Item]
    package let nextCursor: UUID?

    …
}
```


## Ports

A port is what Core needs from outside the service's database: another service, a provider, or a store outside the transaction. Temporal is no port: [Core uses it directly](packages.md#what-core-may-link).

```swift
/// What Loans needs from Catalog: a book by id, in Loans' terms.
package protocol CatalogClient: Sendable {
    /// The book, or `nil` when Catalog has none with this id.
    func book(id: UUID) async throws -> Book?
}

package enum CatalogClientError: Error, Equatable {
    case unavailable
}
```

| Port | Example | Implemented in |
|---|---|---|
| Another service | `CatalogClient` | XGRPC |
| A provider | `NoticeSender`, `PasswordHasher`, `NoticeEventVerifier` | `X<Provider>` |
| A store outside the database | `ResetCodeRepository` | XValkey |

Ports and their implementations are named as [naming](conventions.md#naming) gives them.

- A port returns Core models in the consumer's words and uses untyped `async throws`.
- A port isn't in a scope: it isn't part of the transaction, so the use case holds it directly.

## A use case

There is one use case per operation: one per RPC, and one per database step an activity runs (`MarkLoanOverdue`). Its five files sit in `UseCases/<Name>/`:

```swift
package protocol BorrowBookUseCaseProtocol: Sendable {
    /// Lends the subject a copy of a book and starts the loan's workflow.
    func callAsFunction(
        subject: UserIdentity,
        input: BorrowBookUseCaseInput
    ) async throws(BorrowBookUseCaseError) -> Loan
}

package struct BorrowBookUseCaseInput: Sendable {
    package let bookID: UUID
    package let idempotencyKey: String

    package init(bookID: UUID, idempotencyKey: String) {
        self.bookID = bookID
        self.idempotencyKey = idempotencyKey
    }
}

package protocol BorrowBookUseCaseScope: Sendable {
    var loanRepository: any LoanRepository { get }
}
```

with the error above and the implementation below.

- A use case is named like its RPC ([naming](conventions.md#naming)).
- `callAsFunction` takes `subject: UserIdentity` first when it acts for a caller, then `input:` when the request carries values. A use case that needs neither takes neither.
- It returns a domain model, an array of them, a page of them, or nothing. A result that combines values is a domain type named for what it is (`Session`), never `XUseCaseOutput`.
- The input is a plain value of what the request carries. Wire validity, such as an id that isn't a UUID, is the conversion's to refuse ([conversions](grpc.md#conversions)); business validity is the use case's, as an error case.
- The implementation is generic over its database, `XUseCase<DatabaseType>` where `DatabaseType: Database` and `DatabaseType.Scope: XUseCaseScope`. It holds its ports as `any Port`, a `Logger`, and a policy when its rules are tunable.
- One that starts a workflow also holds what [starting a workflow](workflows.md#starting-a-workflow-from-a-use-case) names.
- Its scope protocol lists only what it uses. The scopes of the database roles it may run on adopt the protocol, so composing it on any other database doesn't compile ([database roles](persistence.md#database-roles)).
- An adapter holds it as `any XUseCaseProtocol` in a property named for the type (`borrowBookUseCase`) and calls it like a function: `try await borrowBookUseCase(subject: subject, input: input)`.

## The body of a use case

```swift
package import BookshelfAuthentication
package import Logging
package import Persistence
package import Temporal

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Lends the subject a copy of a book and starts the loan's workflow.
///
/// The member is the token's subject; the request names only the book. Runs on the tenant
/// database, where the policy confines the transaction to the member's own loans.
package struct BorrowBookUseCase<DatabaseType>: BorrowBookUseCaseProtocol
where DatabaseType: Database, DatabaseType.Scope: BorrowBookUseCaseScope {
    private let database: DatabaseType
    private let catalogClient: any CatalogClient
    private let temporalClient: TemporalClient
    private let taskQueue: String
    private let policy: LoanPolicy
    private let logger: Logger

    package init(
        database: DatabaseType,
        catalogClient: any CatalogClient,
        temporalClient: TemporalClient,
        taskQueue: String,
        policy: LoanPolicy,
        logger: Logger
    ) {
        …
    }

    package func callAsFunction(
        subject: UserIdentity,
        input: BorrowBookUseCaseInput
    ) async throws(BorrowBookUseCaseError) -> Loan {
        guard !input.idempotencyKey.isEmpty else {
            throw .invalidIdempotencyKey
        }

        do {
            guard let book = try await catalogClient.book(id: input.bookID) else {
                logger.warning("Borrowing refused: no such book", metadata: ["bookID": "\(input.bookID)"])
                throw BorrowBookUseCaseError.bookNotFound
            }

            let loan = try await database.withTransaction { scope in
                // One borrow per member at a time, so a retry in flight and the limit see each other's loans.
                try await scope.loanRepository.lockLoans(userID: subject.userID)

                // A retry returns the loan its first attempt created, before the limit counts it.
                let existingLoan = try await scope.loanRepository.loan(userID: subject.userID, idempotencyKey: input.idempotencyKey)
                if let existingLoan {
                    guard existingLoan.bookID == book.id else {
                        logger.warning("Borrowing refused: idempotency key reused for another book")
                        throw BorrowBookUseCaseError.idempotencyConflict
                    }

                    return existingLoan
                }

                let activeLoans = try await scope.loanRepository.activeLoans(userID: subject.userID)
                guard activeLoans.count < policy.maximumActiveLoans else {
                    logger.warning("Borrowing refused: loan limit reached")
                    throw BorrowBookUseCaseError.loanLimitReached
                }

                let dueDate = policy.dueDate(borrowedAt: .now)
                let command = CreateLoanCommand(
                    userID: subject.userID,
                    bookID: book.id,
                    dueDate: dueDate,
                    idempotencyKey: input.idempotencyKey
                )
                return try await scope.loanRepository.create(command)
            }

            let workflowID = LoanWorkflow.id(loanID: loan.id)
            let workflowOptions = WorkflowOptions(
                id: workflowID,
                taskQueue: taskQueue,
                idReusePolicy: .allowDuplicateFailedOnly,
                idConflictPolicy: .useExisting
            )
            let workflowInput = LoanWorkflow.Input(loanID: loan.id, userID: loan.userID, bookID: loan.bookID, dueDate: loan.dueDate)

            do {
                _ = try await temporalClient.startWorkflow(type: LoanWorkflow.self, options: workflowOptions, input: workflowInput)
                logger.info("Book borrowed", metadata: ["loanID": "\(loan.id)"])
                return loan
            } catch is WorkflowAlreadyStartedError {
                // A retry after the loan's run completed: its work is done.
                return loan
            }
        } catch let error as BorrowBookUseCaseError {
            throw error
        } catch CatalogClientError.unavailable {
            logger.warning("Borrowing failed: the catalog is unavailable")
            throw .catalogUnavailable
        } catch {
            logger.error(
                "Borrowing failed: unknown error",
                metadata: [
                    "bookID": "\(input.bookID)",
                    "error": "\(String(reflecting: error))",
                ]
            )
            throw .unknown
        }
    }
}
```

The body reads in the order the requirement states it: refuse what needs no data, look up, decide, write, start what follows, return. The catches come in this order: `catch let error as XUseCaseError { throw error }` when the `do` throws the use case's own cases; one `catch` per case of a repository's or port's error that the caller acts on (`catch CatalogClientError.unavailable`), logged and mapped to the use case's case; and a final `catch` that logs an error with `String(reflecting: error)` and throws `.unknown`. The rest follows [errors](style.md#errors), [build, then call](style.md#build-then-call) and [logging](#logging). The start follows [starting a workflow](workflows.md#starting-a-workflow-from-a-use-case).

## System use cases

A use case's actor is a person, through an RPC, or the system: time, or a workflow's step, through an activity. Use cases never call other use cases synchronously. One run triggering another later through a workflow isn't a use case calling a use case: they are separate runs with separate transactions.

```swift
package protocol MarkLoanOverdueUseCaseProtocol: Sendable {
    /// Marks a loan past its due date overdue, unless it was returned first.
    func callAsFunction(input: MarkLoanOverdueUseCaseInput) async throws(MarkLoanOverdueUseCaseError) -> Loan
}

package struct MarkLoanOverdueUseCaseInput: Sendable {
    package let loanID: UUID

    …
}
```

- A system use case takes no `subject`. Its input names what it acts on.
- Activities call system use cases only, never user-facing ones. A use case that checks the caller (`ReturnBook`) is never invoked from an activity with an invented identity.
- When a person and the system both need the same effect, each audience has its own use case: `MarkLoanOverdueUseCase` for the worker, and `MarkLoanOverdueByAdministratorUseCase`, which takes `subject` and checks the role. They share the domain rule, on a model or a policy, and the repository's conditional write (`markOverdue(id:)`), and neither calls the other.
- The worker scope adopts the system use cases' scope protocols, so wiring one on the tenant database fails to compile ([database roles](persistence.md#database-roles)).

## Transactions

- A transaction holds a pooled connection until it ends, so it contains only database work. Remote calls go before it (the catalog lookup) or after it commits (the workflow start).
- A decision that must be atomic with its write happens inside the closure (the loan limit) and throws the use case's case; `PostgresDatabase` rolls back and rethrows the same error.
- A rule over a count, such as the loan limit, first locks what it counts (`lockLoans(userID:)`), since `SELECT … FOR UPDATE` locks only rows that already exist; the lock ends with the transaction. A rule a constraint can state, such as a unique index, is that constraint, mapped to a case.
- A state change is the repository's conditional write ([state transitions](persistence.md#repositories-and-statements)); the use case maps its `nil` to its case (`alreadyReturned`).
- Work started after the commit is idempotent end to end. The row is keyed by the request's idempotency key and the workflow's id by the row, and the use case looks the key up before any rule counts rows, so a retry after a lost start finds its loan and starts the same workflow ([starting a workflow](workflows.md#starting-a-workflow-from-a-use-case)).
- The scope and its repositories never outlive the closure: nothing escapes it, and no task outlives it.

## Authorization

- The caller reaches a use case as `subject: UserIdentity`. A use case never reads `OperationContext`.
- **The caller's own.** The use case acts on `subject.userID`, never on a user id from its input, and runs on the tenant database, where row-level security confines it as well ([row-level security](persistence.md#row-level-security)).
- **Administrators.** The use case checks the role before anything else, then runs on the internal database in a service with tenant tables. The gateway's `AdministratorRequestContext` refuses earlier; the use case's check is the rule.
- **Internal callers.** The use case takes the user it acts for in its input; mTLS admitted the calling process.
- **The system.** A [system use case](#system-use-cases) acts for no caller and runs on the worker's database.

```swift
package func callAsFunction(
    subject: UserIdentity,
    input: ListAllLoansUseCaseInput
) async throws(ListAllLoansUseCaseError) -> KeyedPage<Loan> {
    guard subject.role == .admin else {
        logger.warning("Loan list refused: not an administrator")
        throw .forbidden
    }

    do {
        return try await database.withTransaction { scope in
            try await scope.loanRepository.loans(startingAfter: input.startingAfter, pageSize: input.pageSize)
        }
    } catch {
        logger.error("Loan list failed: unknown error", metadata: ["error": "\(String(reflecting: error))"])
        throw .unknown
    }
}
```

## Logging

- Each use case logs through the `Logger` it's built with; the metadata provider adds the caller's `userID` to every line of a request ([user tokens](security.md#user-tokens)).
- Levels: `info` for a completed change, `warning` for a refusal, `error` for `unknown`. A successful read logs nothing.
- Messages are short sentences: `Book borrowed`, `Borrowing refused: no such book`, `Borrowing failed: unknown error`.
- `error` holds `String(reflecting: error)`.
- Never logged: tokens, passwords, secrets and their digests, email addresses, names, request bodies.
