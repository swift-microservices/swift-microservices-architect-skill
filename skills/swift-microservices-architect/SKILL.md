---
name: swift-microservices-architect
description: Architects and checks Swift server backends. Use when planning a Swift backend or splitting it into services, adding a service, endpoint, use case, repository, migration, webhook, multi-tenant table, background job or durable Temporal workflow, drawing a Swift server's module boundaries or writing its Package.swift, wiring configuration, graceful shutdown, mTLS or JWT auth, naming server types and targets, setting up a server package's tests, CI/CD or deployment, or reviewing a Swift server's architecture or code style. Builds them as gRPC microservices behind a Hummingbird gateway, one Swift package per service, with Postgres row-level security, Valkey and Temporal workflows. Not for iOS, macOS or SwiftUI apps. Applies even when the user doesn't name the architecture.
license: MIT
metadata:
  author: Zaid Rahhawi
  tags: swift, server-side-swift, microservices, grpc, temporal
---

# Swift Microservices Architect

## Purpose

Decides how a Swift backend splits into services and modules, where code lives and who owns it, and the shapes that hold a service together, from Core's use cases to its adapters, composition roots, tests and deployment. In a backend built another way, keep its structure and conventions unless the user asks to change them, and take a shape from this skill only for what the backend lacks.

## Examples

`X` stands for a service in a target's name (`LoansCore`) and for what a type is named for (`BorrowBookUseCase`, `LoanService`); `<Project>` and `<project>` for the project. The examples are Bookshelf, a small lending library:

| Package | Holds |
|---|---|
| `bookshelf-identity` | Accounts, sessions, branches and their librarians; issues every access token; reset codes in Valkey; members for other services |
| `bookshelf-catalog` | Books: anyone reads, administrators edit; Loans looks books up internally |
| `bookshelf-loans` | A member's loans, a tenant table a branch's librarians read too; a workflow marks a loan overdue and sends a notice |
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
- XCore imports Temporal only in `Workflows/` and the use cases that reach a workflow, and never builds its client or worker.
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
| Who the caller is | The token, verified by the gateway and again by each service |
| Which processes may call an internal RPC | The callers the plan lists, admitted by certificate through `InternalCallerInterceptor`; never the gateway |
| Tenant isolation | Row-level security; `<Project>Persistence` binds the caller to each transaction, and each audience's use cases run as [their database role](references/persistence.md#database-roles) |
| Durable, delayed or multi-service work | A Temporal workflow in XCore's `Workflows/` |
| What every service needs identically | `<project>-core`: identity, tenant binding, transport readers |

## Code style

