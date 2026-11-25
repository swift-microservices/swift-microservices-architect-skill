# The system

How a backend splits into services, how they talk, and the packages they share. The examples are Bookshelf, the lending library in `SKILL.md`.

## Contents
- Splitting a system into services
- Naming a service
- Contracts
- How services talk
- Erasing a person's data
- Data placement
- The shared packages
- The plan
- Out of scope

## Splitting a system into services

A service is a capability that owns its data and the rules over it. Identity owns accounts, credentials and sessions; Catalog owns books; Loans owns who has borrowed what. Only the owner reads and writes its tables and its cache; every other process reaches that data through the owner's contract.

The organizations callers act for, and who belongs to each, are the token issuer's: it decides whether a caller may act for an organization before naming it in a token ([organization tenants](persistence.md#organization-tenants)). Identity owns Bookshelf's branches and their librarians, and Loans keeps only a loan's `branch_id`.

Draw a boundary by data and change:
- **One service** when one kind of change touches both parts, or one transaction must cover both. Borrowing checks a member's active loans and records the new one atomically, so both are Loans.
- **Separate services** when each part has its own data, its own rules and its own reason to change: the catalog changes with how books are described, loans with lending policy.
- **Separate models** when a noun means something different on each side. To Catalog a book is a description with copies; to Loans it's an id and a title for a notice, modeled as `Book` in LoansCore's `Catalog/`.

Then check what the split costs. Across a boundary cross only ids and the few fields the consumer needs, through internal RPCs; a step that must also happen on the other side runs as a workflow. Keep the parts in one service when splitting them would need a shared table, a distributed transaction, or a call to the other side on every request.

Avoid:
- A service per entity or table (`Books`, `Copies`, `Members`): every operation crosses the network.
- A shared service that owns other services' tables, or a "common" service of leftovers.
- Splitting before the second capability exists. A capability starts as an area inside its service's Core (`LoansCore/Loans/`) and moves out when its data, rules and pace of change stand apart.

Moving an area into its own service takes these steps, in order:
1. Release its contract.
2. Give it its own package, database, roles and executable.
3. Give the remaining use cases a model in a folder named for the new service, a port and a gRPC client in place of its repository.

A step that was atomic across the two becomes a workflow. Moving or dropping data, or deleting a migration, is never inferred: finish the non-destructive work and ask the user.

## Naming a service

