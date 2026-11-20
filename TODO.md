# To do

Guidance the skill doesn't give yet. Until an item lands, the skill says nothing about it. Each item names where its rule would live, following `CLAUDE.md`'s one home per rule, and a rule that lands also gets a grader or an eval case.

## Deferred

- **JWT key rotation.** The skill assumes the signing key never changes. Every process loads its keys once, at startup, so a rotation would run in this order: add the new public key file and restart every process that verifies tokens; switch Identity's private key; once the last token the old key signed has expired, remove the old public key file and restart again. Home: `security.md#user-tokens`.

## Before production (P0)

- **Deploy order.** `delivery.md` states it; it holds once [swift-microservices/ci#17](https://github.com/swift-microservices/ci/pull/17) is released and services pin that release.
- **Evals for the production rules.** Graders for the rules added with the pool budget and timeouts, `InternalCallerInterceptor`, health checks and observability, per `CLAUDE.md`'s eval suite, then a comparison against `main`.

## Next (P1)

- **Wire-breaking checks for protos.** `delivery.md` states them; they hold once [swift-microservices/ci#18](https://github.com/swift-microservices/ci/pull/18) is released and `<project>-protos` pins that release.
- **Evals for the P1 rules.** Graders for typed error mapping, secrets from files, refresh-token reuse, attempt limits, batch reads, large-table migrations, workflow changes and data erasure.

## Later (P2)

- **Draining status.** The health service reports `NOT_SERVING` once graceful shutdown starts, before the server drains. Home: `composition.md#health`.
- **Temporal access per service.** Any process with a Temporal certificate can signal another service's workflows in the shared namespace; a namespace per service, or an authorizer, closes it. Home: `security.md`, `workflows.md#the-worker`.

- **Cancellation.** A cancelled request leaves without an error-level log line, or as a `cancelled` case mapped to 499. Home: `style.md#errors`.
- **Strict memory safety.** `.strictMemorySafety()` flags `nonisolated(unsafe)` and unsafe pointers, not `@unchecked Sendable`, and CI turns its warnings into errors. Build the package template with it, the Temporal macros and generated contracts included, before adding it to `swiftSettings`. Home: `packages.md#swift-settings`.
- **Recurring jobs and retention.** Temporal Schedules with a stated creator; retention for webhook event ids, refresh tokens and expired rows. Home: `workflows.md`.
- **Concurrent updates and caches.** Optimistic concurrency (`etag`, `If-Match`); invalidating a cache key after the commit that changes its source. Home: `use-cases.md#transactions`, `gateway.md`, `persistence.md#valkey`.
- **Hardening.** CORS origins from configuration; SBOM, provenance attestation and image scanning; a numeric UID and a read-only root filesystem. Home: `gateway.md`, `delivery.md`.
- **Local runs.** The same mTLS with a development CA, never a plaintext mode. Home: `system.md#out-of-scope`.
