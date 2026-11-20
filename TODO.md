# To do

Guidance the skill doesn't give yet. Until an item lands, the skill says nothing about it. Each item names where its rule would live, following `CLAUDE.md`'s one home per rule, and a rule that lands also gets a grader or an eval case.

## Deferred

- **JWT key rotation.** The skill assumes the signing key never changes. Every process loads its keys once, at startup, so a rotation would run in this order: add the new public key file and restart every process that verifies tokens; switch Identity's private key; once the last token the old key signed has expired, remove the old public key file and restart again. Home: `security.md#user-tokens`.

## Before production (P0)

- **Deploy order.** `delivery.md` states it; it holds once [swift-microservices/ci#17](https://github.com/swift-microservices/ci/pull/17) is released and services pin that release.
- **Evals for the production rules.** Graders for the rules added with the pool budget and timeouts, `InternalCallerInterceptor`, health checks and observability, per `CLAUDE.md`'s eval suite, then a comparison against `main`.

## Next (P1)

- **Changing a workflow.** Patch it or register a new type; a `WorkflowReplayer` test over recorded histories in `XCoreTests`; what the build id does and doesn't do. Home: `workflows.md`, `testing.md`.
- **Refresh tokens.** Rotate on every use and revoke the session on reuse; state the access token's lifetime; always verify `iss`. Home: `security.md#user-tokens`.
- **Secrets from files.** `DirectoryFilesProvider` over `/run/secrets` instead of environment variables. Home: `security.md#secrets`, `composition.md#configuration`.
- **Abuse limits.** Attempt counters in Valkey for sign-in and password reset; a `…Limited` case mapped to `resourceExhausted`, then 429 with `Retry-After`. Home: `security.md`, `grpc.md#status-codes`, `persistence.md#valkey`.
- **Batch reads.** A `BatchGet…` internal RPC and a `books(ids:)` port for lists that need another service's data, never one call per item. Home: `grpc.md`, `system.md#how-services-talk`.
- **Typed error mapping in handlers and activities.** `do throws(E)` with an exhaustive `switch`, so a new error case fails the build. Home: `style.md#errors`, `grpc.md#a-handler`, `workflows.md#activities`, SKILL.md's Code style, `check_skill.py` and graders.
- **Wire-breaking checks for protos.** `buf breaking` and `buf lint` as a swift-microservices/ci input. Home: `delivery.md#a-librarys-ci-workflows`.
- **Large-table migrations.** Indexes built `CONCURRENTLY` and backfills run outside the migration transaction, as a short-lived command. Home: `persistence.md#migrations`.
- **Postgres floor and backups.** Postgres 18 as the stated minimum (for `uuidv7()`); backups, point-in-time recovery and Temporal's store as questions for the plan. Home: SKILL.md's Prerequisites and Limitations, `stack.md`, `system.md#out-of-scope`.
- **Deleting a person's data.** A workflow from Identity to each consumer's internal RPC; Temporal retention as a privacy setting. Home: `system.md`, `workflows.md`.
- **A "Prepare for production" checklist** and an Operations section in the plan. Home: SKILL.md's Instructions, `system.md#the-plan`.

## Later (P2)

- **Draining status.** The health service reports `NOT_SERVING` once graceful shutdown starts, before the server drains. Home: `composition.md#health`.
- **Temporal access per service.** Any process with a Temporal certificate can signal another service's workflows in the shared namespace; a namespace per service, or an authorizer, closes it. Home: `security.md`, `workflows.md#the-worker`.

- **Cancellation.** A cancelled request leaves without an error-level log line, or as a `cancelled` case mapped to 499. Home: `style.md#errors`.
- **Compiler checks and readability.** `.strictMemorySafety()` in the package template; lines of about 120 columns; DocC catalogs for `<project>-core`. Home: `packages.md#swift-settings`, `style.md#formatting`, `delivery.md`.
- **Recurring jobs and retention.** Temporal Schedules with a stated creator; retention for webhook event ids, refresh tokens and expired rows. Home: `workflows.md`.
- **Concurrent updates and caches.** Optimistic concurrency (`etag`, `If-Match`); invalidating a cache key after the commit that changes its source. Home: `use-cases.md#transactions`, `gateway.md`, `persistence.md#valkey`.
- **Hardening.** CORS origins from configuration; SBOM, provenance attestation and image scanning; a numeric UID and a read-only root filesystem. Home: `gateway.md`, `delivery.md`.
- **Local runs.** The same mTLS with a development CA, never a plaintext mode. Home: `system.md#out-of-scope`.
