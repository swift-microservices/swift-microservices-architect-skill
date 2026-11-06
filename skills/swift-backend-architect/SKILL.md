---
name: swift-backend-architect
description: Architects Swift server backends as gRPC microservices behind a Hummingbird API gateway, each service one Swift package with a Core target of domain models, repository protocols and typed-throws use cases, adapter targets for Postgres, gRPC, Temporal and Valkey, and an executable composition root on swift-configuration and swift-service-lifecycle, secured with mTLS, JWTs and Postgres row-level security through the swift-microservices libraries. Use when planning a backend or splitting it into services, designing a module map or Package.swift, writing use cases, repositories, gRPC services, Hummingbird routes and request contexts, Temporal workflows or a composition root, naming Swift server types and targets, adopting strict concurrency or FoundationEssentials, or reviewing a Swift backend's architecture or code style, even when the user doesn't name the architecture.
---

# Swift Backend Architect

Decides how a Swift backend splits into services and modules, where code lives, the shapes of use cases, adapters and composition roots, and how the code reads.

`X` stands for a service (`Loans` → `LoansCore`, `LoansGRPC`, `BorrowBookUseCase`), `<Org>` and `<org>` for the organization (`Bookshelf`, `bookshelf-core`).

A backend built another way keeps its structure until the user asks to change it. A change there follows its own conventions and takes a shape from this skill only where it has none.

