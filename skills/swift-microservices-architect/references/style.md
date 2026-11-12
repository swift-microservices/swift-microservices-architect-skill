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
- Numbers are named where they belong ([domain models](use-cases.md#domain-models)), never an inline literal in a workflow or use case: `ActivityOptions.notification`, `LoanPolicy.maximumActiveLoans`, `EmailAddress.maximumLength`.
- `// MARK: -` names the sections of a composition root and the groups inside a type: a service's RPCs by audience, a router builder's tiers, an activity container's steps.
- Code that a reader would otherwise check twice gets a one-line comment with the reason: a business rule, an ordering constraint, a safety property. A comment never narrates the next line.

A feature is built the established way. Before writing one, look up the standard or documented practice that covers it: an RFC, OWASP's guidance, or the provider's or library's documented approach, such as RFC 9457 for problem details, RFC 8725 for JWTs, OWASP's password storage, the IETF `Idempotency-Key` header, RFC 3339 for dates on the wire and Google's AIPs for a contract's standard methods and fields.
- Adopt that practice within this skill's rules, and never invent a scheme where a standard exists.
- Handle what most production systems meet. A rare edge case gets a sentence to the user, not code.
- Without web access, tell the user that the approach comes from prior knowledge, unchecked against the current standard.

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

- A use case declares its error with typed throws: `async throws(BorrowBookUseCaseError) -> Loan`. Repositories, ports, clients and handlers use untyped `throws`.
- Errors are mapped with `do` and one `catch` per case: `catch CatalogClientError.unavailable { throw .catalogUnavailable }`. The order and the final `catch` are in [the body of a use case](use-cases.md#the-body-of-a-use-case); a handler maps every case and has no final `catch` ([a handler](grpc.md#a-handler)).
- In a use case, a handler and an activity, the `do` holds the whole path, from the first step of the work through its `return`. Only refusals come before it: requiring the caller, converting the request, checking input that needs no data.
- There, each `catch` ends its own path, by throwing or by returning what its case means (`nil` for `notFound`). Nothing is declared before the `do` for a `catch` to fill in, and no code follows the `do`.
- A `do` nests in one place: around a workflow's start, when its `catch` returns what the path built ([starting a workflow](workflows.md#starting-a-workflow-from-a-use-case)).
- Inside a typed-throws function and outside a `do`, `throw .case` takes its type from the function. Inside a `do`, a `throw` is spelled in full: `throw BorrowBookUseCaseError.bookNotFound`.
- `String(reflecting: error)` goes into the log line of an unknown error, never into a response.
- A use case's typed error has no case for cancellation, so `CancellationError` reaches its final `catch` and leaves as `.unknown`. Everywhere else it propagates, and nothing catches it to carry on, except where `temporal-developer` gives a workflow's wait for a deadline that form.

## Concurrency

Every package builds with [the Swift settings](packages.md#swift-settings). The code inside these rules, such as an actor's design, a `Mutex`, a task group or `async let`, cancellation, a long-running `Service` of the service's own or an interceptor's `@concurrent` `next`, follows the Swift Concurrency skill (`swift-concurrency`).

- Everything that crosses a boundary is `Sendable`: models, inputs, commands, errors, protocols. Structs and enums by default; an actor only for mutable state shared across tasks; `Mutex` from `Synchronization` for a small piece of state touched synchronously.
- No `@unchecked Sendable`, `nonisolated(unsafe)` or `@preconcurrency` in owned code. When a dependency needs one, it appears once, in the adapter that wraps the dependency, with the reason on the line above.
- No unstructured tasks in a service. Long-running work is a `Service` in the `ServiceGroup`; work that must outlive a request is a [workflow](workflows.md#when-work-is-a-workflow); concurrency inside a request is `async let` or a task group, which end with the request.
- A requirement from a library built without `NonisolatedNonsendingByDefault` is implemented with `@concurrent` on each `async` closure parameter, since the library's plain spelling means `@concurrent` there and the caller's isolation here: Hummingbird middleware's `next` is written `next: @concurrent (Request, Context) async throws -> Response`, a grpc-swift `ServerInterceptor`'s `next: @concurrent @Sendable (…)`, and a `ClientInterceptor`'s `next: @concurrent (…)`. Copied as the library spells it, the method doesn't satisfy the requirement. When the closure type wraps, swift-format moves it to the line after `next:` ([binding the tenant](persistence.md#binding-the-tenant)).
- CPU-heavy synchronous work, such as hashing a password, runs on `NIOThreadPool.singleton.runIfActive { … }`, off the cooperative pool.
- No server type is `@MainActor`.

## Access control and imports

- Inside a service's package, what another target uses is `package`, the rest internal or `private`. `public` is for libraries other packages link: `<project>-core`, `<project>-protos`.
- A `package` struct spells its `package init`, since the memberwise initializer is internal.
- Imports are internal by default. A file imports a module `package` when the module's types appear in its `package` declarations, `public` when in `public` ones, and plainly otherwise.
- A file imports every module whose members it uses, since `MemberImportVisibility` hides members of modules it doesn't import: `SwiftProtobuf` for a message's `.with { … }`, `Persistence` or `PersistencePostgres` for `withTransaction`, `<Project>Authentication` for a `UserRole`'s `rawValue`, the Foundation block for `uuidString`.
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
- A scoped import takes the same condition: `import struct Foundation.Data` alone links full Foundation, so it's `import struct FoundationEssentials.Data` under `#if canImport(FoundationEssentials)`.
- `FoundationEssentials` ships with every Swift toolchain on Linux and isn't importable on Darwin, where the condition takes `Foundation`. With `MemberImportVisibility`, code that reaches for full Foundation compiles on a Mac and fails on Linux, so CI's Linux build catches it.
- Modern Foundation and standard library APIs only:

| Instead of | Use |
|---|---|
| `DateFormatter`, `ISO8601DateFormatter` | `Date.ISO8601FormatStyle`: `date.formatted(.iso8601)`, `try Date(string, strategy: .iso8601)` |
| `NumberFormatter`, localized date formatters | `FormatStyle`s (`.number`, `.currency(code:)`, `Date.FormatStyle`), imported from `FoundationInternationalization` only where text is formatted for people |
| `NSRegularExpression` | Swift `Regex` |
| `JSONSerialization` | `Codable` with `JSONEncoder` and `JSONDecoder` |
| `URLSession` | AsyncHTTPClient |
| `String(format:)`, `CharacterSet`, `NSString` methods | String interpolation; `Character` and `Unicode.Scalar.Properties` |
| `TimeInterval` timeouts, `DispatchTime` | `Duration`: `.seconds(30)`, `.milliseconds(500)` |
| `Date()` | `Date.now` |
| `URL(fileURLWithPath:)` | `URL(filePath:)` |
| `DispatchQueue`, `NSLock`, `Thread` | Structured concurrency, actors, `Mutex` |

- A dependency's traits decide whether it links full Foundation; a service declares them so it doesn't ([traits and Foundation](packages.md#traits-and-foundation)).

## Types and values

- Models, inputs, commands and outputs are structs of `let` properties. Closed sets are enums (`LoanStatus`); a set other services may extend is a `RawRepresentable` string struct with static members (`UserRole`), which a contract carries as its raw string ([contracts](grpc.md#contracts-in-the-protos-package)).
- Foundation adds no `Duration` to a `Date`, so a `TimeInterval` appears only at a `Date`'s arithmetic, converted once in the policy or model method that owns the duration: `let loanSeconds = loanPeriod / .seconds(1)`, then `borrowedAt.addingTimeInterval(loanSeconds)`. Every other duration is a `Duration`.
- A calendar date, such as a date of birth, is a Core value of year, month and day, a `DATE` column and an RFC 3339 full-date `string` (`1988-04-17`) in a contract, `format: date` over HTTP, never a `Date` at midnight.
- Ids are `UUID` in owned Swift and lowercase strings on the wire, over gRPC and HTTP alike; the gateway's generated types hold them as `String`s ([OpenAPI types](gateway.md#openapi-types)). Instants are `Date`, durations `Duration`.
- Absence is an optional, never a sentinel such as `""`, `-1` or `.distantPast`.
- A value that can be invalid is validated where it's made, by a failable initializer, so a model never holds an invalid one.
- Protocols exist only where substitution is real: use cases, repositories, scopes, the database and ports. Models, commands, policies and configuration are concrete. There is no clock or id-generator protocol: ids and stored dates come from the database, and a use case that decides on time reads `Date.now`.
- Stored dependencies are existentials (`any CatalogClient`), except `TemporalClient`, which Core holds as the concrete type; parameters are opaque where they can be (`some JWTAlgorithm`), and a type is generic where the compiler must check a constraint on it or it wraps a library's generic client: a use case over its database, `GRPCCatalogClient<Transport>`.
- `logger` is the last parameter of every initializer and function that takes one, and the last stored dependency; only a trailing closure follows it.

## Documentation comments

- `///`, starting with a one-line summary; a following paragraph says why, or what a caller must know.
- Every use case says the requirement it implements and the database role it runs on; every port, what the service needs from it.
- A name that says everything gets no comment.

## Formatting

- swift-format with the repository's `.swift-format`; `swift-format lint --strict --recursive Sources Package.swift` passes.
- `.swift-format` sets four-space indentation and 400-column lines; a line break before each argument of a call or declaration that wraps, respecting existing line breaks; trailing commas in multi-element collections; and `indentConditionalCompilationBlocks: false`, so the `FoundationEssentials` block stays flush left.
- It sets no `rules`, so the default rules, ordered imports among them, stay on: a `rules` map turns off every rule it doesn't name.
