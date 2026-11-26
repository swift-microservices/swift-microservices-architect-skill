# The system

How a backend splits into services, how they talk, and the packages they share. The examples are Bookshelf, the lending library in `SKILL.md`.

## Contents
- Splitting a system into services
- Naming a service
- Contracts
- How services talk
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

## Data placement

A service's data is its own: only the service reads and writes it, and every other process reaches it through the service's contract.

- A service that stores data has its own Postgres instance, holding its database (`bookshelf_loans`). A service that stores nothing has none, and one whose state is all short-lived has Valkey alone.
- A plan may instead put every service's database on one instance per environment, recorded under Decisions. Databases, roles and policies stay as they are, since each role's name carries its service's name ([naming](conventions.md#naming)); each database admits only its own roles ([Postgres](security.md#postgres)), and every service's pools together stay within that instance's connections.
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
- The platform each environment deploys to, its servers' CPU architectures, the image registry and the CI host: the user's answers, with no default ([delivery](delivery.md))
- Each service's Postgres instance: how its roles log in, its TLS mode and the rest of its setup: the user's answers ([Postgres](security.md#postgres))
- How each process connects to Temporal, each service's namespace and its retention: the user's answers ([the worker](workflows.md#the-worker))
- Backups and point-in-time recovery of Postgres and Temporal's store, and whether Temporal's authorizer confines each identity to its namespace: the user's answers
- Each environment's certificate authority, a developer's machine included, and how a developer runs Postgres, Valkey and Temporal: the user's answers
- Each topic's partitions and retention, for a service with events ([events](events.md))

## Build order
1. [ ] <project>-core and <project>-protos: Start a project
2. [ ] The token issuer: Add a service
3. [ ] Each other service, before its callers, a line each: Add a service
4. [ ] <project>-gateway: Add the gateway
5. [ ] Production: Prepare for production

## Questions
- Each question for the user, with the answer the plan assumes
```

Review the plan against the hard rules in `SKILL.md`, and put its questions to the user, before writing code.

## Out of scope

Decided separately, outside this skill: setting up the platform and its servers, compose files, networks and VPNs, the edge proxy, certificate issuance and renewal, observability backends, backups and point-in-time recovery of Postgres and Temporal's store, client SDKs and frontends. How each package is tested, released and deployed is [delivery](delivery.md). The architecture leaves room for each: an executable runs wherever its configuration points, and certificates and keys are files at configured paths.
