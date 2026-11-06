# The application layer

XCore is the service: what it knows (domain models), what it decides (use cases), and what it needs from outside (repositories and ports), with no knowledge of how any of them is reached.

## Contents
- Domain models
- Errors
- Repositories and commands
- Ports
- A use case
- The body of a use case
- Transactions
- Authorization
- Logging

Its folders, an area per resource and `Ports/`, are in [the folder layout](packages.md#folder-layout).

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
| `XRepositoryError` | A repository adapter | Reasons the store reports that a use case acts on: `idempotencyConflict`, `duplicateEmail` |
| `<Service>ClientError` and other port errors | A port adapter | Reasons the remote side reports that a use case acts on: `unavailable` |
| `XUseCaseError` | The use case | Every outcome its caller handles differently, then `unknown` |

```swift
package enum BorrowBookUseCaseError: Error, Equatable, Sendable {
    case invalidIdempotencyKey
    case bookNotFound
    case loanLimitReached
    case idempotencyConflict
    case catalogUnavailable
    case unknown
}
```

- Each error is an enum, `Error, Equatable, Sendable`, with no associated values unless the caller acts on them, and without messages: a transport writes the message its caller reads ([status codes](grpc.md#status-codes)).
- A case names an outcome in the domain's terms (`bookNotFound`, `loanLimitReached`), never the failure that caused it (`queryFailed`).
- `unknown` is the use case's last case: everything it can't name, logged where it's thrown.
- A repository or port adapter raises only reasons it can detect, such as a constraint or a status code, and lets every other error propagate unchanged. A cache's read is the one exception ([Valkey](persistence.md#valkey)).

## Repositories and commands

```swift
package protocol LoanRepository: Sendable {
    func create(_ command: CreateLoanCommand) async throws -> Loan
    func loan(id: UUID) async throws -> Loan?
    func loan(userID: UUID, idempotencyKey: String) async throws -> Loan?
    func activeLoans(userID: UUID) async throws -> [Loan]
    func loans(userID: UUID, page: Int, pageSize: Int) async throws -> Page<Loan>
    func loans(startingAfter: UUID?, pageSize: Int) async throws -> KeyedPage<Loan>
    func markReturned(id: UUID) async throws -> Loan?
    func markOverdue(id: UUID) async throws -> Loan?
}

package enum LoanRepositoryError: Error, Equatable, Sendable {
    /// The idempotency key created a loan of another book.
    case idempotencyConflict
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

    package var totalPages: Int {
        (totalCount + pageSize - 1) / pageSize
    }

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

A port is what Core needs from outside the service's database: another service, a provider's capability, the workflow engine, or a store outside the transaction.

```swift
/// What Loans needs from Catalog: a book by id, in Loans' terms.
package protocol CatalogClient: Sendable {
    /// The book, or `nil` when Catalog has none with this id.
    func book(id: UUID) async throws -> Book?
}

package enum CatalogClientError: Error, Equatable, Sendable {
    case unavailable
}
```

| Port | Example | Implemented in |
|---|---|---|
| Another service | `CatalogClient` | XGRPC |
| A capability | `NoticeSender`, `PasswordHasher`, `NoticeEventVerifier` | `X<Provider>` |
| The workflow engine | `LoanWorkflowClient` | XTemporal |
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
- The implementation is generic over its database, `XUseCase<DatabaseType>` where `DatabaseType: Database` and `DatabaseType.Scope: XUseCaseScope`, so dispatch stays static. It holds its ports as `any Port`, a `Logger`, and a policy when its rules are tunable.
- Its scope protocol lists only what it uses. The scopes of the database roles it may run on adopt the protocol, so composing it on any other database doesn't compile ([database roles](persistence.md#database-roles)).
- An adapter holds it as `any XUseCaseProtocol` in a property named for the type (`borrowBookUseCase`) and calls it like a function: `try await borrowBookUseCase(subject: subject, input: input)`.
- A use case never calls another use case.

## The body of a use case

```swift
package import BookshelfAuthentication
package import Logging
package import Persistence

/// Lends the subject a copy of a book and starts the loan's workflow.
///
/// The member is the token's subject; the request names only the book. Runs on the tenant
/// database, where the policy confines the transaction to the member's own loans.
package struct BorrowBookUseCase<DatabaseType>: BorrowBookUseCaseProtocol
where DatabaseType: Database, DatabaseType.Scope: BorrowBookUseCaseScope {
    private let database: DatabaseType
    private let catalogClient: any CatalogClient
    private let loanWorkflowClient: any LoanWorkflowClient
    private let policy: LoanPolicy
    private let logger: Logger

    package init(
        database: DatabaseType,
        catalogClient: any CatalogClient,
        loanWorkflowClient: any LoanWorkflowClient,
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
                // A retry finds the loan its first attempt created, before the limit counts it.
                let existingLoan = try await scope.loanRepository.loan(userID: subject.userID, idempotencyKey: input.idempotencyKey)
                if let existingLoan, existingLoan.bookID == book.id {
                    return existingLoan
                }

                guard existingLoan == nil else {
                    logger.warning("Borrowing refused: idempotency key reused for another book")
                    throw BorrowBookUseCaseError.idempotencyConflict
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

            try await loanWorkflowClient.startLoan(loan)
            logger.info("Book borrowed", metadata: ["loanID": "\(loan.id)"])
            return loan
        } catch let error as BorrowBookUseCaseError {
            throw error
        } catch LoanRepositoryError.idempotencyConflict {
            logger.warning("Borrowing refused: idempotency key reused for another book")
            throw .idempotencyConflict
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

1. Input checks that need no data come first, before the `do`, throwing the case directly (`throw .invalidIdempotencyKey`).
2. One `do` holds the work through its `return`, in the order the requirement states it: look up, decide, write, start what follows. Each value a step takes is a `let` first ([build, then call](style.md#build-then-call)).
3. A refusal the use case decides is logged as a warning and thrown where it's decided, spelled with its type inside the `do` (`throw BorrowBookUseCaseError.bookNotFound`).
4. The catches, in this order: `catch let error as XUseCaseError { throw error }`, when the `do` throws the use case's own cases; one `catch` per case of a repository's or port's error that the caller acts on (`catch LoanRepositoryError.idempotencyConflict`), each logged and mapped to the use case's case; a final `catch` that logs an error with `String(reflecting: error)` and throws `.unknown`.
5. A completed change is logged at info with the ids it created or changed.
6. Nothing else: no helper methods and no workarounds ([reading like the requirement](style.md#reading-like-the-requirement)).

## Transactions

- A transaction holds a pooled connection until it ends, so it contains only database work. Remote calls go before it (the catalog lookup) or after it commits (the workflow start).
- A decision that must be atomic with its write happens inside the closure (the loan limit) and throws the use case's case; `PostgresDatabase` rolls back and rethrows the same error.
- A rule over rows that a concurrent transaction could change holds only with a lock or a constraint: `SELECT … FOR UPDATE`, or a unique or check constraint the repository maps to a case.
- A state change is the repository's conditional write ([state transitions](persistence.md#repositories-and-statements)); the use case maps its `nil` to its case (`alreadyReturned`).
- Work started after the commit is idempotent end to end. The row is keyed by the request's idempotency key and the workflow's id by the row, and the use case looks the key up before any rule counts rows, so a retry after a lost start finds its loan and starts the same workflow ([starting a workflow](workflows.md#starting-a-workflow-from-a-use-case)).
- The scope and its repositories never outlive the closure: nothing escapes it, and no task outlives it.

## Authorization

- The caller reaches a use case as `subject: UserIdentity`. A use case never reads `OperationContext`.
- **The caller's own.** The use case acts on `subject.userID`, never on a user id from its input, and runs on the tenant database, where row-level security confines it as well ([row-level security](persistence.md#row-level-security)).
- **Administrators.** The use case checks the role before anything else, then runs on the internal database in a service with tenant tables. The handler's `requireAdministrator()` is an early gate; the use case's check is the rule.
- **Internal callers.** The use case takes the user it acts for in its input; mTLS admitted the calling process.

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
- Metadata keys are lowerCamelCase ids (`loanID`, `bookID`), and `error` holds `String(reflecting: error)`.
- Never logged: tokens, passwords, secrets and their digests, email addresses, names, request bodies.
