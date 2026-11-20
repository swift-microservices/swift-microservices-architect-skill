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

- **Temporal access per service.** Any process with a Temporal certificate can signal another service's workflows in the shared namespace; a namespace per service, or an authorizer, closes it. Home: `security.md`, `workflows.md#the-worker`.

- **Strict memory safety.** `.strictMemorySafety()` flags `nonisolated(unsafe)` and unsafe pointers, not `@unchecked Sendable`, and CI turns its warnings into errors. Build the package template with it, the Temporal macros and generated contracts included, before adding it to `swiftSettings`. Home: `packages.md#swift-settings`.
- **Supply chain.** SBOM, provenance attestation and image scanning in `build_image.yml`. Needs a change in swift-microservices/ci first. Home: `delivery.md`.
