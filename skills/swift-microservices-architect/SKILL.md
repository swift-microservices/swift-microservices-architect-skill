---
name: swift-microservices-architect
description: Architects Swift server backends as gRPC microservices behind a Hummingbird gateway, one Swift package per service, with Postgres row-level security, Valkey and Temporal workflows. Use when planning a Swift backend or splitting it into services, adding a service, endpoint, use case, repository, migration, webhook, multi-tenant table, background job or durable Temporal workflow, drawing a Swift server's module boundaries or writing its Package.swift, wiring configuration, graceful shutdown, mTLS or JWT auth, naming server types and targets, setting up a server package's tests, CI/CD or deployment, or reviewing a Swift server's architecture or code style. Not for iOS, macOS or SwiftUI apps. Applies even when the user doesn't name the architecture.
license: MIT
---

# Swift Microservices Architect

In a backend built another way, keep its structure and conventions unless the user asks to change them, and take a shape from this skill only for what the backend lacks.

`X` stands for a service in a target's name (`LoansCore`) and for what a type is named for (`BorrowBookUseCase`, `LoanService`); `<Project>` and `<project>` for the project. The examples are Bookshelf, a small lending library:

| Package | Holds |
|---|---|
| `bookshelf-identity` | Accounts, passwords, sessions; issues every access token; reset codes in Valkey; members for other services, internally |
| `bookshelf-catalog` | Books: anyone reads, administrators edit; Loans looks books up internally |
| `bookshelf-loans` | A member's loans, a tenant table; a workflow marks a loan overdue and sends a notice |
| `bookshelf-gateway` | The public HTTP API, forwarding to the services' gRPC contracts |
| `bookshelf-core` | `BookshelfAuthentication`, `BookshelfPersistence`, `BookshelfTransport`, `BookshelfTesting` |
| `bookshelf-protos` | `IdentityProtos`, `CatalogProtos`, `LoansProtos` |

## The shape

```
Clients ── HTTPS ──► edge (TLS ends) ── HTTP ──► Gateway (Hummingbird, OpenAPI)
Gateway ── gRPC, mTLS, the caller's JWT ──► each service's XService
Service, worker ── gRPC, mTLS ──► another service's XInternalService
Service, worker ── mTLS ──► Temporal          Service, worker ──► its own data, wherever it lives
```

Every service and the gateway depend on `<project>-core`, `<project>-protos` and the swift-microservices libraries ([stack](references/stack.md)).

## A service's package

```
<project>-x
├── XCore         domain models, errors, repository protocols and commands, ports, use cases, workflows, activity containers
├── XPostgres     a scope per database role, repositories, statements, migrations
├── XGRPC         XService and XInternalService, Protobuf conversions, gRPC clients for Core's ports
├── XValkey       repositories for short-lived values
├── X<Provider>   a third-party API behind a Core port (LoansResend)
└── X             executable: commands, configuration defaults, migrations, composition roots
```

