# Swift Microservices Architect

An agent skill that designs and maintains Swift server backends: gRPC microservices behind a Hummingbird API gateway, each service one Swift package with a Core of typed-throws use cases and an adapter target per technology, composed and run by its executable.

This README is for people. Agents read [SKILL.md](skills/swift-microservices-architect/SKILL.md) and the files in [references/](skills/swift-microservices-architect/references/). Agents changing the skill follow [CLAUDE.md](CLAUDE.md).

## Why this architecture

- **Boundaries the compiler enforces.** Each layer of a service is an SPM target. Core can't import a driver, a transport or a generated contract, and adapters can't import each other, so "the use case must not know about Postgres" is a build error rather than a review comment.
- **The service is its use cases.** Rules, authorization decisions and the meaning of every error live in typed-throws use cases. gRPC services, HTTP routes, Temporal activities and repositories only translate, so a transport or a store changes without touching the rules.
- **Code that reads like the requirement.** One `do` holding the whole path, one `catch` per outcome, every value a call takes built first in a named `let`, no helper methods: a use case, a workflow or a handler reads top to bottom, the way Apple's WWDC sample code does.
- **Every hop proves itself.** Mutual TLS between processes with certificates that reload without a restart, the caller's token verified by every service, and Postgres row-level security under every tenant query.
- **One composition root per process.** swift-configuration reads everything once, defaults live in one `InMemoryProvider`, and swift-service-lifecycle runs every client, server and worker in one structured task with graceful shutdown.
- **Durable work on Temporal.** Anything that waits, retries or spans services is a workflow started by a deterministic id, not a fire-and-forget task.
- **Modern Swift throughout.** Swift 6 mode with `ExistentialAny`, `MemberImportVisibility`, `InternalImportsByDefault` and `NonisolatedNonsendingByDefault`, `package` access, and `FoundationEssentials`, so services drop full Foundation as their dependencies do.

## What the skill covers

- Splitting a backend into services by data ownership, naming them, and writing the plan: services, contracts, module maps, shared packages and gateway routes.
- A service's package: `XCore`, `XPostgres`, `XGRPC`, `XTemporal`, `XValkey`, `X<Provider>`, `XHTTP` and the executable, their dependency direction, what Core may link, and `Package.swift` with its Swift settings, Swift Evolution proposals, and the package traits that keep full Foundation out, with each stack package's Foundation status.
- The organization's shared packages: `<org>-core` for identity, tenant binding and transport configuration, and `<org>-protos` for contracts.
- The swift-microservices libraries (`OperationContext`, `Authentication` with its JWT, gRPC and Hummingbird adapters, `Persistence` and `PersistencePostgres`) and the server stack around them.
- The application layer: domain models, errors, repositories, ports, use cases with typed throws, scope protocols, transactions, authorization and logging.
- Persistence: Postgres scopes per database role, row-level security bound from the caller's token, statements, migrations, other stores, and Valkey for short-lived values.
- gRPC: contracts with paged lists, `XService` and `XInternalService`, handlers, conversions, status codes, interceptors, clients for ports and transports.
- The gateway: Hummingbird request contexts in tiers, the router, controllers, provider webhooks, problem details, and upstream clients that forward the caller's token.
- Temporal: starting workflows from use cases, deterministic workflows, activities over use cases and ports, options, versioning and the worker.
- Composition: commands, configuration readers and defaults, logging, the `ServiceGroup` and why it matters.
- Security: the trust model, mTLS with certificate reloading, user tokens, authorization layers, secrets and webhooks.
- Testing: a test target per module over mocks of its protocols, and the shared mocks in `<org>-core`'s testing product.
- CI/CD: the GitHub Actions CI workflows of a public library, a system library and a service over swiftlang's, Apple's and swift-microservices' reusable workflows, semver releases, an image per commit on GitHub Container Registry deployed through Dokploy to staging and then to production, and Dependabot.
- Code style and naming conventions.

Out of scope for now: setting up Dokploy and its servers, compose files, networks and VPNs, the edge proxy, certificate issuance and renewal, observability backends, client SDKs and frontends.

Covered by other skills the agent loads alongside this one:
- Swift Concurrency: [Swift Concurrency](https://github.com/AvdLee/Swift-Concurrency-Agent-Skill)
- Swift Testing: [Swift Testing Expert](https://github.com/AvdLee/Swift-Testing-Agent-Skill)

## Layout

```
swift-microservices-architect-skill/
├── .claude-plugin/                  Claude Code plugin and marketplace manifests
├── skills/swift-microservices-architect/
│   ├── SKILL.md                     entry point: shape, rules, style, gotchas, workflows, which reference to read
│   └── references/
│       ├── system.md                services, contracts, how services talk, data ownership, shared packages, the plan
│       ├── packages.md              targets, dependency direction, Package.swift, Swift settings, traits, layouts, boundary checks
│       ├── stack.md                 the swift-microservices libraries, the server stack, each one's Foundation status
│       ├── use-cases.md             models, errors, repositories, ports, use cases, transactions, authorization, logging
│       ├── persistence.md           Postgres scopes and roles, row-level security, migrations, other stores, Valkey
│       ├── grpc.md                  contracts, services, handlers, conversions, interceptors, clients, transports
│       ├── gateway.md               request contexts, router, controllers, errors, upstream clients, the edge
│       ├── workflows.md             Temporal workflows, activities, options, versions, the worker
│       ├── composition.md           commands, composition roots, configuration, logging, lifecycle
│       ├── security.md              trust model, mTLS, tokens, authorization, secrets, webhooks
│       ├── testing.md               test targets per module, mocks, the shared testing product
│       ├── delivery.md              CI/CD per package kind: workflows, tests, releases, images, deployment
│       ├── style.md                 how the code reads
│       └── conventions.md           naming, folders, files
├── .github/                         CI: validation, the semver label check, releases, Dependabot
├── scripts/check_skill.py           the checks to run after every change to the skill
├── CLAUDE.md                        authoring rules and skill best practices for agents changing the skill
├── README.md
└── LICENSE
```

## Installation

**Claude Code plugin**

```
/plugin marketplace add swift-microservices/swift-microservices-architect-skill
/plugin install swift-microservices-architect@swift-microservices-architect-skill
```

**skills CLI**

```bash
npx skills add https://github.com/swift-microservices/swift-microservices-architect-skill --skill swift-microservices-architect
```

**Manual**

Copy `skills/swift-microservices-architect/` to `~/.claude/skills/swift-microservices-architect/` (all your projects) or to `.claude/skills/swift-microservices-architect/` in a repository (shared with the team).

Claude Code loads the skill when a task matches its description, or on request with `/swift-microservices-architect`.

## License

MIT. See [LICENSE](LICENSE).
