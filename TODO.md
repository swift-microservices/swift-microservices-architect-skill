# To do

Guidance the skill doesn't give yet. Until an item lands, the skill says nothing about it. Each item names where its rule would live, following `CLAUDE.md`'s one home per rule.

## Later (P2)

- **A pool-wait alert.** The plan's Operations alerts on each role pool's wait for a connection. postgres-nio records it (`db.client.connection.wait_time`, `db.client.connection.pending_requests`) on its main branch, in no release yet; once a release has it, `packages.md`'s template raises postgres-nio's lower bound to it and the alert joins the others. Home: `system.md#the-plan`, `packages.md#packageswift-template`.

