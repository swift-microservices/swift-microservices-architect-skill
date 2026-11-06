# swift-backend-architect

This repository is the `swift-backend-architect` agent skill. Agents read `skills/swift-backend-architect/SKILL.md` and its `references/`; people read `README.md`. It ships as a Claude Code plugin (`.claude-plugin/`) and through the skills CLI.

## What the skill is for

- It decides how a Swift backend splits into services and modules, where code lives and who owns it, and the shapes that hold a service together: Core's models, errors, repositories, ports and use cases; the Postgres, gRPC, Temporal, Valkey, provider and HTTP adapters; the gateway; the composition roots; the shared `<org>-core` and `<org>-protos` packages; and how the code reads and is named.
- It states shapes and rules. The code inside a shape that isn't architecture (actor design, task group technique, test code) belongs to the skills under Related skills in `SKILL.md`.
- Out of scope until decided: CI/CD, deployment, container images and compose files, networks and VPNs, the edge proxy, certificate issuance and renewal, observability backends, client SDKs and frontends, and tests.

## What a change must respect

- Add only what an agent would get wrong without it: a placement, an ownership rule, a shape, a style rule, a gotcha. Cut explanations of what Claude already knows about Swift, SPM or the libraries.
- State the rule, then a short reason when the reason guides judgment in cases the rule doesn't cover.
- Each rule lives in one reference. `SKILL.md` carries at most one line for it (a hard rule, a principle, a brief, a style point, a gotcha or a workflow step); other references link to it instead of restating it; `conventions.md` holds only names.
- Examples come from Bookshelf, the lending library in `SKILL.md`'s table, and each idea is shown where it fits best:
  - a service with every target, a tenant table, a workflow and calls to other services: Loans
  - a service with no tenant table and an internal contract another service calls: Catalog
  - the one token issuer, Valkey, and a provider target for hashing: Identity
  - a use case's five files and body: `BorrowBook`; an administrators' use case: `ListAllLoans`
  - a workflow, its activities and options: `LoanWorkflow`, `LoanActivities`
  - the gateway: `BookshelfAPI`, `LoanController`, the request contexts

  Reuse these, and add an example only when none of them can show a new idea. Never bring in names, services, endpoints or details from the systems the skill is used on; write the rule they illustrate instead.
- Code shows a shape the skill prescribes: a use case's files and its body, a handler, a scope, a workflow's `run`, a composition root's sections, a reader. It isn't an implementation to copy: no helper functions, no test code, no internals of a library, and a method body appears only where the body is the shape. Elide the rest with `…`.
- The stack is fixed: Hummingbird for HTTP, grpc-swift-2 and its siblings for RPC, swift-temporal-sdk, valkey-swift, PostgresNIO with the swift-microservices libraries, swift-configuration, swift-service-lifecycle, swift-argument-parser. No other HTTP framework is named, and no invented infrastructure (DI containers, buses, generic repositories) is added.
- The code style is fixed: one `do` holding the whole path, one `catch` per case, typed throws on use cases, build then call (a value a call takes is a named `let`), no helper methods in use cases or workflows, Swift 6 mode with the four upcoming features, `package` access, the conditional `FoundationEssentials` import. A change never weakens it.
- Describe the current design only, with no dates, old names, renames, migrations of the skill or history. A library's version appears only in `Package.swift` lower bounds and `stack.md`.
- One term per concept, as `conventions.md` names it: service, capability, area, use case, repository, command, port, scope, database role, tenant table, contract, `XService`, `XInternalService`, adapter target, composition root, the gateway, tier, workflow, activity, worker.
- A new rule mustn't contradict an existing one. When it replaces one, change every place the old rule appears.
- Voice: plain declarative sentences in the present tense, lists over paragraphs, no "you", no all-caps emphasis, no hedging.

## How Claude loads the skill

A skill loads in three stages, each with its own limit:

