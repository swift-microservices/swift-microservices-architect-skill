# Checklists

Each task's checklist, which the agent copies into its response as [the instructions](../SKILL.md#instructions) give. Its `.md` files are references beside this one, and its scripts are in the skill's `scripts/`.

## Contents
- Verify
- Plan a backend
- Start a project
- Add a service
- Add an operation
- Add a durable process
- Add an event
- Add the gateway
- Prepare for production
- Set up CI/CD
- Review a backend

## Verify

```
- [ ] scripts/swift_ci.sh build and test with POSTGRES_* and VALKEY_* set (delivery.md#tests); report any suite that can't run
- [ ] scripts/check_boundaries.sh and scripts/check_style.sh (packages.md#checking-the-boundaries), and swift-format lint
- [ ] Each skill the task's checklist names was invoked with the Skill tool, or reported as skipped
- [ ] Fix and repeat until all pass; a concurrency diagnostic goes through swift-concurrency-pro, never silenced; a warning in a dependency's code is a departure (style.md#warnings-from-dependencies)
- [ ] A check that couldn't run here, such as a missing toolchain, Postgres or swift-format, stays unticked, and the response says why
```

## Plan a backend

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

## Start a project

```
- [ ] The plan's answers on certificate authorities, Postgres, Temporal and local runs
- [ ] <project>-core: the plan's products, tested with swift-testing-pro (packages.md#the-projects-core-package)
- [ ] <project>-protos: a target per contract (packages.md#the-contracts-package)
- [ ] Set up CI/CD for each and tag its first release; scripts/check_style.sh and swift-format lint
```

## Add a service

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

## Add an operation

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

## Add a durable process

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

## Add an event

```
- [ ] An event, not a workflow or RPC (events.md#choosing-a-mechanism), in the plan's Events
- [ ] Publisher: its contract, outbox and relay (events.md#the-outbox)
- [ ] Each consumer: a system use case safe to run twice, its handler (events.md#consumers)
- [ ] Worker roots (events.md#the-worker); tests over mocks, with swift-testing-pro
- [ ] Verify
```

## Add the gateway

```
- [ ] Package <project>-gateway (packages.md#the-gateway-package)
- [ ] GatewayHTTP: openapi.yaml first, then each route's tier, controller, conversions and errors (gateway.md)
- [ ] Gateway: its command and Serve root (composition.md#the-gateways-root)
- [ ] GatewayHTTPTests over mocks, with swift-testing-pro
- [ ] Set up CI/CD as a service
- [ ] Verify
```

## Prepare for production

```
- [ ] Each role's pool and timeouts, within Postgres's max_connections (persistence.md#connections-and-timeouts)
- [ ] Each root: grpc.health.v1, observability, secrets from files, the worker's shutdown period (composition.md)
- [ ] The plan's Operations, answered by the user (system.md#the-plan)
- [ ] Each release's checks and rollback triggers with deploy-checklist (related-skills.md)
- [ ] Verify
```

## Set up CI/CD

```
- [ ] The package's kind: public library, system library or service (delivery.md#package-kinds)
- [ ] Its CI on the plan's CI host, holding every change to the gate (delivery.md#the-gate): on GitHub, swift-microservices/ci's CI workflows as its README gives them, each pinned to a release's commit
- [ ] .swift-format (style.md#formatting), and the license header files Soundness checks
- [ ] A service: its image and its platform's deploy, meeting the deployment contract (delivery.md#the-deployment-contract)
- [ ] scripts/swift_ci.sh build and test, with --library for a library and POSTGRES_* and VALKEY_* for a service (delivery.md#tests); fix and repeat until both pass
```

## Review a backend

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