The examples are Bookshelf, a small lending library:

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
Service, worker ── mTLS ──► Temporal          Service ──► its own Postgres database, Valkey
```

Every service and the gateway depend on `<org>-core`, `<org>-protos` and the swift-microservices libraries ([stack](references/stack.md)).

## A service's package

```
<org>-x
├── XCore         domain models, errors, repository protocols and commands, ports, use cases
├── XPostgres     a scope per database role, repositories, statements, migrations
├── XGRPC         XService and XInternalService, Protobuf conversions, gRPC clients for Core's ports
├── XTemporal     workflows, activity containers, the Temporal client for Core's workflow port
├── XValkey       repositories for short-lived values
├── X<Provider>   a third-party API behind a Core port (LoansResend)
├── XHTTP         HTTP the service serves itself, only when a caller can't use the gateway
└── X             executable: commands, configuration defaults, migrations, composition roots
```

A service has only the targets it needs. Each imports only what its arrow points at:

```
X ─────────────► every X target, <Org>Transport, <Org>Persistence, drivers, transports, lifecycle
XGRPC, XHTTP ──► XCore, contracts, the transport's framework, <Org>Authentication
XPostgres ─────► XCore, PersistencePostgres      XTemporal ──► XCore, Temporal
XValkey ───────► XCore, Valkey                   X<Provider> ► XCore, the provider's SDK
XCore ─────────► Persistence, <Org>Authentication, Logging
```

Hard rules:
- XCore imports no driver, transport, contract, workflow engine, configuration or lifecycle module ([what Core may link](references/packages.md#what-core-may-link)).
- Adapter targets never import each other; the executable hands one to another through Core's protocols.
- Generated contract types never leave XGRPC, the gateway's HTTP target and executables.
- Only an executable reads configuration, constructs clients and runs services.
- No service reads another's database; data crosses services only through contracts.

## Who owns what

| Concern | Owner |
|---|---|
| Business rules, authorization decisions, what an error means | The use case, in XCore |
| Protobuf ↔ domain, HTTP ↔ protobuf | XGRPC's `Protobuf/` conversions; the gateway's `Schemas/` |
| Who the caller is | The gateway verifies and forwards the token; each service verifies it again |
| Which process may call an internal RPC | mTLS trust at the listener |
| Tenant isolation | Row-level security; `<Org>Persistence` binds the caller to each transaction |
| Durable, delayed or multi-service work | A Temporal workflow in XTemporal |
| Contracts; the public API | `<org>-protos`; the gateway's `openapi.yaml` |

## Principles

1. **A service owns a capability and its data.** Other processes reach its data only through its contracts. Where its storage lives is a deployment decision; its targets don't change with it ([the system](references/system.md)).
2. **Core is the service; adapters translate.** gRPC services, routes, activities and repositories convert and delegate to use cases.
3. **SPM enforces the boundaries.** A layer is a target, and a target imports only what it declares.
4. **One composition root per process.** A command's `run()` reads configuration, builds every concrete type and runs them in one `ServiceGroup`.
5. **Every hop proves itself.** mTLS between processes, the caller's token verified by each service, row-level security under tenant queries ([security](references/security.md)).
6. **Code reads like the requirement.** Use cases, workflows and handlers read top to bottom, with typed throws and one `catch` per case; Apple's WWDC sample code is the bar ([style](references/style.md)).
7. **Modern Swift throughout.** Swift 6 mode with `ExistentialAny`, `MemberImportVisibility`, `InternalImportsByDefault` and `NonisolatedNonsendingByDefault` in every package ([Swift settings](references/packages.md#swift-settings)); structured concurrency.
8. **Share only what every service needs identically.** Identity, tenant binding and transport configuration go in `<org>-core`; a service models another's data in its own words.

## The shapes in brief

- **Use case.** Five files: `XUseCaseProtocol` (`callAsFunction(subject:input:) async throws(XUseCaseError) -> Output`), `XUseCaseInput`, `XUseCaseError` (outcomes the caller acts on, then `unknown`), `XUseCaseScope` (the repositories it touches) and `XUseCase<DatabaseType>`, held as `any XUseCaseProtocol` in `xUseCase` ([use cases](references/use-cases.md)).
- **Repositories and ports.** Core protocols with untyped `throws`: repositories reached through a transaction's scope; ports to other services, providers, the workflow engine and Valkey held directly.
- **Persistence.** A Postgres scope per database role adopts the scope protocols of the use cases allowed to run as that role, so the compiler checks which role runs what ([persistence](references/persistence.md)).
- **gRPC.** `XService` for people through the gateway, `XInternalService` for processes. A handler requires its caller, converts the request, calls one use case and maps every error case to a status ([gRPC](references/grpc.md)).
- **Gateway.** Hummingbird routes in tiers of request contexts, one controller per resource, forwarding the caller's token; plain HTTP behind the edge's TLS ([gateway](references/gateway.md)).
- **Workflows.** A Core port starts a workflow by a deterministic id; XTemporal holds the workflow, activities over use cases and ports, and the client; `x worker run` runs them as the worker role ([workflows](references/workflows.md)).
- **Composition.** ArgumentParser commands; one `ConfigReader` over environment variables and `InMemoryProvider.applicationDefaults`; shared readers from `<Org>Transport`; one `ServiceGroup` with graceful shutdown on `SIGTERM` ([composition](references/composition.md)).

## Code style

A use case maps errors this way, and adapters read the same:

```swift
do {
    …  // the work, in the order the requirement states it
} catch let error as BorrowBookUseCaseError {
    throw error
} catch LoanRepositoryError.idempotencyConflict {
    logger.warning("Borrowing refused: idempotency key reused for another book")
    throw .idempotencyConflict
} catch {
    logger.error("Borrowing failed: unknown error", metadata: ["error": "\(String(reflecting: error))"])
    throw .unknown
}
```

- One `do` holds the work through its `return`, then one `catch` per case the caller acts on, then `unknown`. Each `catch` ends its own path: nothing is declared before the `do` for a `catch` to fill, and nothing follows it. A handler maps every case to a status, with no catch-all.
- Build, then call: a value a call takes is a `let` named for what it is (`let statement = …`, then `connection.execute(statement, logger: logger)`), never a conversion, `try` or `await` in the arguments ([style](references/style.md#build-then-call)).
- No private helper methods in use cases, workflows or activities, and no workarounds: no `Result` juggling, steering flags, `try?`, nested `do` in a `catch`, or force unwraps.
- `package` across a service's targets with `package import`, the conditional `FoundationEssentials` import, `Duration` and `FormatStyle` over legacy Foundation types.
- Everything crossing a boundary is `Sendable`; no `@unchecked Sendable`, `nonisolated(unsafe)`, `Task {}` or `Task.detached`.

## Gotchas

- Module names are unique across the package graph: a service named `Authentication` or `Logging` collides with a dependency. Rename the service, not one of its targets.
- `NonisolatedNonsendingByDefault` changes what an unannotated `async` function type means. Implement a requirement from a library built without it exactly as declared, `@concurrent` included: Hummingbird middleware's `next`, gRPC interceptors' `next`.
- Hummingbird's `add(middleware:)` changes its group for every route added after it; give each route tier its own `group()`.
- A route whose bearer token isn't an access token, such as a refresh request's refresh token, stays outside `BearerAuthenticationMiddleware`, which refuses any bearer token it can't verify.
- A component left out of the `ServiceGroup` never runs: an unrun `GRPCClient` or `PostgresClient` never connects, so its calls wait until their deadline.
- A process connected as the database owner bypasses row-level security, and an unset tenant setting reads as `''` on a reused connection, so policies wrap it in `NULLIF`.
- Workflow code is replayed: `Date.now`, `UUID()`, randomness, `Task.sleep`, a captured `Logger` or any I/O in a workflow breaks it ([determinism](references/workflows.md#determinism)).
- A plain `import Foundation` in owned code links full Foundation; use the conditional `FoundationEssentials` import.

## Workflows

Copy the checklist for the task into the response and check items off as they're done.

**Plan a backend**

```
- [ ] The capabilities and the data each owns; a service per capability with its own data and rules (system.md#splitting-a-system-into-services)
- [ ] Name each service; check its target names against every module in the graph
- [ ] Per service: XService RPCs by audience, XInternalService RPCs and callers, tables (tenant or not), workflows, short-lived state
- [ ] Per service: its targets, commands and database roles
- [ ] <org>-core's products, <org>-protos' contracts, the gateway's routes by tier
- [ ] Write the plan from system.md#the-plan; check it against the hard rules before any code
```

**Add a service**

```
- [ ] <org>-protos: XProtos with XService, and XInternalService if processes call in
- [ ] Package <org>-x from packages.md#packageswift-template, with only the targets the plan names
- [ ] XCore: models, errors, repositories, ports, a use case per RPC (use-cases.md)
- [ ] XPostgres: roles, tables, row-level security, statements, a scope per role (persistence.md)
- [ ] XGRPC: proto services over the use cases, conversions, clients for ports (grpc.md)
- [ ] XTemporal, XValkey, X<Provider> as the plan needs
- [ ] X: commands, InMemoryProvider defaults, Migrations, Serve, and Run with a worker (composition.md)
- [ ] Gateway: routes for the public RPCs (gateway.md)
- [ ] swift build; fix and repeat until it builds without warnings
```

**Add an operation**

```
- [ ] Contract: the RPC under its audience in XService, or in XInternalService
- [ ] XCore: the use case's five files; its scope lists only what it touches
- [ ] XPostgres: the scopes of the roles it may run as adopt its scope protocol
- [ ] XGRPC: the handler and the input's conversion, every error case mapped
- [ ] Executable: the use case on its role's database, passed to the service
- [ ] Gateway: the route in its tier, if public
- [ ] swift build; fix and repeat until it builds without warnings
```

**Add a durable process**

```
- [ ] XCore: the XWorkflowClient port; the use cases its activities run, adopted by the worker scope
- [ ] XTemporal: the workflow, its activities, TemporalXWorkflowClient, named ActivityOptions (workflows.md)
- [ ] The use case that starts it, after its transaction commits, by a deterministic id
- [ ] Executable: the Temporal client in Serve; the worker group and its Run root
- [ ] swift build; fix and repeat until it builds without warnings
```

**Review a backend**

```
- [ ] Run the boundary checks (packages.md#checking-the-boundaries)
- [ ] Each use case: its five files, typed throws, one catch per case, no helpers, the right database role
- [ ] Each adapter only converts and delegates; every error case is mapped
- [ ] Each root: configuration read only there, every component in the ServiceGroup in dependency order
- [ ] Swift settings, FoundationEssentials imports, package access, naming (conventions.md)
- [ ] Report each finding with its file, the rule it breaks and the fix; change code only when asked
```

**Decide where a type belongs**

1. A rule or concept of one service → its XCore, in the area it belongs to.
2. What a service knows about another's data → a model in its XCore `Ports/`, beside the port that returns it.
3. A message between processes → `<org>-protos`; a public request or response → the gateway's `openapi.yaml`.
4. A conversion → the adapter target of the technology it converts to.
5. Identical in every service (identity, tenant binding, transport readers) → `<org>-core`.
6. Reading configuration, building and running things → the executable.

## References

Read the reference for the part at hand:

| Reference | Read when |
|---|---|
| [references/system.md](references/system.md) | Splitting a backend into services, contracts, how services talk, data ownership, the shared packages, the plan |
| [references/packages.md](references/packages.md) | Targets and dependency direction, what Core may link, `Package.swift`, Swift settings, traits and Foundation, layouts, boundary checks |
| [references/stack.md](references/stack.md) | The swift-microservices libraries and the server stack, and which target links each |
| [references/use-cases.md](references/use-cases.md) | Models, errors, repositories, ports, use cases and their bodies, transactions, authorization, logging |
| [references/persistence.md](references/persistence.md) | Postgres scopes and roles, row-level security, statements, migrations, other stores, Valkey |
| [references/grpc.md](references/grpc.md) | Contracts, gRPC services and handlers, conversions, status codes, interceptors, clients for ports, transports |
| [references/gateway.md](references/gateway.md) | Request contexts and tiers, the router, controllers, errors, upstream clients, the edge |
| [references/workflows.md](references/workflows.md) | Starting workflows, workflows, determinism, activities, options, versions, the worker |
| [references/composition.md](references/composition.md) | Commands, the composition root, configuration, logging, the ServiceGroup and why |
| [references/security.md](references/security.md) | The trust model, mTLS and certificate reloading, user tokens, authorization layers, secrets |
| [references/style.md](references/style.md) | Readability, errors, concurrency, imports and access control, Foundation, types, documentation |
| [references/conventions.md](references/conventions.md) | Naming a package, target, type, file, key or folder |

## Related skills

Load these, when installed, for the code inside the shapes:

| Writing or reviewing | Skill |
|---|---|
| Actors, task groups, cancellation, `Sendable` diagnostics, Swift 6 migration | A Swift Concurrency skill: `swift-concurrency` |
| Argument labels, method names, documentation comments | `swift-api-design-guidelines` |
| Tests of use cases, handlers and workflows | A Swift Testing skill: `swift-testing-expert` |
| An app that calls the gateway's API | `swiftui-architect` |

Where this skill states a shape, follow it; those skills cover the code inside it.
