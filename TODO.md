# To do

Guidance the skill doesn't give yet. Until an item lands, the skill says nothing about it. Each item names where its rule would live, following `CLAUDE.md`'s one home per rule.

## Before production (P0)

- **An eval suite.** Cases and graders that check what agents produce with the skill against `main`, rebuilt from scratch, with the rules and the steps that run them in `CLAUDE.md`.

## Later (P2)

- **An `openapi.yaml` breaking-change check.** A pull request that breaks `/v1` in the gateway's `openapi.yaml` fails CI, against the pull request's base, as `<project>-protos`' buf check fails one that breaks the wire. swift-microservices/ci's `service.yml` has no input for it yet; once it has one, the gateway's `ci.yml` passes it. Home: `delivery.md#a-services-ci-workflows`, linked from `gateway.md#versions`.
- **A one-shot migrate command.** `<x> migrate` applies the migrations as the owner and exits, and its application alone mounts the migrator's certificate, so no container that serves RPCs holds the owner's credentials and no migration races a health check or the pipeline's 10-minute wait for a healthy container. It needs swift-microservices/ci's `deploy_dokploy.yml` to treat an application that runs to completion, exiting 0, as deployed before it moves to the next, since `deploy-dokploy.sh` waits for a running, healthy container. `serve --migrate-database` and the migrating application's start period then go. Home: `composition.md#commands`, `persistence.md#migrations`, `security.md#postgres`, `delivery.md#a-services-ci-workflows`.
- **Operations plan.** Service-level objectives per route tier, the alerts that guard them (error rate, latency, failed workflows, schedule-to-start latency, pool waits), and runbooks for a bad deploy, a stuck or nondeterministic workflow, and certificate renewal, in the plan's Operations section. Home: `system.md#the-plan`.