1. **The listing.** Every session lists each installed skill's `name` and `description` on every turn, and Claude decides from them alone whether to invoke the skill. An entry is cut at 1,536 characters.
2. **Invocation.** The `SKILL.md` body enters the conversation as one message and stays; the specification recommends under 5,000 tokens. After compaction Claude Code re-attaches the first 5,000 tokens of each invoked skill, within 25,000 tokens shared by every skill invoked, the most recent first.
3. **References.** A file in `references/` loads only when `SKILL.md` sends Claude to it. A file reached only through another reference may be read in part, such as its first 100 lines.

The guidance changes, so recheck these before changing the skill's structure or frontmatter: [skills in Claude Code](https://code.claude.com/docs/en/skills), [skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices), [Agent Skills overview](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview) and the [Agent Skills specification](https://agentskills.io/specification).

## How the skill is structured

- The skill folder holds only what agents read: `SKILL.md` and `references/`. Everything for people, such as `README.md`, this file and the license, stays outside it.
- `SKILL.md` is the entry point. It stays under 500 lines and under 5,000 tokens, with the most important content first, since compaction keeps the start. Its sections are: the example system, the shape, a service's package with its hard rules, who owns what, principles, the shapes in brief, code style, gotchas, workflows, references and related skills.
- `SKILL.md` holds only what every task needs. Its gotchas are mistakes any task can make; a mistake only one shape invites is stated once, in that shape's reference.
- A workflow is a checklist the agent copies into its response, ending in a build it repeats until it passes.
- Detail lives in `references/`, one topic per file. Every reference is listed in the References table in `SKILL.md`, saying when to read it, and none is reachable only through another reference.
- A reference over 100 lines starts with a `## Contents` list of its `##` sections.
- Links between files use GitHub heading anchors; renaming a heading means updating every link to it.
- Frontmatter holds only `name` and `description`, in YAML that parses. claude.ai and the API accept only the open Agent Skills keys and reject any other, such as Claude Code's `when_to_use` or `paths`.
- `name` matches the folder: at most 64 characters of lowercase letters, digits and single hyphens, without `anthropic` or `claude`.
- `description` is at most 1,024 characters, in the third person, with no angle brackets or XML tags. It says what the skill does, then when to use it, in the words users type, and ends by claiming the tasks where the user doesn't name the architecture.

## Making a change

1. Decide whether it belongs: architecture, ownership, a shape or the style goes in; technique goes to the related skills; one system's detail stays out.
2. Find every place the rule or name appears: `grep -rn "<term>" README.md .claude-plugin skills`.
3. When the change alters what an agent produces, copy `skills/swift-backend-architect` to a scratch folder first, as the baseline to compare against.
4. Edit the reference first, then the line in `SKILL.md`, then `conventions.md`, then `README.md` when what the skill covers changes.
5. Keep the descriptions in `SKILL.md`, `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` in step.
6. Verify, and fix until each passes:
   - `wc -l -c skills/swift-backend-architect/SKILL.md` stays within the limits above, at about 3.5 characters a token, so the References table stays inside the first 5,000 tokens
   - the frontmatter parses and keeps to its limits: `LANG=en_US.UTF-8 ruby -ryaml -e 'h = YAML.safe_load(File.read(ARGV[0], encoding: "UTF-8")[/\A---\n(.*?)\n---\n/m, 1]); d = h["description"]; puts h.keys.inspect, d.length, d.match?(/[<>]/)' skills/swift-backend-architect/SKILL.md` prints only `name` and `description`, at most 1,024, and `false`
   - `grep` finds no stale name or rule, and no name from a system the skill is used on
   - every link and anchor resolves
   - `claude plugin validate .` passes
7. When the change alters what an agent produces, give two fresh agents the same two or three realistic tasks (plan a backend, add a service, add an operation, add a workflow, review a service), one reading the baseline and one the edited skill. Read both answers, and fix whatever the edited skill still leaves them to guess.

A new reference file gets a lowercase topic name, a Contents list once it passes 100 lines, a row in the References table in `SKILL.md`, and a line in the layout in `README.md`.

## Releases and commits

- The version appears three times, in `plugin.json` and twice in `marketplace.json` (the marketplace and its plugin entry); keep them equal and change them only when releasing.
- Commit or push only when asked. A subject line names the guidance in the imperative, such as "Run tenant use cases on the service role", not the files touched.