A service has only the targets it needs, and each imports only what [its row](references/packages.md#the-targets-of-a-service) lists. Hard rules:
- XCore imports no driver, transport, contract, configuration or lifecycle module ([what Core may link](references/packages.md#what-core-may-link)).
- XCore imports Temporal only in `Workflows/` and the use cases that start, signal, query or update a workflow, and never builds its client or worker.
- Adapter targets never import each other or Temporal; the executable hands one to another through Core's protocols.
- Generated contract types never leave XGRPC, the gateway's HTTP target and executables.
- Only an executable reads configuration, builds clients and runs the `ServiceGroup`.
- No service reads another's database; data crosses services only through contracts.

## Who owns what

| Concern | Owner |
|---|---|
| Business rules, authorization decisions, what an error means | The use case, in XCore; adapters only convert and delegate |
| What a service knows about another's data | A model in its XCore `Ports/`, beside the port that returns it |
| Protobuf ↔ domain, HTTP ↔ protobuf | XGRPC's `Protobuf/` conversions; the gateway's `Schemas/` |
| Messages between processes; the public API | `<project>-protos`; the gateway's `openapi.yaml` |
| Who the caller is | The gateway verifies and forwards the token; each service verifies it again |
| Which processes may call an internal RPC | mTLS at the listener: every process the environment's authority signs |
| Tenant isolation | Row-level security; `<Project>Persistence` binds the caller to each transaction, and each audience's use cases run as [their database role](references/persistence.md#database-roles) |
| Durable, delayed or multi-service work | A Temporal workflow in XCore's `Workflows/` |
| What every service needs identically | `<project>-core`: identity, tenant binding, transport readers |

## Code style

Code reads like the requirement it implements, with Apple's WWDC sample code as the bar ([style](references/style.md)). Use cases map errors this way; adapters keep one `catch` per case and add no final `catch` ([errors](references/style.md#errors)):

```swift
do {
    …  // the work, in the order the requirement states it
} catch let error as BorrowBookUseCaseError {
    throw error
} catch CatalogClientError.unavailable {
    logger.warning("Borrowing failed: the catalog is unavailable")
    throw .catalogUnavailable
} catch {
    logger.error("Borrowing failed: unknown error", metadata: ["error": "\(String(reflecting: error))"])
    throw .unknown
}
```

- One `do` holds the work through its `return`, and each `catch` ends its own path: nothing is declared before the `do` for a `catch` to fill, and a `do` nests only around a workflow's start ([errors](references/style.md#errors)).
- Build, then call: a value a call takes is a named `let`, never a conversion, `try` or `await` in the arguments ([build, then call](references/style.md#build-then-call)).
- No helper methods in use cases, workflows or activities, and no `Result` juggling, steering flags, `try?`, nested `do` in a `catch`, or force unwraps.
- Swift 6 mode with `ExistentialAny`, `MemberImportVisibility`, `InternalImportsByDefault` and `NonisolatedNonsendingByDefault` ([Swift settings](references/packages.md#swift-settings)); `package` access across a service's targets.
- Everything crossing a boundary is `Sendable`; no `Task {}` or `Task.detached`, and unchecked concurrency only where [concurrency](references/style.md#concurrency) allows it.

## Gotchas

- A component left out of the `ServiceGroup` never runs: an unrun `GRPCClient` or `PostgresClient` never connects, so its calls wait until their deadline.
- A process connected as the database owner bypasses row-level security, so every process connects as its roles and only `serve --migrate-database` as the owner.
- Temporal checks `Codable` only at run time: every workflow and activity payload, and each type it holds, is `Codable, Sendable` ([workflows](references/workflows.md#a-workflow)).
- Workflow code is replayed: `Date.now`, `UUID()`, randomness, `Task.sleep` or any I/O in a workflow breaks it ([determinism](references/workflows.md#determinism)).
- Every build and test of an XCore with workflows links the Temporal SDK and its prebuilt sdk-core binary target, so a machine that can't fetch that artifact can't build Core ([what Core may link](references/packages.md#what-core-may-link)).
- A plain or scoped `import Foundation` in owned code links full Foundation on Linux; use the conditional `FoundationEssentials` import.

## Checklists

Copy the task's checklist into the response and check items off as they're done; each `.md` file it names is in `references/`.

**Plan a backend**

```
- [ ] The capabilities and the data each owns; a service per capability (system.md#splitting-a-system-into-services)
- [ ] Name each service; check its target names against every module in the graph
- [ ] Per service: XService RPCs by audience, XInternalService RPCs and callers with no call cycle, tables (tenant or not), workflows, short-lived state
- [ ] Per service: its targets and commands; whether it stores data, where, its roles and how processes prove them (system.md#data-placement)
- [ ] <project>-core's products, <project>-protos' contracts, the gateway's routes by tier
- [ ] Build order: <project>-core and <project>-protos, the token issuer, each service before its callers, the gateway
- [ ] Write the plan from system.md#the-plan; check it against the hard rules before any code
```

**Add a service**

```
- [ ] Look up the standard approach for the feature and follow it within these rules (style.md#reading-like-the-requirement)
- [ ] <project>-protos: XProtos with XService, and XInternalService if processes call in
- [ ] Package <project>-x from packages.md#packageswift-template, with only the targets the plan names
- [ ] XCore: models, errors, repositories, ports, a use case per RPC (use-cases.md)
- [ ] XPostgres: roles, tables, row-level security, statements, a scope per role (persistence.md)
- [ ] XGRPC: proto services over the use cases, conversions, clients for ports (grpc.md)
- [ ] XCore's Workflows/, XValkey, X<Provider> as the plan needs
- [ ] X: commands, InMemoryProvider defaults, Migrations, Serve, and Run with a worker (composition.md)
- [ ] Gateway: routes for the public RPCs (gateway.md)
- [ ] A test target per module, over mocks (testing.md)
- [ ] Its CI workflows, Containerfile, .swift-format and Dependabot as a service (delivery.md, style.md#formatting)
- [ ] swift build and swift test with CI's flags and POSTGRES_* and VALKEY_* set (delivery.md#tests), scripts/check_boundaries.sh and scripts/check_style.sh (packages.md#checking-the-boundaries) and swift-format lint; fix and repeat until all pass, and report any suite that can't run
```

**Add an operation**

```
- [ ] Look up the standard approach for the feature and follow it within these rules (style.md#reading-like-the-requirement)
- [ ] Contract: the RPC under its audience in XService, or in XInternalService
- [ ] XCore: the use case's five files; its scope lists only what it touches (use-cases.md)
- [ ] XPostgres: the scopes of the roles it may run as adopt its scope protocol
- [ ] XGRPC: the handler and the input's conversion, every error case mapped
- [ ] Executable: the use case on its role's database, passed to the service
- [ ] Gateway: the route in its tier, if public
- [ ] Tests: the use case's outcomes and the handler's statuses, over mocks
- [ ] swift build and swift test with CI's flags and POSTGRES_* and VALKEY_* set (delivery.md#tests), scripts/check_boundaries.sh and scripts/check_style.sh (packages.md#checking-the-boundaries) and swift-format lint; fix and repeat until all pass, and report any suite that can't run
```

**Add a durable process**

```
- [ ] Look up the standard approach for the feature and follow it within these rules (style.md#reading-like-the-requirement)
- [ ] XCore: the system use cases its activities run, adopted by the worker scope (use-cases.md#system-use-cases)
- [ ] XCore/Workflows/<WorkflowName>/: the workflow, its activity container over use case and port protocols, named ActivityOptions (workflows.md)
- [ ] The use case that starts it, holding TemporalClient and the task queue, after its transaction commits, by a deterministic id
- [ ] Executable: TemporalClient and the task queue into Serve's use cases; the worker group and its Run root
- [ ] Tests: the workflow and the starting use case on the test server, its activities over mocks
- [ ] swift build and swift test with CI's flags and POSTGRES_* and VALKEY_* set (delivery.md#tests), scripts/check_boundaries.sh and scripts/check_style.sh (packages.md#checking-the-boundaries) and swift-format lint; fix and repeat until all pass, and report any suite that can't run
```

**Set up CI/CD**

```
- [ ] The package's kind: public library, system library or service (delivery.md#package-kinds)
- [ ] Its CI workflows, calling swift-microservices/ci at a release's commit; dependabot.yml; .swift-format, .license_header_template and .licenseignore; the secrets
- [ ] A library: the semver labels and .github/release.yml; a service: its Containerfile
- [ ] swift build and swift test with CI's flags (delivery.md#tests); fix and repeat until both pass
```

**Review a backend**

```
- [ ] Run this skill's scripts/check_boundaries.sh from each service's and the gateway's root, and scripts/check_style.sh from every package's (packages.md#checking-the-boundaries)
- [ ] Each use case: its five files, typed throws, one catch per case, no helpers, the right database role
- [ ] Each adapter only converts and delegates; every error case is mapped
- [ ] Each root: configuration read only there, every component in the ServiceGroup in dependency order
- [ ] Swift settings, each target listing every module it imports (packages.md#packageswift-template), FoundationEssentials imports, package access, naming (conventions.md)
- [ ] Findings ranked blocking (tenant isolation, authorization, credentials, the build), major (the shapes), minor (naming, layout, logging), each citing a file and line or an empty grep, with the rule and the fix; then the user's decisions. Change code only when asked
- [ ] swift build and swift test; report each result, or why it couldn't run
```

## References

Read each reference when its row applies:

| Reference | Read when |
|---|---|
| [system.md](references/system.md) | Planning a backend, adding or splitting a service, deciding how services talk |
| [packages.md](references/packages.md) | Creating a package, changing a target's imports or dependencies, deciding what Core may link, checking boundaries |
| [stack.md](references/stack.md) | Choosing a library or a version, or checking whether one links full Foundation |
| [use-cases.md](references/use-cases.md) | Writing a model, error, repository, port or use case, including a system use case, or deciding a transaction or authorization |
| [persistence.md](references/persistence.md) | Writing a scope, statement, migration, policy, tenant table, Valkey repository or Valkey client |
| [grpc.md](references/grpc.md) | Changing a contract, handler, conversion, client, paged list or transport |
| [gateway.md](references/gateway.md) | Adding a route, request context, controller, webhook route or error mapping |
| [workflows.md](references/workflows.md) | Writing or starting a workflow, activity container or worker |
| [composition.md](references/composition.md) | Wiring a command, composition root, configuration, logging or the ServiceGroup |
| [security.md](references/security.md) | Touching TLS or mTLS, tokens, secrets, authorization layers or webhook verification |
| [style.md](references/style.md) | Writing or reviewing any Swift |
| [testing.md](references/testing.md) | Writing tests or mocks |
| [delivery.md](references/delivery.md) | Setting up CI, releases, deployment, the Containerfile or Dependabot |
| [conventions.md](references/conventions.md) | Naming anything or placing a file |

## Related skills

For the code inside the shapes, load these when installed; where this skill states a shape, follow it:
- Actors, task groups, cancellation, `Sendable` diagnostics, Swift 6 migration: `swift-concurrency`
- Argument labels, method names, documentation comments: `swift-api-design-guidelines`
- Tests of use cases, handlers and workflows: `swift-testing-expert`
- How a workflow is designed and behaves (its history, signals and updates, waiting, compensation, versioning): `temporal-developer`
