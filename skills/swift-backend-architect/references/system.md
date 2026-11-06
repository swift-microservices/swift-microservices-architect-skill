# The system

How a backend splits into services, how they talk, and the packages they share. The examples are Bookshelf, the lending library in `SKILL.md`.

## Contents
- Splitting a system into services
- Naming a service
- Contracts
- How services talk
- Data ownership and storage
- The shared packages
- The gateway's place
- The plan
- Out of scope

## Splitting a system into services

A service is a capability that owns its data and the rules over it. Identity owns accounts, credentials and sessions; Catalog owns books; Loans owns who has borrowed what. Only the owner reads and writes its tables; every other process reaches that data through the owner's contract.

Draw a boundary by data and change:
- **One service** when one kind of change touches both parts, or one transaction must cover both. Borrowing checks a member's active loans and records the new one atomically, so both are Loans.
- **Separate services** when each part has its own data, its own rules and its own reason to change: the catalog changes with how books are described, loans with lending policy.
- **Separate models** when a noun means something different on each side. To Catalog a book is a description with copies; to Loans it's an id and a title for a notice, modeled as `Book` in LoansCore's `Ports/`.

Then check what the split costs. Across a boundary cross only ids and the few fields the consumer needs, through internal RPCs; a step that must also happen on the other side runs as a workflow. A split that needs a shared table, a distributed transaction or an RPC on every request of the other side is one service.

Avoid:
- A service per entity or table (`Books`, `Copies`, `Members`): every operation crosses the network.
- A shared service that owns other services' tables, or a "common" service of leftovers.
- Splitting before the second capability exists. A capability starts as an area inside its service's Core (`LoansCore/Loans/`) and moves out when its data, rules and pace of change stand apart.

## Naming a service

