# To do

Guidance the skill doesn't give yet. Until an item lands, the skill says nothing about it. Each item names where its rule would live, following `CLAUDE.md`'s one home per rule.

## Later (P2)

- **A one-shot migrate command.** `<x> migrate` applies the migrations as the owner and exits, and its application alone mounts the migrator's certificate, so no container that serves RPCs holds the owner's credentials and no migration races a health check or the pipeline's 10-minute wait for a healthy container. It needs swift-microservices/ci's `deploy_dokploy.yml` to treat an application that runs to completion, exiting 0, as deployed before it moves to the next, since `deploy-dokploy.sh` waits for a running, healthy container. `serve --migrate-database` and the migrating application's start period then go. Home: `composition.md#commands`, `persistence.md#migrations`, `security.md#postgres`, `delivery.md#a-services-ci-workflows`.
- **A pool-wait alert.** The plan's Operations alerts on each role pool's wait for a connection. postgres-nio records it (`db.client.connection.wait_time`, `db.client.connection.pending_requests`) on its main branch, in no release yet; once a release has it, `packages.md`'s template raises postgres-nio's lower bound to it and the alert joins the others. Home: `system.md#the-plan`, `packages.md#packageswift-template`.

