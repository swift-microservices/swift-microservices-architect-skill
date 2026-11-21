# To do

Guidance the skill doesn't give yet. Until an item lands, the skill says nothing about it. Each item names where its rule would live, following `CLAUDE.md`'s one home per rule.

## Before production (P0)

- **An eval suite.** Cases and graders that check what agents produce with the skill against `main`, rebuilt from scratch, with the rules and the steps that run them in `CLAUDE.md`.

## Later (P2)

- **Overload protection.** A cap on each service's concurrent RPCs and on the gateway's in-flight requests, so a slowdown refuses the excess quickly instead of letting every request queue until its deadline. Home: `grpc.md#transports`, `gateway.md`, `composition.md#configuration`.
- **Public API versioning.** `Deprecation` and `Sunset` headers on a retiring route, the rule for a `/v2` beside `/v1`, and an `openapi.yaml` breaking-change check as a swift-microservices/ci input. Home: `gateway.md`, `delivery.md`.
- **A one-shot migrate command.** `<x> migrate` applies the migrations as the owner and exits, and its application alone mounts the migrator's certificate, so no container that serves RPCs holds the owner's credentials and no migration races a health check or the pipeline's 10-minute wait for a healthy container. It needs swift-microservices/ci's `deploy_dokploy.yml` to treat an application that runs to completion, exiting 0, as deployed before it moves to the next, since `deploy-dokploy.sh` waits for a running, healthy container. `serve --migrate-database` and the migrating application's start period then go. Home: `composition.md#commands`, `persistence.md#migrations`, `security.md#postgres`, `delivery.md#a-services-ci-workflows`.
- **Operations plan.** Service-level objectives per route tier, the alerts that guard them (error rate, latency, failed workflows, schedule-to-start latency, pool waits), and runbooks for a bad deploy, a stuck or nondeterministic workflow, and certificate renewal, in the plan's Operations section. Home: `system.md#the-plan`.

