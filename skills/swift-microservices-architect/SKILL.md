---
name: swift-microservices-architect
description: Architects Swift server backends as gRPC microservices behind a Hummingbird gateway, with one Swift package per service, a Core of typed-throws use cases, an adapter target per technology (Postgres with row-level security, gRPC, Temporal, Valkey) and an executable composition root. Use when planning a Swift backend or splitting it into services, drawing module boundaries or writing Package.swift, adding a service, endpoint, use case, repository, migration, multi-tenant table or durable Temporal workflow, wiring configuration, graceful shutdown, mTLS or JWT auth, naming server types and targets, setting up a package's CI/CD on GitHub Actions, or reviewing a Swift server's architecture or code style, even when the user doesn't name the architecture.
license: MIT
---

# Swift Microservices Architect

In a backend built another way, keep its structure and conventions unless the user asks to change them, and take a shape from this skill only for what the backend lacks.

`X` stands for a service in a target's name (`LoansCore`) and for what a type is named for (`BorrowBookUseCase`, `LoanService`); `<Org>` and `<org>` for the organization. The examples are Bookshelf, a small lending library:

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
└── X             executable: commands, configuration defaults, migrations, composition roots
```

A service has only the targets it needs, and each imports only what [its row](references/packages.md#the-targets-of-a-service) lists. Hard rules:
- XCore imports no driver, transport, contract, workflow engine, configuration or lifecycle module ([what Core may link](references/packages.md#what-core-may-link)).
- Adapter targets never import each other; the executable hands one to another through Core's protocols.
- Generated contract types never leave XGRPC, the gateway's HTTP target and executables.
- Only an executable reads configuration, builds clients and runs the `ServiceGroup`.
- No service reads another's database; data crosses services only through contracts.

## Who owns what

| Concern | Owner |
|---|---|
| Business rules, authorization decisions, what an error means | The use case, in XCore; adapters only convert and delegate |
| What a service knows about another's data | A model in its XCore `Ports/`, beside the port that returns it |
| Protobuf ↔ domain, HTTP ↔ protobuf | XGRPC's `Protobuf/` conversions; the gateway's `Schemas/` |
| Messages between processes; the public API | `<org>-protos`; the gateway's `openapi.yaml` |
| Who the caller is | The gateway verifies and forwards the token; each service verifies it again |
| Which processes may call an internal RPC | mTLS at the listener: every process the environment's authority signs |
| Tenant isolation | Row-level security; `<Org>Persistence` binds the caller to each transaction, and each audience's use cases run as [their database role](references/persistence.md#database-roles) |
| Durable, delayed or multi-service work | A Temporal workflow in XTemporal |
| What every service needs identically | `<org>-core`: identity, tenant binding, transport readers |

## Code style

Code reads like the requirement it implements, with Apple's WWDC sample code as the bar ([style](references/style.md)). Use cases and adapters map errors this way:

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

- One `do` holds the work through its `return`, and each `catch` ends its own path: nothing is declared before the `do` for a `catch` to fill.
- Build, then call: a value a call takes is a named `let`, never a conversion, `try` or `await` in the arguments ([build, then call](references/style.md#build-then-call)).
- No helper methods in use cases, workflows or activities, and no `Result` juggling, steering flags, `try?`, nested `do` in a `catch`, or force unwraps.
- Swift 6 mode with `ExistentialAny`, `MemberImportVisibility`, `InternalImportsByDefault` and `NonisolatedNonsendingByDefault` ([Swift settings](references/packages.md#swift-settings)); `package` access across a service's targets.
- Everything crossing a boundary is `Sendable`; no `Task {}` or `Task.detached`, and unchecked concurrency only where [concurrency](references/style.md#concurrency) allows it.

## Gotchas

- A component left out of the `ServiceGroup` never runs: an unrun `GRPCClient` or `PostgresClient` never connects, so its calls wait until their deadline.
- A process connected as the database owner bypasses row-level security, so every process connects as its roles and only `serve --migrate-database` as the owner.
- Temporal checks `Codable` only at run time: every workflow and activity payload, and each type it holds, is `Codable, Sendable` ([workflows](references/workflows.md#a-workflow)).
- Workflow code is replayed: `Date.now`, `UUID()`, randomness, `Task.sleep` or any I/O in a workflow breaks it ([determinism](references/workflows.md#determinism)).
- A plain or scoped `import Foundation` in owned code links full Foundation on Linux; use the conditional `FoundationEssentials` import.

## Checklists

Copy the task's checklist into the response and check items off as they're done; each `.md` file it names is in `references/`.

**Plan a backend**

```
- [ ] The capabilities and the data each owns; a service per capability (system.md#splitting-a-system-into-services)
- [ ] Name each service; check its target names against every module in the graph
- [ ] Per service: XService RPCs by audience, XInternalService RPCs and callers with no call cycle, tables (tenant or not), workflows, short-lived state
- [ ] Per service: its targets, commands and database roles
- [ ] <org>-core's products, <org>-protos' contracts, the gateway's routes by tier
- [ ] Build order: <org>-core and <org>-protos, the token issuer, each service before its callers, the gateway
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
- [ ] A test target per module, over mocks (testing.md)
- [ ] Its CI workflows, Containerfile and Dependabot as a service (delivery.md)
- [ ] swift build and swift test; fix and repeat until both pass without warnings
```

**Add an operation**

```
- [ ] Contract: the RPC under its audience in XService, or in XInternalService
- [ ] XCore: the use case's five files; its scope lists only what it touches (use-cases.md)
- [ ] XPostgres: the scopes of the roles it may run as adopt its scope protocol
- [ ] XGRPC: the handler and the input's conversion, every error case mapped
- [ ] Executable: the use case on its role's database, passed to the service
- [ ] Gateway: the route in its tier, if public
- [ ] Tests: the use case's outcomes and the handler's statuses, over mocks
- [ ] swift build and swift test; fix and repeat until both pass without warnings
```

**Add a durable process**

```
- [ ] XCore: the XWorkflowClient port; the use cases its activities run, adopted by the worker scope
- [ ] XTemporal: the workflow, its activities, TemporalXWorkflowClient, named ActivityOptions (workflows.md)
- [ ] The use case that starts it, after its transaction commits, by a deterministic id
- [ ] Executable: the Temporal client in Serve; the worker group and its Run root
- [ ] Tests: the workflow on the time-skipping server, its activities over mocks
- [ ] swift build and swift test; fix and repeat until both pass without warnings
```

**Set up CI/CD**

```
- [ ] The package's kind: public library, system library or service (delivery.md#package-kinds)
- [ ] Its CI workflows, calling swift-microservices/ci at a release's commit; dependabot.yml; .license_header_template and .licenseignore; the secrets
- [ ] A library: the semver labels and .github/release.yml; a service: its Containerfile
- [ ] swift build and swift test with CI's flags; fix and repeat until both pass
```

**Review a backend**

```
- [ ] Run the boundary checks (packages.md#checking-the-boundaries)
- [ ] Each use case: its five files, typed throws, one catch per case, no helpers, the right database role
- [ ] Each adapter only converts and delegates; every error case is mapped
- [ ] Each root: configuration read only there, every component in the ServiceGroup in dependency order
- [ ] Swift settings, FoundationEssentials imports, package access, naming (conventions.md)
- [ ] Findings ranked blocking (tenant isolation, authorization, credentials, the build), major (the shapes), minor (naming, layout, logging), each citing a file and line or an empty grep, with the rule and the fix; then the user's decisions. Change code only when asked
- [ ] swift build and swift test; report each result, or why it couldn't run
```

## References

Read the reference for the part at hand:

| Reference | Covers |
|---|---|
| [system.md](references/system.md) | Splitting into services, contracts, how services talk, the shared packages, the plan |
| [packages.md](references/packages.md) | Targets and their imports, `Package.swift`, Swift settings, traits and Foundation, layouts, boundary checks |
| [stack.md](references/stack.md) | The libraries, which target links each, Foundation linking, choosing versions |
| [use-cases.md](references/use-cases.md) | Models, errors, repositories, ports, a use case's five files and body, transactions, authorization |
| [persistence.md](references/persistence.md) | Scopes per database role, row-level security, statements, migrations, Valkey |
| [grpc.md](references/grpc.md) | Contracts, proto services, handlers, conversions, paging, status codes, clients, transports |
| [gateway.md](references/gateway.md) | OpenAPI types, request contexts and tiers, controllers, webhooks, errors, upstream clients |
| [workflows.md](references/workflows.md) | Starting workflows, payloads, determinism, activities and options, versions, the worker |
| [composition.md](references/composition.md) | Commands, composition roots, configuration, logging, the ServiceGroup |
| [security.md](references/security.md) | The trust model, mTLS, user tokens, authorization layers, secrets, webhooks |
| [style.md](references/style.md) | How the code reads: errors, concurrency, imports, Foundation, types, formatting |
| [testing.md](references/testing.md) | Test targets, what each proves, mocks |
| [delivery.md](references/delivery.md) | CI workflows per package kind, releases, deployment, the Containerfile, Dependabot |
| [conventions.md](references/conventions.md) | Naming a package, target, type, file, key or folder |

## Related skills

For the code inside the shapes, load these when installed; where this skill states a shape, follow it:
- Actors, task groups, cancellation, `Sendable` diagnostics, Swift 6 migration: `swift-concurrency`
- Argument labels, method names, documentation comments: `swift-api-design-guidelines`
- Tests of use cases, handlers and workflows: `swift-testing-expert`
