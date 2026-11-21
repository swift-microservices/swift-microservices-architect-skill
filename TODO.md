# To do

Guidance the skill doesn't give yet. Until an item lands, the skill says nothing about it. Each item names where its rule would live, following `CLAUDE.md`'s one home per rule, and a rule that lands also gets a grader or an eval case.

## Deferred

- **JWT key rotation.** The skill assumes the signing key never changes. Every process loads its keys once, at startup, so a rotation would run in this order: add the new public key file and restart every process that verifies tokens; switch Identity's private key; once the last token the old key signed has expired, remove the old public key file and restart again. Home: `security.md#user-tokens`.

## Before production (P0)

- **Evals for the production rules.** Graders for the rules added with the pool budget and timeouts, `InternalCallerInterceptor`, health checks and observability, per `CLAUDE.md`'s eval suite, then a comparison against `main`.

## Next (P1)

- **Evals for the P1 rules.** Graders for typed error mapping, secrets from files, refresh-token reuse, attempt limits, batch reads, large-table migrations, workflow changes and data erasure.

## Later (P2)

- **Overload protection.** A cap on each service's concurrent RPCs and on the gateway's in-flight requests, so a slowdown refuses the excess quickly instead of letting every request queue until its deadline. Home: `grpc.md#transports`, `gateway.md`, `composition.md#configuration`.
- **Public API versioning.** `Deprecation` and `Sunset` headers on a retiring route, the rule for a `/v2` beside `/v1`, and an `openapi.yaml` breaking-change check as a swift-microservices/ci input. Home: `gateway.md`, `delivery.md`.
- **Operations plan.** Service-level objectives per route tier, the alerts that guard them (error rate, latency, failed workflows, schedule-to-start latency, pool waits), and runbooks for a bad deploy, a stuck or nondeterministic workflow, and certificate renewal, in the plan's Operations section. Home: `system.md#the-plan`.

