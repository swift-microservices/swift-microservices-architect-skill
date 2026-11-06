# Swift style

How the code reads: the bar for readability, error handling, strict concurrency, access control and imports, Foundation, types, documentation and formatting.

## Contents
- Reading like the requirement
- Build, then call
- Errors
- Concurrency
- Access control and imports
- Foundation
- Types and values
- Documentation comments
- Formatting

## Reading like the requirement

The bar is the sample code in Apple's WWDC sessions, such as *Meet async/await in Swift*, *Embrace Swift generics*, *Beyond the basics of structured concurrency* and *Migrate your app to Swift 6*: small types named for their role, straight-line async code, early exits, nothing clever.

- A use case's `callAsFunction`, a workflow's `run`, an activity and a handler read top to bottom as the requirement they implement: refuse what isn't allowed, do the work, record what happened, return.
- No private helper methods in use cases, workflows or activities. A step that deserves a name is a policy's or model's method (`policy.dueDate(borrowedAt:)`), a port, another activity or a child workflow; a body too long to read at once is two use cases.
- No workarounds: no `Result` juggling, flags that steer control flow, `try?` that hides a failure, nested `do` inside a `catch`, force unwraps or `as!`.
- `guard` for refusals and unwrapping, with the `else` doing one thing. `switch` over every case of an enum outcome; `if case` only when one case matters.
- Names say what a value is: `activeLoans`, `isMarkedOverdue`, `catalogConfig`; never `result`, `data`, `flag` or a type's name.
- Tunable numbers are named where they belong: `ActivityOptions.notification`, `LoanPolicy.maximumActiveLoans`; never an inline literal in a workflow or use case.
- `// MARK: -` names the sections of a composition root and the groups of a service's RPCs.
- Code that a reader would otherwise check twice gets a one-line comment with the reason: a business rule, an ordering constraint, a safety property. A comment never narrates the next line.

## Build, then call

A value a call takes is built first, in a `let` named for what it is, and the call takes the name:

```swift
let statement = ActiveLoansByUserIDStatement(userID: userID)
let rows = try await connection.execute(statement, logger: logger)
```

- Arguments are names, literals, properties, closures, static members built from those (`.seconds(30)`, `.dns(host: host, port: port)`) and initializers over constants (`ErrorMiddleware()`, `RetryPolicy(initialInterval: .seconds(1), …)`).
- Anything else is a `let` first: an initializer that takes a variable, a conversion, a method's result, a `try` or an `await`. That holds for statements, requests, inputs, commands, configurations, transports, clients and use cases alike.
- Two forms stay inline: interpolation in a log line (`"\(String(reflecting: error))"`), and Hummingbird's route builder (`loanController.addAuthenticatedRoutes(to: authenticated.group("loans"))`).

## Errors