- A noun for the capability: `Identity`, `Catalog`, `Loans`. Its package and repository are `<org>-<service>` (`bookshelf-loans`), its targets `X…` ([naming](conventions.md#naming)).
- Module names are unique across the whole package graph. A service named `Authentication` collides twice, its executable with swift-authentication's `Authentication` and its gRPC target with `AuthenticationGRPC`. Check a name's targets against every product in the graph (`Logging`, `Configuration`, `Metrics`, `Tracing`, `Crypto`, `Temporal`, `Valkey`) and pick another name rather than an exception to the target scheme.

## Contracts

Each service publishes one proto package, `<org>.<service>.v1`, with up to two proto services:

| Proto service | Called by | Admitted by |
|---|---|---|
| `XService` | People, through the gateway | Per RPC: anyone, the caller's own (the token names the user), or administrators |
| `XInternalService` | Other services and workers | The peer's mTLS certificate alone; requests name the user they act on |

- Inside `XService`, RPCs are grouped by audience. Anyone's RPCs carry their own proof when they need one (a password, a refresh token, a webhook signature). The caller's own RPCs name no user: the service takes the account from the token. Administrators' RPCs name the users they act on.
- A service with no process calling in has no internal service. An RPC that would answer anyone's question about someone else (an account by email) is internal only.
- Proto services are named for their resource (`BookService`, `LoanService`), or for the service when its RPCs aren't about one resource (`IdentityService`).
- RPCs use the standard verbs where they fit (`GetBook`, `ListBooks`, `CreateBook`, `UpdateBook`, `DeleteBook`) and a domain verb otherwise (`BorrowBook`, `ReturnBook`). An administrators' list of what the caller's own RPC also lists is `ListAllX`.
- Each contract owns its messages; no message is shared between contracts.
- A create that a client may retry carries an `idempotency_key`; the owner deduplicates on it.

Message rules and the package layout: [contracts in the protos package](grpc.md#contracts-in-the-protos-package).

## How services talk

| Need | Mechanism |
|---|---|
| An answer now from the owner of the data | Unary gRPC to its `XInternalService`, over mTLS, as the calling process |
| A person's request | The gateway, which forwards the caller's token to the owning service's `XService` |
| Work that must happen eventually, waits for time or a signal, retries, or touches several services | A Temporal workflow, started through a Core port ([workflows](workflows.md)) |

- A user's token never travels on an internal call; the calling process proves itself with its certificate, and its request names the user.
- No service reads another's database or cache, or shares a table with it.
- Every call between processes has a deadline. A call inside an open database transaction holds a pooled connection for its whole duration, so transactions make no remote calls ([transactions](use-cases.md#transactions)).
- Durable work is a workflow, not a message on a queue: Temporal holds the retries, the timers and the history.

## Data ownership and storage

- Each service owns its storage. Where it lives is a deployment decision: a database per service on one shared Postgres instance, an instance per service, or a managed store for a small service. The module map doesn't change with it: storage is an adapter target behind Core's repository protocols ([other stores](persistence.md#other-stores)).
- On Postgres: a database per service (`bookshelf_loans`), an owner only migrations connect as, and a role per purpose that processes connect as ([database roles](persistence.md#database-roles)).
- A table whose rows belong to a user and are read as that user is a tenant table, isolated by row-level security (`loans`). Public data (`books`) and credential material found by a secret on anonymous paths (refresh tokens by digest) have no tenant policy ([row-level security](persistence.md#row-level-security)).
- Short-lived values with an expiry (one-time codes, challenges, rate counters) live in Valkey, as their only copy or as a cache, never data that must survive a restart of the store ([Valkey](persistence.md#valkey)).

## The shared packages

Besides the swift-microservices libraries ([stack](stack.md)), every service and the gateway depend on two packages of the organization's own.

**`<org>-core`**, the organization layer, holds what every service would otherwise write identically:

| Product | Holds | Linked by |
|---|---|---|
| `<Org>Authentication` | `UserIdentity` (the token's claims), `UserRole`, `OperationContext.user`, `Logger.MetadataProvider.user`, the EdDSA `JWTAuthenticator` and `JWTIssuer` initializers | XCore, XGRPC, XHTTP, executables |
| `<Org>Persistence` | `PostgresSettings.user(_:)`, `UserSettingsInterceptor`, `UserSettingsMiddleware`, `PostgresClient.Configuration(config:role:)` | Executables with Postgres |
| `<Org>Transport` | The configuration readers every executable shares: mTLS transport security, the certificate reloader's configuration, HTTP/2 transport tuning, `ServiceConfig`, the token keys | Executables |
| `<Org>Testing` | Test doubles: `MockDatabase<Scope>`, a table-backed authenticator | Test targets |

It holds none of these: a service's models, repositories, scopes or migrations; contracts; deployment defaults such as mount paths, ports and role names, which stay in each executable's `InMemoryProvider` defaults; generic abstractions, which belong to the swift-microservices libraries; a process identity or service token, since certificates prove processes.

**`<org>-protos`** holds one target per contract (`IdentityProtos`, `CatalogProtos`, `LoansProtos`), generated at build time, so a consumer links only the contracts it calls. A small system may keep the `XProtos` targets in `<org>-core` as separate products; a separate package lets contracts version and release on their own.

Both packages: [the organization's core package](packages.md#the-organizations-core-package), [the contracts package](packages.md#the-contracts-package).

## The gateway's place

The gateway, `<org>-gateway`, is the only process clients reach. It owns the public HTTP API, described by an OpenAPI document; verifies the caller's token to choose a route's tier; and forwards each request with the original token to the owning service's `XService`. It owns no tables and no business rules, and each service authorizes again in its use cases ([gateway](gateway.md)).

## The plan

Planning a backend, or a change that adds or splits a service, produces this document before any code is written:

```markdown
# <System> backend

## Services
| Service | Owns | Tables (tenant?) | Workflows | Short-lived state |
|---|---|---|---|---|

## Contracts
| Proto service | RPC | Audience: anyone, own, administrators, or internal (callers) |
|---|---|---|

## Module maps
### <org>-<service>
| Target | Holds |
|---|---|
- Commands: `serve [--migrate-database]`, `worker run`
- Database roles and the use cases each runs
- Calls out to: other services' internal RPCs, providers, Temporal, Valkey

## Shared packages
- <org>-core: each product and what it holds
- <org>-protos: one target per contract

## Gateway routes
| Route | Tier | Upstream RPC |
|---|---|---|

## Decisions
- Each boundary and why it holds; each exception to a rule, with its reason
```

Review the plan against the hard rules in `SKILL.md` before writing code.

## Out of scope

Decided separately, outside this skill: CI/CD, deployment, container images and compose files, networks and VPNs, the edge proxy, certificate issuance and renewal, observability backends, client SDKs and frontends, and tests. The architecture leaves room for each: an executable runs wherever its configuration points, and certificates and keys are files at configured paths.
