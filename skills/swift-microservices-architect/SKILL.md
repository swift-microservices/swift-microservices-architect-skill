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

In names, `X` stands for the service in a target (`LoansCore`) and for what a type is named after (`BorrowBookUseCase`, `LoanRepository`); `<Project>` and `<project>` stand for the project's name. Examples are Bookshelf, a lending library:

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
| Messages between processes; the public API | `<project>-protos`; the gateway's OpenAPI document |
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

- One `do` holds the work through its `return`, and each `catch` ends its path, so every outcome reads in one place: nothing is declared before the `do` for a `catch` to fill, and a `do` nests only around a workflow's start ([errors](references/style.md#errors)).
- Build, then call: a value a call takes is a named `let`, never a conversion, `try` or `await` in the arguments, so each step reads as one named fact and a failure points at one line ([style](references/style.md#build-then-call)).
- No helper methods in use cases, workflows or activities, so each reads top to bottom as its requirement; a step worth naming is a policy's method, a port or another activity. No `Result` juggling, steering flags, `try?` or force unwraps, which hide a failure the caller must map.
- Everything crossing a boundary is `Sendable`; no `Task {}` or `Task.detached {}`, and unchecked concurrency only where [concurrency](references/style.md#concurrency) allows.

## Troubleshooting

- A component left out of the `ServiceGroup` never runs: a `GRPCClient` or `PostgresClient` never connects, and its calls hang to their deadline.
- The worker's `gracefulShutdownPeriod` defaults to zero, so every deploy cancels in-flight activities and repeats their effects ([worker's root](references/composition.md#the-workers-root)).
- The database owner bypasses row-level security: only `migrate` and `build-indexes` connect as it ([migrations](references/persistence.md#migrations)).
- Policies combine with `OR`, so a session acting for a branch also sees the branch's rows in the caller's own queries: a caller's own read names the user in its `WHERE`, and a branch's read names the branch ([tenants](references/persistence.md#organization-tenants)).
- Temporal checks `Codable` only at run time: every workflow and activity payload, and each type it holds, is `Codable, Sendable` ([workflows](references/workflows.md#a-workflow)).
- Workflow code is replayed: the clock, `UUID()`, randomness, `Task.sleep(for:)` or any I/O breaks it ([determinism](references/workflows.md#determinism)).
- An event published after its commit, not from the outbox, is lost if the process stops first ([outbox](references/events.md#the-outbox)).
- A token whose `kid` a verifier's key file lacks fails there as `unauthenticated`, so a new key reaches every verifier before Identity signs with it ([signing keys](references/security.md#signing-keys)).

## Prerequisites

- A Swift toolchain at the package's `swift-tools-version`; for `XPostgresTests` and `XValkeyTests`, Postgres 18 and Valkey 9 or later, through `POSTGRES_*` and `VALKEY_*` ([tests](references/delivery.md#tests)).
- swift-format, for the lint every change passes ([formatting](references/style.md#formatting)).
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
| [checklists.md](references/checklists.md) | Every task: its checklist |
| [system.md](references/system.md) | Planning, adding or splitting a service; how services talk; where data lives |
| [packages.md](references/packages.md) | A package, a target's dependencies, what Core may link |
| [stack.md](references/stack.md) | A library or version, or whether one links full Foundation |
| [use-cases.md](references/use-cases.md) | A model, error, repository, port or use case; transactions and authorization |
| [persistence.md](references/persistence.md) | A scope, statement, migration, policy or tenant table; pools; Valkey |
| [grpc.md](references/grpc.md) | A contract, handler, conversion, client, paged list or transport |
| [gateway.md](references/gateway.md) | A route or its breaking change, a request context, controller, webhook route or error mapping |
| [workflows.md](references/workflows.md) | A workflow, activity container or worker; starting or reaching a run |
| [events.md](references/events.md) | An event, or choosing one over a workflow |
| [composition.md](references/composition.md) | A command, composition root, configuration and its readers, logging, telemetry, health or the ServiceGroup |
| [security.md](references/security.md) | mTLS, Postgres logins, tokens and their key files, secrets or webhooks |
| [style.md](references/style.md) | Writing or reviewing any Swift |
| [testing.md](references/testing.md) | Writing tests or mocks |
| [delivery.md](references/delivery.md) | CI, releases, the gate or the deployment contract |
| [delivery-dokploy.md](references/delivery-dokploy.md) | Deploying to Dokploy |
| [conventions.md](references/conventions.md) | Naming anything or placing a file |
| [related-skills.md](references/related-skills.md) | Work a related skill covers |

## Related skills

[related-skills.md](references/related-skills.md) names the skill for each task's technique, and where this skill wins over one.

## Instructions

Copy the task's checklist from [checklists.md](references/checklists.md) into the response, **Verify**'s lines replacing a `Verify` item, and tick items when done. A line naming a related skill invokes it with the Skill tool there ([installing them](references/related-skills.md#installing-them)). A new backend runs Plan a backend, then each Build order line's checklist ([the plan](references/system.md#the-plan)); with no task, propose the next unticked line.

| Checklist | When |
|---|---|
| [Verify](references/checklists.md#verify) | Last, in every task that changes code; a review runs its build and tests |
| [Plan a backend](references/checklists.md#plan-a-backend) | A new backend, or a change that adds or splits a service |
| [Start a project](references/checklists.md#start-a-project) | The shared packages, before the first service |
| [Add a service](references/checklists.md#add-a-service) | A new service |
| [Add an operation](references/checklists.md#add-an-operation) | An RPC, endpoint or use case |
| [Add a durable process](references/checklists.md#add-a-durable-process) | Work that waits, retries or spans services |
| [Add an event](references/checklists.md#add-an-event) | A fact other services react to |
| [Add the gateway](references/checklists.md#add-the-gateway) | The public HTTP API |
| [Prepare for production](references/checklists.md#prepare-for-production) | Before the first production deploy |
| [Set up CI/CD](references/checklists.md#set-up-cicd) | A package's CI, release and deploy |
| [Review a backend](references/checklists.md#review-a-backend) | Reviewing a backend's architecture or code style |