Code reads like the requirement it implements, with Apple's WWDC sample code as the bar ([style](references/style.md)). Use cases map errors this way; a handler or activity maps a use case's error with `do throws(XUseCaseError)` and an exhaustive `switch` ([errors](references/style.md#errors)):

```swift
do {
    …  // the work, in the order the requirement states it
} catch let error as BorrowBookUseCaseError {
    throw error
} catch CatalogClientError.unavailable {
    logger.warning("Borrowing failed: the catalog is unavailable")
    throw .catalogUnavailable
} catch is CancellationError {
    throw .unknown
} catch {
    logger.error("Borrowing failed: unknown error", metadata: ["error": "\(error)"])
    throw .unknown
}
```

- One `do` holds the work through its `return`, and each `catch` ends its path: nothing is declared before the `do` for a `catch` to fill, and a `do` nests only around a workflow's start ([errors](references/style.md#errors)).
- Build, then call: a value a call takes is a named `let`, never a conversion, `try` or `await` in the arguments ([build, then call](references/style.md#build-then-call)).
- No helper methods in use cases, workflows or activities, and no `Result` juggling, steering flags, `try?`, nested `do` in a `catch`, or force unwraps.
- Swift 6 mode with `ExistentialAny`, `MemberImportVisibility`, `InternalImportsByDefault`, `NonisolatedNonsendingByDefault` and strict memory safety ([Swift settings](references/packages.md#swift-settings)); `package` access across a service's targets.
- Everything crossing a boundary is `Sendable`; no `Task {}` or `Task.detached`, and unchecked concurrency only where [concurrency](references/style.md#concurrency) allows it.

## Troubleshooting

- A component left out of the `ServiceGroup` never runs: an unrun `GRPCClient` or `PostgresClient` never connects, so its calls hang until their deadline.
- The worker's `gracefulShutdownPeriod` defaults to zero, so every deploy cancels in-flight activities and repeats their effects ([the worker's root](references/composition.md#the-workers-root)).
- The database owner bypasses row-level security: only `serve --migrate-database` and `build-indexes` connect as it, and the migrating application's health check waits out its migrations ([migrations](references/persistence.md#migrations)).
- Policies combine with `OR`: on a table with a user's and an organization's, a session acting for the organization reaches its rows through the caller's own use cases ([organization tenants](references/persistence.md#organization-tenants)).
- Temporal checks `Codable` only at run time: every workflow and activity payload, and each type it holds, is `Codable, Sendable` ([workflows](references/workflows.md#a-workflow)).
- Workflow code is replayed: `Date.now`, `UUID()`, randomness, `Task.sleep` or any I/O in a workflow breaks it ([determinism](references/workflows.md#determinism)).
- A plain or scoped `import Foundation` in owned code links full Foundation on Linux; use the conditional `FoundationEssentials` import.

## Prerequisites

- A Swift toolchain at the package's `swift-tools-version`; for `XPostgresTests` and `XValkeyTests`, Postgres 18 and Valkey 9 or later, through `POSTGRES_*` and `VALKEY_*` ([tests](references/delivery.md#tests)).
- Network access for an XCore with workflows: its build fetches Temporal's sdk-core binary and its tests the test server ([what Core may link](references/packages.md#what-core-may-link), [test targets](references/testing.md#test-targets)).
- The [related skills](#related-skills) `temporal-developer`, `supabase-postgres-best-practices`, `valkey`, `swift-testing-pro`, `swift-concurrency-pro` and `swift-api-design-guidelines-skill`; ask the user once to install a missing one (`npx skills add <source> --skill <name>`) and carry on.

## Available Scripts

Each is in this skill's `scripts/`, runs from the package's root and exits non-zero on any failure:

| Script | Purpose | Arguments |
|---|---|---|
| `scripts/swift_ci.sh` | `swift build` or `swift test` with the flags CI applies ([tests](references/delivery.md#tests)) | `[--library] <build\|test> [arguments…]` |
| `scripts/check_boundaries.sh` | The boundaries SPM can't check ([checking the boundaries](references/packages.md#checking-the-boundaries)) | `<X> <Project>` from a service's or the gateway's root: `Loans Bookshelf` |
| `scripts/check_style.sh` | The style rules a script can see in the sources | None |

## Limitations

- A workflow start or signal lost after its transaction commits is recovered only when the client retries the request ([transactions](references/use-cases.md#transactions)).
- Not covered: setting up Dokploy and its servers, compose files, networks, the edge proxy, certificate issuance, observability backends, backups, client SDKs and frontends; ask the user rather than invent them.

## References

Read a reference only when the task reaches its row or a checklist item names it.

| Reference | Read when |
|---|---|
| [system.md](references/system.md) | Planning a backend, adding or splitting a service, how services talk, where data lives |
| [packages.md](references/packages.md) | Creating a package, changing a target's dependencies, what Core may link |
| [stack.md](references/stack.md) | Choosing a library or version, or whether one links full Foundation |
| [use-cases.md](references/use-cases.md) | Writing a model, error, repository, port or use case; transactions and authorization |
| [persistence.md](references/persistence.md) | Writing a scope, statement, migration, policy or tenant table; pools; Valkey |
| [grpc.md](references/grpc.md) | Changing a contract, handler, conversion, client, paged list or transport |
| [gateway.md](references/gateway.md) | A route, request context, controller, webhook route or error mapping |
| [workflows.md](references/workflows.md) | A workflow, activity container or worker, or starting or reaching a run |
| [composition.md](references/composition.md) | A command, composition root, configuration, logging, health checks or the ServiceGroup |
| [observability.md](references/observability.md) | Bootstrapping telemetry or tracing a request across processes |
| [security.md](references/security.md) | mTLS, database logins, tokens, secrets, attempt limits or webhooks |
| [style.md](references/style.md) | Writing or reviewing any Swift |
| [testing.md](references/testing.md) | Writing tests or mocks |
| [delivery.md](references/delivery.md) | CI, releases, deployment, the Containerfile or Dependabot |
| [conventions.md](references/conventions.md) | Naming anything or placing a file |

## Related skills

They cover the code inside the shapes, and this skill's shapes and rules win over their examples. Load each when its task comes up:
- A workflow's design: its history, signals and updates, waiting, compensation, versioning: `temporal-developer` ([source](https://github.com/temporalio/skill-temporal-developer))
- A table's policy, grants, indexes and column types, and what a migration locks: `supabase-postgres-best-practices` ([source](https://github.com/supabase/agent-skills))
- The Valkey command for an operation, its expiry and atomicity: `valkey` ([source](https://github.com/valkey-io/valkey-skills))
- Test code, with Swift Testing: `swift-testing-pro` ([source](https://github.com/twostraws/Swift-Testing-Agent-Skill))
- Actors, task groups, cancellation, `Sendable` and strict-concurrency diagnostics: `swift-concurrency-pro` ([source](https://github.com/twostraws/Swift-Concurrency-Agent-Skill))
- Argument labels, method names, documentation comments: `swift-api-design-guidelines-skill` ([source](https://github.com/Erikote04/Swift-API-Design-Guidelines-Agent-Skill))

## Instructions

Copy the task's checklist into the response, with **Verify**'s lines in place of a `Verify` item, and check items off as they're done; each `.md` file it names is in `references/`.

**Plan a backend**

```
- [ ] The capabilities and the data each owns; a service per capability (system.md#splitting-a-system-into-services)
- [ ] Name each service; check its target names against every module in the graph
- [ ] Per service: XService RPCs by audience, XInternalService RPCs and callers with no call cycle, tables (tenant or not), workflows, short-lived state
- [ ] With workflows in the plan: load temporal-developer before shaping them
- [ ] Per service: its targets and commands; whether it stores data, where, its roles and how processes prove them (system.md#data-placement)
- [ ] <project>-core's products, <project>-protos' contracts, the gateway's routes by tier
- [ ] Build order: <project>-core and <project>-protos, the token issuer, each service before its callers, the gateway
- [ ] Write the plan from system.md#the-plan; check it against the hard rules and put its questions to the user before any code
```

**Add a service**

```
- [ ] The feature's established approach (style.md#reading-like-the-requirement)
- [ ] <project>-protos: XProtos with XService, and XInternalService if processes call in
- [ ] Package <project>-x from packages.md#packageswift-template, with only the targets the plan names
- [ ] XCore: models, errors, repositories, ports, a use case per RPC (use-cases.md)
- [ ] XPostgres: roles, tables, row-level security, statements, a scope per role (persistence.md), the SQL with supabase-postgres-best-practices
- [ ] XGRPC: proto services over the use cases, conversions, clients for ports (grpc.md)
- [ ] XCore's Workflows/, XValkey, X<Provider> as the plan needs; a workflow designed with temporal-developer, a Valkey command chosen with valkey
- [ ] X: commands, InMemoryProvider defaults, Migrations over XPostgres' lists, Serve with its health service, Health, BuildIndexes, and Run with a worker (composition.md)
- [ ] Gateway: routes for the public RPCs (gateway.md)
- [ ] A test target per module testing.md lists, over mocks, a file per tested type, written with swift-testing-pro
- [ ] Its CI workflows, Containerfile, .swift-format and Dependabot as a service (delivery.md, style.md#formatting)
- [ ] Verify
```

**Add an operation**

```
- [ ] The feature's established approach (style.md#reading-like-the-requirement)
- [ ] Contract: the RPC under its audience in XService, or in XInternalService
- [ ] XCore: the use case's files; its scope lists only what it touches (use-cases.md)
- [ ] A workflow run it affects, reached from the use case (workflows.md#reaching-a-run-from-a-use-case)
- [ ] XPostgres: the scopes of the roles it may run as adopt its scope protocol; new SQL with supabase-postgres-best-practices
- [ ] XGRPC: the handler and the input's conversion, every error case mapped
- [ ] Executable: the use case on its role's database, passed to the service
- [ ] Gateway: the route in its tier, if public
- [ ] Tests: the use case's outcomes and the handler's statuses, over mocks, written with swift-testing-pro
- [ ] Verify
```

**Add a durable process**

```
- [ ] The feature's established approach (style.md#reading-like-the-requirement)
- [ ] Design the workflow with temporal-developer: waiting, handlers, compensation, versioning (workflows.md#changing-a-workflow); without a Swift reference there, read the SDK's documentation
- [ ] Each person's change is written by its use case, then signalled if the run waits on it, or sent as an update if only the run can decide (workflows.md#reaching-a-run-from-a-use-case)
- [ ] XCore: the system use cases its activities run, adopted by the worker scope (use-cases.md#system-use-cases)
- [ ] XCore/Workflows/<WorkflowName>/: the workflow, its activity container over use case and port protocols, named ActivityOptions (workflows.md)
- [ ] The use case that starts it, holding TemporalClient and the task queue, after its transaction commits, by a deterministic id
- [ ] Executable: TemporalClient and the task queue into Serve's use cases; the worker group and its Run root
- [ ] Tests: the workflow and the starting use case on the test server, its activities over mocks, written with swift-testing-pro
- [ ] Verify
```

**Prepare for production**

```
- [ ] Each role's pool and timeouts, within Postgres's max_connections (persistence.md#connections-and-timeouts)
- [ ] Each root: health, observability, secrets from files, the worker's shutdown period (composition.md)
- [ ] The plan's Operations, answered by the user (system.md#the-plan)
- [ ] Verify
```

**Verify**

```
- [ ] scripts/swift_ci.sh build and test with POSTGRES_* and VALKEY_* set (delivery.md#tests); report any suite that can't run
- [ ] scripts/check_boundaries.sh and scripts/check_style.sh (packages.md#checking-the-boundaries), and swift-format lint
- [ ] Fix and repeat until all pass; a concurrency diagnostic goes through swift-concurrency-pro, never silenced
```

**Set up CI/CD**

```
- [ ] The package's kind: public library, system library or service (delivery.md#package-kinds)
- [ ] Its CI workflows, calling swift-microservices/ci at a release's commit; dependabot.yml, .swift-format (style.md#formatting), .license_header_template, .licenseignore and the secrets
- [ ] A library: the semver labels and .github/release.yml; a service: its Containerfile
- [ ] scripts/swift_ci.sh build and test, with --library for a library and POSTGRES_* and VALKEY_* for a service (delivery.md#tests); fix and repeat until both pass
```

**Review a backend**

```
- [ ] scripts/check_boundaries.sh from each service's and the gateway's root, scripts/check_style.sh from every package's
- [ ] Each use case: its files, typed throws, one catch per case, no helpers, the right database role
- [ ] Each adapter only converts and delegates; every error case is mapped
- [ ] Each root: configuration read only there, every component in the ServiceGroup in dependency order
- [ ] Workflows checked with temporal-developer, tests with swift-testing-pro, and actors, Mutexes and unchecked concurrency with swift-concurrency-pro
- [ ] Swift settings, each target listing every module it imports (packages.md#packageswift-template), FoundationEssentials imports, package access, naming (conventions.md)
- [ ] Findings ranked blocking (tenant isolation, authorization, credentials, the build), major (shapes), minor (naming, layout, logging), each with a file and line or an empty grep, the rule and the fix; change code only when asked
- [ ] scripts/swift_ci.sh build and test; report each result, or why it couldn't run
```
