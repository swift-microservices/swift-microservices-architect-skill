---
name: swift-microservices-architect
description: Architects and checks Swift server backends. Use when planning a Swift backend or splitting it into services, adding a service, endpoint, use case, repository, migration, webhook, multi-tenant table, background job, Kafka event or durable Temporal workflow, drawing a Swift server's module boundaries or writing its Package.swift, wiring configuration, graceful shutdown, mTLS or JWT auth, naming server types and targets, setting up a server package's tests, CI/CD, deployment or Dokploy, or reviewing a Swift server's architecture or code style. Builds them as gRPC microservices behind a Hummingbird gateway, one Swift package per service, with Postgres row-level security, Valkey and Temporal. Not for iOS, macOS or SwiftUI apps. Applies even when the user doesn't name the architecture.
license: MIT
metadata:
  author: Zaid Rahhawi
  tags: swift, server-side-swift, microservices, grpc, temporal
---

# Swift Microservices Architect

## Purpose

Decides how a Swift backend splits into services and modules, who owns what and the shapes that hold a service together. A backend built another way keeps its structure and conventions unless the user asks otherwise, and takes only the shapes it lacks.

## Examples

`X` is a service in a target's name (`LoansCore`) and what a type is named for (`BorrowBookUseCase`); `<Project>` and `<project>` are the project. Examples are Bookshelf, a lending library:

| Package | Holds |
|---|---|
| `bookshelf-identity` | Accounts, sessions, branches and their librarians; issues every access token; reset codes in Valkey; members for other services |
| `bookshelf-catalog` | Books: anyone reads, administrators edit, Loans looks up internally; counts borrows from Loans' events |
| `bookshelf-loans` | A member's loans, a tenant table a branch's librarians read too; a workflow marks a loan overdue and sends a notice |
| `bookshelf-gateway` | The public HTTP API over the services' gRPC contracts |
| `bookshelf-core` | `BookshelfAuthentication`, `BookshelfPersistence`, `BookshelfTransport`, `BookshelfEvents`, `BookshelfTesting` |
| `bookshelf-protos` | `IdentityProtos`, `CatalogProtos`, `LoansProtos` |

## The shape

```
Clients ── HTTPS ──► edge (TLS ends) ── HTTP ──► Gateway (Hummingbird, OpenAPI)
Gateway ── gRPC, mTLS, the caller's JWT ──► each service's XService
Service, worker ── gRPC, mTLS ──► another service's XInternalService
Service, worker ──► Temporal, and its own Postgres, as the plan's answers set
Worker ── TLS ──► Kafka
```

## A service's package

```
<project>-x
├── XCore         models, errors, repository protocols and commands, ports, use cases, workflows, activity containers
├── XPostgres     a scope per database role, repositories, statements, migrations
├── XGRPC         XService and XInternalService, Protobuf conversions, gRPC clients for Core's ports
├── XValkey       repositories for short-lived values
├── XKafka        event handlers and publishers
├── X<Provider>   a third-party API behind a Core port (LoansResend)
└── X             executable: commands, configuration defaults, migrations, composition roots
```