- A use case declares its error with typed throws ([SE-0413](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md)): `async throws(BorrowBookUseCaseError) -> Loan`. Repositories, ports, clients and handlers use untyped `throws`.
- Errors are mapped with `do` and one `catch` per case: `catch LoanRepositoryError.idempotencyConflict { throw .idempotencyConflict }`. The order and the final `catch` are in [the body of a use case](use-cases.md#the-body-of-a-use-case); a handler maps every case and has no final `catch` ([a handler](grpc.md#a-handler)).
- The `do` holds the whole path, from the first step of the work through its `return`. Only refusals come before it: requiring the caller, converting the request, checking input that needs no data.
- Each `catch` ends its own path, by throwing or by returning what its case means (`nil` for `notFound`). Nothing is declared before the `do` for a `catch` to fill in, and no code follows the `do`.
- Inside a typed-throws function and outside a `do`, `throw .case` takes its type from the function. Inside a `do`, a `throw` has no contextual type and is spelled in full: `throw BorrowBookUseCaseError.bookNotFound`.
- An error enum has no associated values unless the caller acts on them, and no messages: a transport writes the message ([status codes](grpc.md#status-codes)).
- `String(reflecting: error)` goes into the log line of an unknown error, never into a response.
- `CancellationError` propagates; nothing catches it to carry on.

## Concurrency

Every package builds with [the Swift settings](packages.md#swift-settings).

- Everything that crosses a boundary is `Sendable`: models, inputs, commands, errors, protocols. Structs and enums by default; an actor only for mutable state shared across tasks; `Mutex` from `Synchronization` for a small piece of state touched synchronously.
- No `@unchecked Sendable`, `nonisolated(unsafe)` or `@preconcurrency` in owned code. When a dependency needs one, it appears once, in the adapter that wraps the dependency, with the reason beside it.
- No unstructured tasks in a service. Long-running work is a `Service` in the `ServiceGroup`; work that must outlive a request is a [workflow](workflows.md#when-work-is-a-workflow); concurrency inside a request is `async let` or a task group, which end with the request.
- With `NonisolatedNonsendingByDefault` ([SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)) an `async` function runs on its caller's isolation, and so does a plain `async` closure such as a transaction's. `@concurrent` marks work that must leave its caller's actor.
- A requirement declared by a library built without that feature is implemented with its signature exactly as declared, `@concurrent` included: Hummingbird's `RouterMiddleware.handle` takes `next: @concurrent (Request, Context) async throws -> Response`, and grpc-swift's interceptors take `next: @concurrent @Sendable (…)`. An unannotated `async` closure type there means something else and fails to conform.
- CPU-heavy synchronous work, such as hashing a password, runs on `NIOThreadPool.singleton.runIfActive { … }`, off the cooperative pool.
- No server type is `@MainActor`.

## Access control and imports

- Inside a service's package, what another target uses is `package` ([SE-0386](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0386-package-access-modifier.md)), the rest internal or `private`. `public` is for libraries other packages link: `<org>-core`, `<org>-protos`.
- A `package` struct spells its `package init`, since the memberwise initializer is internal.
- Imports are internal by default ([SE-0409](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md)). A file imports a module `package` when the module's types appear in its `package` declarations, `public` when in `public` ones, and plainly otherwise.
- A file imports every module whose members it uses, since `MemberImportVisibility` ([SE-0444](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md)) hides members of modules it doesn't import.
- Access levels go on members, never on an extension.

## Foundation

Owned code imports Foundation's essentials only, with the access level the file needs:

```swift
#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif
```

- A file imports it only when it uses a Foundation type, after its other imports.
- With this import and `MemberImportVisibility`, code that reaches for full Foundation fails to compile on every platform, so it's caught where it's written.
- Modern Foundation and standard library APIs only:

| Instead of | Use |
|---|---|
| `DateFormatter`, `ISO8601DateFormatter` | `Date.ISO8601FormatStyle`: `date.formatted(.iso8601)`, `try Date(string, strategy: .iso8601)` |
| `NumberFormatter`, localized date formatters | `FormatStyle`s (`.number`, `.currency(code:)`, `Date.FormatStyle`), imported from `FoundationInternationalization` only where text is formatted for people |
| `NSRegularExpression` | Swift `Regex` |
| `JSONSerialization` | `Codable` with `JSONEncoder` and `JSONDecoder` |
| `URLSession` | AsyncHTTPClient |
| `TimeInterval` timeouts, `DispatchTime` | `Duration`: `.seconds(30)`, `.milliseconds(500)` |
| `Date()` | `Date.now` |
| `URL(fileURLWithPath:)` | `URL(filePath:)` |
| `DispatchQueue`, `NSLock`, `Thread` | Structured concurrency, actors, `Mutex` |

- A dependency's traits decide whether it links full Foundation; a service declares them so it doesn't ([traits and Foundation](packages.md#traits-and-foundation)).

## Types and values

- Models, inputs, commands and outputs are structs of `let` properties. Closed sets are enums (`LoanStatus`); a set other services may extend is a `RawRepresentable` string struct with static members (`UserRole`).
- Ids are `UUID` in Swift and lowercase strings only on the wire. Instants are `Date`, durations `Duration`.
- Absence is an optional, never a sentinel such as `""`, `-1` or `.distantPast`.
- A value that can be invalid is validated where it's made, by a throwing or failable initializer, so a model never holds an invalid one.
- Stored dependencies are existentials (`any CatalogClient`), parameters opaque where they can be (`some JWTAlgorithm`), and a type is generic where static dispatch matters (a use case over its database).

## Documentation comments

- `///`, starting with a one-line summary; a following paragraph says why, or what a caller must know.
- Every use case says the requirement it implements and the database role it runs on; every port, what the service needs from it.
- A name that says everything gets no comment.

## Formatting

- swift-format with the repository's `.swift-format`; `swift-format lint --strict --recursive Sources Package.swift` passes.
- Four-space indentation. A call or declaration that wraps puts one argument per line, and a multi-line collection ends with a trailing comma.
- Imports sorted, one per line.
