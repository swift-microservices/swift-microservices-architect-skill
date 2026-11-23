# Related skills

This skill states the architecture: the services and who owns what, the mechanism between processes, the shapes, the stack and the style. The technique inside them belongs to maintained skills, each loaded when its task comes up; a checklist names each one again at its step.

## Which skill a task loads

Design and operations, whatever the stack:

- A backend's or a feature's requirements, failure modes, scale and trade-offs, before its shapes: `system-design` ([source](https://github.com/anthropics/knowledge-work-plugins))
- A choice this skill leaves open, weighed as an architecture decision record: `architecture` ([source](https://github.com/anthropics/knowledge-work-plugins))
- A review's security, performance and correctness pass: `code-review` ([source](https://github.com/anthropics/knowledge-work-plugins))
- A release's checks and rollback triggers: `deploy-checklist` ([source](https://github.com/anthropics/knowledge-work-plugins))
- A production incident's triage, status updates and postmortem: `incident-response` ([source](https://github.com/anthropics/knowledge-work-plugins))

These five also come as the Engineering plugin, whose skills carry the `engineering:` prefix, such as `engineering:system-design`.

The code inside a shape:

- A workflow's design: history, signals, updates, waiting, compensation, versioning: `temporal-developer` ([source](https://github.com/temporalio/skill-temporal-developer))
- A table's policy, grants, indexes, column types, and what a migration locks: `supabase-postgres-best-practices` ([source](https://github.com/supabase/agent-skills))
- A Valkey command for an operation, its expiry and atomicity: `valkey` ([source](https://github.com/valkey-io/valkey-skills))
- Test code, with Swift Testing: `swift-testing-pro` ([source](https://github.com/twostraws/Swift-Testing-Agent-Skill))
- Actors, task groups, cancellation, `Sendable` and strict-concurrency diagnostics: `swift-concurrency-pro` ([source](https://github.com/twostraws/Swift-Concurrency-Agent-Skill))
- Argument labels, method names, documentation comments: `swift-api-design-guidelines-skill` ([source](https://github.com/Erikote04/Swift-API-Design-Guidelines-Agent-Skill))

## Where this skill wins

- A related skill decides what a design, a piece of code, a review or a release needs. This skill decides the service that owns it, the mechanism that carries it, the shape that holds it, and how the code reads.
- Where a related skill proposes another stack, shape, mechanism or name, such as REST or a message queue between services, a cache in front of the owner's data, or a helper method in a use case, this skill's choice holds and the need it raised is met inside it.
- Their overlap with this skill is never restated here, and their examples are never copied in.

## Turning a design into shapes

- `system-design`'s answers are the checklist's opening lines, and each lands in a shape this skill names: a step between processes is a call, a workflow or an event ([choosing a mechanism](events.md#choosing-a-mechanism)); a failure is an error case, a workflow's retry or the outbox; volume is a page, an index, a pool or a topic's partitions.
- A requirement that needs something [out of scope](system.md#out-of-scope) is a question for the user.
- An architecture decision record covers only a choice this skill leaves open, such as a capability's boundary, a provider or a policy's limits; a choice this skill makes has none. Its pick and reason join the plan's Decisions ([the plan](system.md#the-plan)).
- `code-review`'s findings are ranked with this skill's own, on Review a backend's scale.
- `deploy-checklist`'s rollback is the plan's runbook for a bad deploy ([the plan](system.md#the-plan)).