A service has only the targets it needs, each importing only what [its row](references/packages.md#the-targets-of-a-service) lists. Hard rules:
- XCore imports no driver, transport, contract, configuration or lifecycle module ([Core's links](references/packages.md#what-core-may-link)).
- XCore imports Temporal only in `Workflows/` and the use cases that reach a workflow, and never builds its client or worker.
- Adapter targets never import each other or Temporal; the executable hands one to another through Core's protocols.
- Generated contract types never leave XGRPC, XKafka, the gateway's HTTP target and executables.
- Only an executable reads configuration, builds clients and runs the `ServiceGroup`.
- No service reads another's database; data crosses services only through contracts.

## Who owns what

| Concern | Owner |
|---|---|
| Business rules, authorization decisions, what an error means | The use case, in XCore; adapters only convert and delegate |
| What a service knows about another's data | A model in an XCore folder named for the owning service (`LoansCore/Catalog/`), never in `Ports/` |
| Protobuf ↔ domain, HTTP ↔ protobuf | `Protobuf/` in XGRPC and XKafka; the gateway's `Schemas/` |
| Messages between processes; the public API | `<project>-protos`; the gateway's `openapi.yaml` |
| Who the caller is | The token, verified by the gateway and again by each service |
| Which processes may call an internal RPC | The plan's callers per RPC, admitted by their certificates' DNS names through `InternalCallerInterceptor`; never the gateway |
| Tenant isolation | Row-level security; `<Project>Persistence` binds the caller per transaction, and each audience's use cases run as [its database role](references/persistence.md#database-roles) |
| Durable, delayed or multi-service work | A Temporal workflow in XCore's `Workflows/` |
| Facts other services react to | An [event](references/events.md) |
| What every service needs identically | `<project>-core`: identity, tenant binding, transport readers, `<Project>Events` |

## Code style

Code reads like the requirement it implements, with Apple's WWDC sample code as the bar. Use cases map errors this way:

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
- Build, then call: a value a call takes is a named `let`, never a conversion, `try` or `await` in the arguments ([style](references/style.md#build-then-call)).
- No helper methods in use cases, workflows or activities, and no `Result` juggling, steering flags, `try?` or force unwraps.
- Everything crossing a boundary is `Sendable`; no `Task {}` or `Task.detached`, and unchecked concurrency only where [concurrency](references/style.md#concurrency) allows.

## Troubleshooting

- A component left out of the `ServiceGroup` never runs: a `GRPCClient` or `PostgresClient` never connects, and its calls hang to their deadline.
- The worker's `gracefulShutdownPeriod` defaults to zero, so every deploy cancels in-flight activities and repeats their effects ([worker's root](references/composition.md#the-workers-root)).
- The database owner bypasses row-level security: only `migrate` and `build-indexes` connect as it ([migrations](references/persistence.md#migrations)).
- Policies combine with `OR`: a session acting for an organization reaches its rows through the caller's own use cases ([tenants](references/persistence.md#organization-tenants)).
- Temporal checks `Codable` only at run time: every workflow and activity payload, and each type it holds, is `Codable, Sendable` ([workflows](references/workflows.md#a-workflow)).
- Workflow code is replayed: `Date.now`, `UUID()`, randomness, `Task.sleep` or any I/O in a workflow breaks it ([determinism](references/workflows.md#determinism)).
- An event published after its commit, not from the outbox, is lost if the process stops first ([outbox](references/events.md#the-outbox)).
- A token whose `kid` a verifier's key file lacks fails there as `unauthenticated`; keys change by [a runbook](references/security.md#signing-keys).

## Prerequisites

- A Swift toolchain at the package's `swift-tools-version`; for `XPostgresTests` and `XValkeyTests`, Postgres 18 and Valkey 9 or later, through `POSTGRES_*` and `VALKEY_*` ([tests](references/delivery.md#tests)).
- Network access for an XCore with workflows: its build fetches Temporal's sdk-core and its tests the test server ([Core's links](references/packages.md#what-core-may-link)).
- The [related skills](#related-skills) `system-design`, `architecture`, `code-review`, `deploy-checklist`, `incident-response`, `temporal-developer`, `supabase-postgres-best-practices`, `valkey`, `swift-testing-pro`, `swift-concurrency-pro` and `swift-api-design-guidelines-skill`.

## Available Scripts

Each is in this skill's `scripts/`, runs from the package's root and exits non-zero on failure:

| Script | Purpose | Arguments |
|---|---|---|
| `scripts/swift_ci.sh` | `swift build` or `swift test` with the flags CI applies | `[--library] <build\|test> [arguments…]` |
| `scripts/check_boundaries.sh` | The boundaries SPM can't check | `<X> <Project>` from a service's or the gateway's root: `Loans Bookshelf` |
| `scripts/check_style.sh` | The style rules a script can see in the sources | None |

## Limitations

- A workflow start or signal lost after its commit is recovered only by the client's retry ([transactions](references/use-cases.md#transactions)).
- Not covered: what [out of scope](references/system.md#out-of-scope) lists; ask the user, never invent it.

## References

Read a reference only when the task reaches its row or a checklist names it.

| Reference | Read when |
|---|---|
| [system.md](references/system.md) | Planning, adding or splitting a service; how services talk; where data lives |
| [packages.md](references/packages.md) | A package, a target's dependencies, what Core may link |
| [stack.md](references/stack.md) | A library or version, or whether one links full Foundation |
| [use-cases.md](references/use-cases.md) | A model, error, repository, port or use case; transactions and authorization |
| [persistence.md](references/persistence.md) | A scope, statement, migration, policy or tenant table; pools; Valkey |
| [grpc.md](references/grpc.md) | A contract, handler, conversion, client, paged list or transport |
| [gateway.md](references/gateway.md) | A route or its breaking change, a request context, controller, webhook route or error mapping |
| [workflows.md](references/workflows.md) | A workflow, activity container or worker; starting or reaching a run |
| [events.md](references/events.md) | An event, or choosing one over a workflow |
| [composition.md](references/composition.md) | A command, composition root, configuration, logging, health or the ServiceGroup |
| [observability.md](references/observability.md) | Telemetry, or a request's trace across processes |
| [security.md](references/security.md) | mTLS, Postgres logins, tokens and their key files, secrets, attempt limits or webhooks |
| [style.md](references/style.md) | Writing or reviewing any Swift |
| [testing.md](references/testing.md) | Writing tests or mocks |
| [delivery.md](references/delivery.md) | CI, releases, deployment, the Containerfile or Dependabot |
| [delivery-dokploy.md](references/delivery-dokploy.md) | Deploying to Dokploy |
| [conventions.md](references/conventions.md) | Naming anything or placing a file |
| [related-skills.md](references/related-skills.md) | Work a related skill covers |

## Related skills

[related-skills.md](references/related-skills.md) names the skill for each task's technique, and where this skill wins over one.

## Instructions

Copy the task's checklist into the response, **Verify**'s lines replacing a `Verify` item, and tick items when done; its `.md` files are in `references/`. A line naming a related skill invokes it with the Skill tool there (related-skills.md#installing-them). A new backend runs **Plan a backend**, then each Build order line's checklist (system.md#the-plan); with no task, propose the next unticked line.

**Plan a backend**

```
- [ ] Requirements, scale and trade-offs with system-design; each open choice searched online (style.md#reading-like-the-requirement), weighed with architecture
- [ ] The capabilities and the data each owns; a service per capability (system.md#splitting-a-system-into-services)
- [ ] Name each service, its target names clashing with no module in the graph
- [ ] Per service: XService RPCs by audience, XInternalService RPCs and callers with no call cycle, tables (tenant or not), workflows, events, short-lived state
- [ ] Invoke temporal-developer before shaping the plan's workflows
- [ ] Per service: its targets and commands; its own Postgres and roles, if it stores data (system.md#data-placement)
- [ ] <project>-core's products, <project>-protos' contracts, the gateway's routes by tier
- [ ] Write the plan from system.md#the-plan; check it against the hard rules and put its questions, with Postgres's, Temporal's and the platform's setup, to the user before any code
```

**Start a project**

```
- [ ] The plan's answers on certificate authorities, Postgres, Temporal and local runs
- [ ] <project>-core: the plan's products, tested with swift-testing-pro (packages.md#the-projects-core-package)
- [ ] <project>-protos: a target per contract (packages.md#the-contracts-package)
- [ ] Set up CI/CD for each and tag its first release; scripts/check_style.sh and swift-format lint
```

**Add a service**

```
- [ ] Search online (style.md#reading-like-the-requirement), then design with system-design and architecture
- [ ] <project>-protos: XProtos with XService, and XInternalService if processes call in
- [ ] Package <project>-x from packages.md#packageswift-template, with only the targets the plan names
- [ ] XCore: models, errors, repositories, ports, a use case per RPC (use-cases.md)
- [ ] XPostgres: roles, tables, row-level security, statements, a scope per role (persistence.md), the SQL with supabase-postgres-best-practices
- [ ] XGRPC: proto services over the use cases, conversions, clients for ports (grpc.md)
- [ ] XCore's Workflows/, XValkey, XKafka, X<Provider> as the plan needs; a workflow designed with temporal-developer, a Valkey command chosen with valkey
- [ ] X: commands, InMemoryProvider defaults, Migrations over XPostgres' lists, Migrate, Serve with grpc.health.v1, BuildIndexes, and Run with a worker (composition.md)
- [ ] Gateway, once built: routes for the public RPCs (gateway.md)
- [ ] A test target per module testing.md lists, over mocks, a file per tested type, with swift-testing-pro
- [ ] Set up CI/CD as a service
- [ ] Verify
```

**Add an operation**

```
- [ ] Search online (style.md#reading-like-the-requirement), then design with system-design and architecture
- [ ] Contract: the RPC under its audience in XService, or in XInternalService
- [ ] XCore: the use case's files; its scope lists only what it touches (use-cases.md); an event it records (events.md#the-outbox)
- [ ] A workflow run it affects, reached from the use case (workflows.md#reaching-a-run-from-a-use-case)
- [ ] XPostgres: the scopes of the roles it may run as adopt its scope protocol; new SQL with supabase-postgres-best-practices
- [ ] XGRPC: the handler and the input's conversion, every error case mapped
- [ ] Executable: the use case on its role's database, passed to the service
- [ ] Gateway: the route in its tier, if public
- [ ] Tests: the use case's outcomes and the handler's statuses, over mocks, with swift-testing-pro
- [ ] Verify
```

**Add a durable process**

```
- [ ] Search online (style.md#reading-like-the-requirement), then design with system-design and architecture
- [ ] Design the workflow with temporal-developer: waiting, handlers, compensation, versioning (workflows.md#changing-a-workflow)
- [ ] Each person's change: its use case writes it, then signals the run, or sends an update if only the run decides (workflows.md#reaching-a-run-from-a-use-case)
- [ ] XCore: the system use cases its activities run, adopted by the worker scope (use-cases.md#system-use-cases)
- [ ] XCore/Workflows/<WorkflowName>/: the workflow, its activity container over use case and port protocols, named ActivityOptions (workflows.md)
- [ ] The use case that starts it, holding TemporalClient and the task queue, after its transaction commits, by a deterministic id
- [ ] Executable: TemporalClient and the task queue into Serve's use cases; the worker group and its Run root
- [ ] Tests: the workflow and the starting use case on the test server, its activities over mocks, with swift-testing-pro
- [ ] Verify
```

**Add an event**

```
- [ ] An event, not a workflow or RPC (events.md#choosing-a-mechanism), in the plan's Events
- [ ] Publisher: its contract, outbox and relay (events.md#the-outbox)
- [ ] Each consumer: a system use case safe to run twice, its handler (events.md#consumers)
- [ ] Worker roots (events.md#the-worker); tests over mocks, with swift-testing-pro
- [ ] Verify
```

**Add the gateway**

```
- [ ] Package <project>-gateway (packages.md#the-gateway-package)
- [ ] GatewayHTTP: openapi.yaml first, then each route's tier, controller, conversions and errors (gateway.md)
- [ ] Gateway: its command and Serve root (composition.md#the-gateways-root)
- [ ] GatewayHTTPTests over mocks, with swift-testing-pro
- [ ] Set up CI/CD as a service
- [ ] Verify
```

**Prepare for production**

```
- [ ] Each role's pool and timeouts, within Postgres's max_connections (persistence.md#connections-and-timeouts)
- [ ] Each root: grpc.health.v1, observability, secrets from files, the worker's shutdown period (composition.md)
- [ ] The plan's Operations, answered by the user (system.md#the-plan)
- [ ] Each release's checks and rollback triggers with deploy-checklist (related-skills.md)
- [ ] Verify
```

**Verify**

```
- [ ] scripts/swift_ci.sh build and test with POSTGRES_* and VALKEY_* set (delivery.md#tests); report any suite that can't run
- [ ] scripts/check_boundaries.sh and scripts/check_style.sh (packages.md#checking-the-boundaries), and swift-format lint
- [ ] Each skill the task's checklist names was invoked with the Skill tool, or reported as skipped
- [ ] Fix and repeat until all pass; a concurrency diagnostic goes through swift-concurrency-pro, never silenced; a warning in a dependency's code is a departure (style.md#warnings-from-dependencies)
```

**Set up CI/CD**

```
- [ ] The package's kind: public library, system library or service (delivery.md#package-kinds)
- [ ] Its CI workflows, on a swift-microservices/ci release's commit; dependabot.yml, .swift-format (style.md#formatting), .license_header_template, .licenseignore and the secrets
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
- [ ] Swift settings, each target listing every module it imports (packages.md#packageswift-template), package access, naming (conventions.md) and API design with swift-api-design-guidelines-skill
- [ ] Security, performance and correctness with code-review (related-skills.md); hand-rolled schemes (style.md#reading-like-the-requirement)
- [ ] Findings ranked blocking (tenant isolation, authorization, credentials, the build), major (shapes), minor (naming, layout, logging), each with a file and line or an empty grep, the rule and the fix; change code only when asked
- [ ] scripts/swift_ci.sh build and test; report each result, or why it couldn't run
```
