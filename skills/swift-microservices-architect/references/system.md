# The system

How a backend splits into services, how they talk, and the packages they share. The examples are Bookshelf, the lending library in `SKILL.md`.

## Contents
- Splitting a system into services
- Naming a service
- Contracts
- How services talk
- Data ownership and storage
- The shared packages
- The plan
- Out of scope

## Splitting a system into services

A service is a capability that owns its data and the rules over it. Identity owns accounts, credentials and sessions; Catalog owns books; Loans owns who has borrowed what. Only the owner reads and writes its tables and its cache; every other process reaches that data through the owner's contract.

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

- A noun for the capability: `Identity`, `Catalog`, `Loans`. [Naming](conventions.md#naming) gives its package, repository and targets.
- Module names are unique across the whole package graph. A service named `Authentication` collides twice, its executable with swift-authentication's `Authentication` and its gRPC target with `AuthenticationGRPC`. Check a name's targets against every product in the graph (`Logging`, `Configuration`, `Metrics`, `Tracing`, `Crypto`, `Temporal`, `Valkey`) and pick another name rather than an exception to the target scheme.

## Contracts

Each service publishes one proto package, `<org>.<service>.v1`, with up to two proto services:

| Proto service | Called by | Admitted by |
|---|---|---|
| `XService` | People, through the gateway | Per RPC: anyone, the caller's own (the token names the user), or administrators |
| `XInternalService` | Other services and workers | The peer's mTLS certificate alone; requests name the user they act on |

- Inside `XService`, RPCs are grouped by audience. Anyone's RPCs carry their own proof when they need one (a password, a refresh token, a webhook signature). The caller's own RPCs name no user: the service takes the account from the token. Administrators' RPCs name the users they act on.
- A service with no process calling in has no internal service. An RPC that would answer anyone's question about someone else (an account by email) is internal only.
- Proto services and RPCs are named as [naming](conventions.md#naming) gives them.
- Each contract owns its messages; no message is shared between contracts.
- A create that a client may retry carries an `idempotency_key`; the owner deduplicates on it.

Message rules and the package layout: [contracts in the protos package](grpc.md#contracts-in-the-protos-package).

## How services talk

| Need | Mechanism |
|---|---|
| An answer now from the owner of the data | Unary gRPC to its `XInternalService`, over mTLS, as the calling process |
| A person's request | The gateway, which forwards the caller's token to the owning service's `XService` ([gateway](gateway.md)) |
| Work that must happen eventually, waits for time or a signal, retries, or touches several services | A Temporal workflow, started through a Core port ([workflows](workflows.md)) |

- Durable work is a workflow, not a message on a queue: Temporal holds the retries, the timers and the history.
- What each hop proves, and where a user's token may travel: [the trust model](security.md#the-trust-model).

## Data ownership and storage

- Each service owns its storage. Where it lives is a deployment decision: a database per service on one shared Postgres instance, an instance per service, or a managed store for a small service. The module map doesn't change with it: storage is an adapter target behind Core's repository protocols ([other stores](persistence.md#other-stores)).
- On Postgres: a database per service (`bookshelf_loans`) with an owner and a role per purpose ([database roles](persistence.md#database-roles)); a table whose rows belong to a user is a tenant table under [row-level security](persistence.md#row-level-security).
- Short-lived values with an expiry live in [Valkey](persistence.md#valkey).

## The shared packages

Besides the swift-microservices libraries ([stack](stack.md)), every service and the gateway depend on two packages of the organization's own.

**`<org>-core`**, the organization layer, holds what every service would otherwise write identically:

| Product | Holds | Linked by |
|---|---|---|
| `<Org>Authentication` | `UserIdentity` (the token's claims), `UserRole`, `OperationContext.user`, `Logger.MetadataProvider.user`, the EdDSA `JWTAuthenticator` and `JWTIssuer` initializers | XCore, XGRPC, XHTTP, executables |
| `<Org>Persistence` | `PostgresSettings.user(_:)`, `UserSettingsInterceptor`, `UserSettingsMiddleware`, `PostgresClient.Configuration(config:role:)` | Executables with Postgres |
| `<Org>Transport` | The configuration readers every executable shares: mTLS transport security, the certificate reloader's configuration, HTTP/2 transport tuning, `ServiceConfig`, the token keys | Executables |
| `<Org>Testing` | The mocks every service would write alike: `MockDatabase<Scope>`, `MockAuthenticator` ([testing](testing.md)) | Test targets |

It holds none of these: a service's models, repositories, scopes or migrations; contracts; deployment defaults such as mount paths, ports and role names, which stay in each executable's `InMemoryProvider` defaults; generic abstractions, which belong to the swift-microservices libraries; a process identity or service token, since certificates prove processes.

**`<org>-protos`** holds one target per contract (`IdentityProtos`, `CatalogProtos`, `LoansProtos`), generated at build time, so a consumer links only the contracts it calls. A small system may keep the `XProtos` targets in `<org>-core` as separate products; a separate package lets contracts version and release on their own.

Both packages: [the organization's core package](packages.md#the-organizations-core-package), [the contracts package](packages.md#the-contracts-package).

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

Decided separately, outside this skill: setting up the deployment platform and its servers, compose files, networks and VPNs, the edge proxy, certificate issuance and renewal, observability backends, client SDKs and frontends. How each package is tested, released and deployed is [delivery](delivery.md). The architecture leaves room for each: an executable runs wherever its configuration points, and certificates and keys are files at configured paths.