- A noun for the capability: `Identity`, `Catalog`, `Loans`. [Naming](conventions.md#naming) gives its package, repository and targets.
- Module names are unique across the whole package graph. A service named `Authentication` collides twice, its executable with swift-authentication's `Authentication` and its gRPC target with `AuthenticationGRPC`. Check a name's targets against every product in the graph (`Logging`, `Configuration`, `Metrics`, `Tracing`, `Crypto`, `Temporal`, `Valkey`) and pick another name rather than an exception to the target scheme.
- A model's name clashes the same way with a type every file sees: Swift Testing's `Test`, `Suite` and `Tag` in test files, the standard library's `Task` and `Result` everywhere. The model takes a fuller noun, and its repository, use cases and folders follow it.

## Contracts

Each service publishes one proto package, `<project>.<x>.v1`, with one `XService` and at most one `XInternalService`:

| Proto service | Called by | Admitted by |
|---|---|---|
| `XService` | People, through the gateway | Per RPC: anyone, the caller's own (the token names the user), a role, or administrators |
| `XInternalService` | Other services and workers | The peer's mTLS certificate alone, its DNS names against each RPC's callers; requests name the user they act on |

- Inside `XService`, RPCs are grouped by audience. Anyone's RPCs carry their own proof when they need one (a password, a refresh token, a webhook signature). The caller's own RPCs name no user: the service takes the account from the token. Administrators' RPCs name the users they act on.
- A service with no process calling in has no internal service. An RPC that would answer anyone's question about someone else (an account by email) is internal only.
- Proto services and RPCs are named as [naming](conventions.md#naming) gives them.
- Each contract owns its messages; no message is shared between contracts.
- A create that a client may retry carries an `idempotency_key`; the owner deduplicates on it. A request that opens a record is a create whatever its verb: `BorrowBook` opens a loan.

Message rules and the package layout: [contracts in the protos package](grpc.md#contracts-in-the-protos-package).

## How services talk

| Need | Mechanism |
|---|---|
| An answer now from the owner of the data | Unary gRPC to its `XInternalService`, over mTLS, as the calling process |
| A person's request | The gateway, which forwards the caller's token to the owning service's `XService` ([gateway](gateway.md)) |
| Work that must happen eventually, waits for time or a signal, retries, or touches several services | A Temporal workflow in Core, started by a use case ([workflows](workflows.md)) |
| A fact about a service's data that other services react to, each on its own | An event on Kafka, recorded in the transaction that makes the change ([events](events.md)) |

- Work that must be seen through is a workflow, never a message on a queue or a topic: Temporal holds the retries, the timers and the history. [Choosing a mechanism](events.md#choosing-a-mechanism) sets workflows and events apart.
- Calls between services form no cycle. Break one by moving ownership, extracting a third capability, or making one direction a workflow or an event.
- What each hop proves, and where a user's token may travel: [the trust model](security.md#the-trust-model).

## Erasing a person's data

A person's data lives in every service that keeps rows about them, so erasing it is a workflow of the service that owns the person:

- Identity's `CloseAccount` use case closes the account and starts `AccountErasureWorkflow` after its commit. One activity per service that keeps rows about members calls that service's internal `Erase…` RPC with the user's id: Loans' `EraseMemberLoans`. A service that starts keeping rows about members adds its RPC and its activity in the same change.
- Each `Erase…` use case deletes what the service owns about the person, or replaces it where a record must stay, such as a loan a branch accounts for, and answers the same when run again.
- The workflow's calls run against the usual direction, Identity to Loans, which a workflow may do without forming a call cycle ([how services talk](#how-services-talk)).
- Workflow payloads and log lines carry ids, never personal data ([reaching a run](workflows.md#reaching-a-run-from-a-use-case), [logging](use-cases.md#logging)), so a history and a log hold nothing to erase; the namespace's retention bounds how long histories keep those ids.

## Data placement

A service's data is its own: only the service reads and writes it, and every other process reaches it through the service's contract.

- A service that stores data has its own Postgres instance, holding its database (`bookshelf_loans`). A service that stores nothing has none, and one whose state is all short-lived has Valkey alone.
- A plan may instead put every service's database on one instance per environment, recorded under Decisions. Databases, roles and policies stay as they are, since each role's name carries its service's name ([naming](conventions.md#naming)); each database admits only its own roles ([Postgres](security.md#postgres)), and Operations sizes every service's pools against that one instance.
- Its processes connect as the owner for migrations, then a role per audience, `<x>_service`, `<x>_internal` and `<x>_worker`, each with its own policy and none with `BYPASSRLS` ([database roles](persistence.md#database-roles)). A service with no tenant table has one role; a plan that joins `<x>_internal` and `<x>_worker` records it under Decisions ([the plan](#the-plan)).
- How the roles log in, the TLS mode and the rest of the instance's setup are the user's answers ([Postgres](security.md#postgres)).
- A table whose rows belong to a user, or to an organization its callers act for, is a tenant table under [row-level security](persistence.md#row-level-security).
- Short-lived values with an expiry live in [Valkey](persistence.md#valkey).

## The shared packages

Besides the swift-microservices libraries ([stack](stack.md)), every service and the gateway depend on two packages of the project's own.

**`<project>-core`** holds what every service would otherwise write identically:

| Product | Holds |
|---|---|
| `<Project>Authentication` | `UserIdentity` (the token's claims), `UserRole`, `OperationContext.user`, `Logger.MetadataProvider.user`, `JWTIssuer(privateKey:)` and `JWTAuthenticator(publicKeys:)` |
| `<Project>Persistence` | `PostgresSettings.user(_:)`, `UserSettingsInterceptor`, `PostgresClient.Configuration(config:role:)`, shaped by the plan's answer on how roles log in |
| `<Project>Transport` | The configuration readers every executable shares: mTLS transport security, the certificate reloader's configuration, HTTP/2 transport tuning, `ServiceConfig`, the token authenticator; `InternalCallerInterceptor` |
| `<Project>Events` | The Kafka readers, `OutboxRelay`, `EventHandler`, `EventRejection` and `EventConsumer`, for a service with [events](events.md) |
| `<Project>Testing` | The mocks every service would write alike: `MockDatabase<Scope>`, `MockAuthenticator` ([testing](testing.md)) |

It holds none of these: a service's models, repositories, scopes or migrations; contracts; deployment defaults such as mount paths, ports and role names, which stay in each executable's `InMemoryProvider` defaults; generic abstractions, which belong to the swift-microservices libraries; a process identity or service token, since certificates prove processes.

**`<project>-protos`** holds one target per contract (`IdentityProtos`, `CatalogProtos`, `LoansProtos`), generated at build time, so a consumer links only the contracts it calls. A package of its own lets contracts release apart from `<project>-core`.

Both packages: [the project's core package](packages.md#the-projects-core-package), [the contracts package](packages.md#the-contracts-package).

## The plan

Planning a backend, or a change that adds or splits a service, produces this document before any code is written. It's the `README.md` of its own repository, `<project>-plan`, since every package is a repository of its own and none holds the whole system. Work in a package reads it from the checkout beside that package's, or asks the user where it is.

The plan stays current: each Build order line is ticked once its checklist is done, and a departure from a default joins Decisions in the change that makes it.

```markdown
# <System> backend

## Services
| Service | Owns | Tables (tenant?) | Workflows | Short-lived state |
|---|---|---|---|---|

## Contracts
| Proto service | RPC | Audience: anyone, own, a role, administrators, or internal (callers) |
|---|---|---|

## Module maps
### <project>-<x>
| Target | Holds |
|---|---|
- Commands: `serve`, `worker run`, `migrate`, `build-indexes`
- Data: its Postgres instance, the database roles and the use cases each runs
- Calls out to: other services' internal RPCs, providers, Temporal, Valkey, Kafka

## Shared packages
- <project>-core: each product and what it holds
- <project>-protos: one target per contract

## Events
| Topic | Publisher | Consumers, and what each does with it |
|---|---|---|

## Gateway routes
| Route | Tier | Upstream RPC |
|---|---|---|

## Decisions
- Each boundary and why it holds; each departure from a default or exception to a rule, and each open choice's pick, with its reason and the sources the search found ([reading like the requirement](style.md#reading-like-the-requirement))

## Operations
| Environment | Each service's Postgres instance: its `max_connections`, each process's replicas and role pools, and their total | Collector endpoint | Stop timeout | Each topic's partitions and retention |
|---|---|---|---|---|

| Tier, or a route set apart | Availability over 30 days | Latency at the 99th percentile |
|---|---|---|

| Alert | Source | Fires when | Runbook |
|---|---|---|---|
- Runbooks, as numbered steps: a bad deploy, a stuck or nondeterministic workflow, certificate renewal, a signing key's rotation
- Each service's Postgres instance: how its roles log in, its TLS mode and the rest of its setup: the user's answers ([Postgres](security.md#postgres))
- How each process connects to Temporal: the user's answer ([the worker](workflows.md#the-worker))
- Backups and point-in-time recovery of Postgres and Temporal's store, each service's Temporal namespace and its retention, and whether Temporal's authorizer confines each identity to its namespace: the user's answers
- Each environment's certificate authority, a developer's machine included, and how a developer runs Postgres, Valkey and Temporal: the user's answers
- The platform each environment deploys to, its servers' CPU architectures, the image registry and the CI host: the user's answers, with no default ([delivery](delivery.md))

## Build order
1. [ ] <project>-core and <project>-protos: Start a project
2. [ ] The token issuer: Add a service
3. [ ] Each other service, before its callers, a line each: Add a service
4. [ ] <project>-gateway: Add the gateway
5. [ ] Production: Prepare for production

## Questions
- Each question for the user, with the answer the plan assumes
```

Operations' targets and thresholds are the user's answers; what they measure, the gateway and Temporal already emit:

- Objectives take a row per route tier ([request contexts and tiers](gateway.md#request-contexts-and-tiers)), and one per route whose work sets it apart, such as sign-in, which bcrypt slows. The gateway's `MetricsMiddleware` measures both ([a trace across processes](observability.md#a-trace-across-processes)): availability from its count of requests by route and status, as the share answered without a `5xx`, and latency from its duration, which covers only requests answered without an error, since it counts a thrown problem but doesn't time it.
- Alerts: error rate and latency per tier, against its objective; failed and timed-out runs, and failing workflow tasks, per namespace; schedule-to-start latency per task queue, which rises when no worker polls or every worker is busy; each consumer group's lag per topic, which rises when a handler retries one event or falls behind ([the worker](events.md#the-worker)). The workflow alerts read Temporal's own metrics. A nondeterministic run never fails: its workflow task fails on every retry, so only the failing-task alert sees it.
- A bad deploy: run Deploy to production with the last commit production ran, never reverting a migration ([a service's CI workflows](delivery.md#a-services-ci-workflows)). Callers and the gateway roll back before a service whose new RPC they call, the reverse of [the order they deploy in](grpc.md#contracts-in-the-protos-package), and the fix goes forward through staging.
- A stuck workflow: rising schedule-to-start latency means its task queue's worker isn't polling; otherwise its pending activity's last failure names the dependency it waits on, and the activity's retries resume it once that recovers.
- A nondeterministic workflow: roll back to the image before the change, so the runs that started before it replay and resume; the runs the bad image started then fail on replay and are reset, as `temporal-developer` describes. The change returns behind a patch, with a failed run's history among the replays `XCoreTests` runs ([changing a workflow](workflows.md#changing-a-workflow)).
- Certificate renewal, which the deployment performs in the order [mutual TLS](security.md#mutual-tls) gives: a renewed pair at the mount paths needs no deploy.
- A signing key's rotation, in [its runbook's](security.md#signing-keys) three steps.

Review the plan against the hard rules in `SKILL.md`, and put its questions to the user, before writing code.

## Out of scope

Decided separately, outside this skill: setting up the platform and its servers, compose files, networks and VPNs, the edge proxy, certificate issuance and renewal, observability backends, backups and point-in-time recovery of Postgres and Temporal's store, client SDKs and frontends. How each package is tested, released and deployed is [delivery](delivery.md). The architecture leaves room for each: an executable runs wherever its configuration points, and certificates and keys are files at configured paths.
