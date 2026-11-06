# swift-microservices-architect

This repository is the `swift-microservices-architect` agent skill. Agents read `skills/swift-microservices-architect/SKILL.md` and its `references/`; people read `README.md`. It ships as a Claude Code plugin (`.claude-plugin/`) and through the skills CLI.

Every change to the skill ends with [the checks](#after-every-change), repeated until they pass.

## What the skill is for

- It decides how a Swift backend splits into services and modules, where code lives and who owns it, and the shapes that hold a service together: Core's models, errors, repositories, ports and use cases; the Postgres, gRPC, Temporal, Valkey, provider and HTTP adapters; the gateway; the composition roots; the shared `<org>-core` and `<org>-protos` packages; and how the code reads and is named.
- It states shapes and rules. The code inside a shape that isn't architecture (actor design, task group technique, test code) belongs to the skills under Related skills in `SKILL.md`.
- Out of scope until decided: CI/CD, deployment, container images and compose files, networks and VPNs, the edge proxy, certificate issuance and renewal, observability backends, client SDKs and frontends, and tests.

## Skill best practices

These come from Anthropic's [skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices), [skills in Claude Code](https://code.claude.com/docs/en/skills), the [Agent Skills overview](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview) and the [Agent Skills specification](https://agentskills.io/specification), as this skill applies them. The guidance changes, so recheck the sources before changing the skill's structure or frontmatter.

**How Claude loads a skill**, in three stages, each with its own limit:

1. **The listing.** Every session lists each installed skill's `name` and `description` on every turn, and Claude decides from them alone whether to invoke the skill. Claude Code cuts an entry at 1,536 characters.
2. **Invocation.** The `SKILL.md` body enters the conversation as one message and stays: under 500 lines and about 5,000 tokens. After compaction Claude Code re-attaches the first 5,000 tokens of each invoked skill, within 25,000 tokens shared by every skill invoked, the most recent first.
3. **References.** A file in `references/` loads only when `SKILL.md` sends Claude to it. A file reached only through another reference may be read in part, such as its first 100 lines.

**Frontmatter**

- Only `name` and `description`, in YAML that parses. claude.ai and the API accept only the specification's keys and reject any other, such as Claude Code's `when_to_use` or `paths`.
- `name` is the folder's name: at most 64 characters of lowercase letters, digits and single hyphens, neither first nor last, without `anthropic` or `claude`.
- `description` is at most 1,024 characters, in the third person, with no angle brackets or XML tags. It says what the skill does, its key use first, then when to use it in the words users type, and ends by claiming the tasks where the user doesn't name the architecture.

**Structure**

- The skill folder holds only what agents read: `SKILL.md` and `references/`. Everything for people, such as `README.md`, this file, `scripts/` and the license, stays outside it.
- `SKILL.md` holds what every task needs, the most important first, since compaction keeps the start. Its sections are: the example system, the shape, a service's package with its hard rules, who owns what, the shapes in brief, code style, gotchas, workflows, references and related skills.
- Detail lives in `references/`, one topic per file. Every reference is in `SKILL.md`'s References table, saying when to read it, so none is reachable only through another: references stay one level deep.
- A reference over 100 lines starts with a `## Contents` list of its `##` sections.
- Links are relative, with forward slashes and GitHub heading anchors; renaming a heading means updating every link to it.

**Content**

- Only what Claude doesn't already know: a placement, an ownership rule, a shape, a style rule, a gotcha, or a reason that guides judgment. Cut explanations of Swift, SPM, Postgres or a library's basics.
- One home per rule. A rule lives in one reference; `SKILL.md` carries at most one line for it (a hard rule, an ownership row, a brief, a style point, a gotcha or a workflow step); other references link to it instead of restating it. `conventions.md` holds only names. A rule stated twice drifts apart and costs tokens twice.
- `SKILL.md`'s gotchas are mistakes any task can make; a mistake only one shape invites is stated once, in that shape's reference.
- One term per concept, no time-sensitive statements, concrete examples, and one default rather than a menu of options.
- A workflow is a checklist the agent copies into its response, ending in a build it repeats until it passes.

## What a change must respect

- State the rule, then a short reason when the reason guides judgment in cases the rule doesn't cover.
- Examples come from Bookshelf, the lending library in `SKILL.md`'s table, and each idea is shown where it fits best:
  - a service with every target, a tenant table, a workflow and calls to other services: Loans
  - a service with no tenant table and an internal contract another service calls: Catalog
  - the one token issuer, Valkey, and a provider target for hashing: Identity
  - a use case's five files and body: `BorrowBook`; an administrators' use case: `ListAllLoans`
  - a workflow, its activities and options: `LoanWorkflow`, `LoanActivities`
  - the gateway: `BookshelfAPI`, `LoanController`, the request contexts, `ErrorMiddleware`

  Reuse these, and add an example only when none of them can show a new idea. Never bring in names, services, endpoints or details from the systems the skill is used on; write the rule they illustrate instead.
- Code shows a shape the skill prescribes: a use case's files and its body, a handler, a scope, a workflow's `run`, a composition root's sections, a reader. It isn't an implementation to copy: no helper functions, no test code, no internals of a library, and a method body appears only where the body is the shape. Elide the rest with `…`.
- The stack is fixed: Hummingbird for HTTP, grpc-swift-2 and its siblings for RPC, swift-temporal-sdk, valkey-swift, PostgresNIO with the swift-microservices libraries, swift-configuration, swift-service-lifecycle, swift-argument-parser. No other HTTP framework is named, and no invented infrastructure (DI containers, buses, generic repositories) is added.
- The code style is fixed, and every example follows it: one `do` holding the whole path, one `catch` per case, typed throws on use cases, build then call (a value a call takes is a named `let`), no helper methods in use cases, workflows or activities, Swift 6 mode with the four upcoming features, `package` access, the conditional `FoundationEssentials` import. A change never weakens it.
- Describe the current design only, with no dates, old names, renames, migrations of the skill or history. A library's version appears only in `Package.swift` lower bounds and `stack.md`.
- One term per concept, as `conventions.md` names it: service, capability, area, use case, repository, command, port, scope, database role, tenant table, contract, `XService`, `XInternalService`, adapter target, composition root, the gateway, tier, workflow, activity, worker.
- A new rule mustn't contradict an existing one. When it replaces one, change every place the old rule appears.
- Voice: plain declarative sentences in the present tense, lists over paragraphs, no "you", no all-caps emphasis, no hedging.

## Making a change

1. Decide whether it belongs: architecture, ownership, a shape or the style goes in; technique goes to the related skills; one system's detail stays out.
2. Find every place the rule or name appears: `grep -rn "<term>" README.md .claude-plugin skills`.
3. Edit the rule's home first, then its line in `SKILL.md`, then `conventions.md`, then `README.md` when what the skill covers changes. Keep the descriptions in `SKILL.md`, `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` identical.
4. Run [the checks](#after-every-change).

A new reference file gets a lowercase topic name, a Contents list once it passes 100 lines, a row in the References table in `SKILL.md`, and a line in the layout in `README.md`.

## After every change

1. `python3 scripts/check_skill.py` passes. It checks:
   - the frontmatter's keys, `name` and `description`, against the limits above
   - `SKILL.md`'s lines and estimated tokens, at 3.5 characters a token, and that its References table ends inside the first 5,000
   - that every reference is in `SKILL.md`'s References table and `README.md`'s layout, with a Contents list past 100 lines
   - every link and anchor
   - that the three descriptions and the three versions in `SKILL.md` and the manifests agree
   - that no Swift example builds a value inside an argument or declares a variable before a `do` for its catches to fill
   - `claude plugin validate .`, whose warnings about the missing icon and about `CLAUDE.md` are expected
2. Review the diff for what no script checks:

   ```
   - [ ] Each rule has one home: SKILL.md carries at most one line for it, and other files link to it
   - [ ] Nothing explains what Claude already knows
   - [ ] Examples are Bookshelf's and follow the code style
   - [ ] Terms are conventions.md's, with no dates, history or old names
   - [ ] README.md still describes what the skill covers
   ```

3. When the change alters what an agent produces, compare it against the last commit. Check that commit out as the baseline (`git worktree add ../skill-baseline HEAD`), give two fresh agents the same two or three realistic tasks (plan a backend, add a service, add an operation, add a workflow, review a service), one with each skill, on the models the skill runs on. Fix whatever the edited skill still leaves them to guess, then remove the worktree.

## Pull requests and releases

- Every change reaches `main` through a pull request from its own branch, carrying exactly one semver label; the PR label workflow refuses one without. The label says what the change does to agents following the skill:

  | Label | When |
  |---|---|
  | `⚠️ semver/major` | A rule or shape changes so that code following the skill no longer conforms, such as a renamed target or a reversed rule |
  | `🆕 semver/minor` | New guidance that contradicts none: a shape, a rule, a gotcha, a reference |
  | `🔨 semver/patch` | A correction, clearer wording or a better example, with no rule changed |
  | `semver/none` | Nothing the skill says changes: the README, this file, CI, scripts |

- The Validate workflow runs `scripts/check_skill.py` on every pull request and push to `main`, with Claude Code installed so `claude plugin validate` runs too.
- Dependabot checks the workflows' pinned actions weekly and opens a pull request labeled `semver/none` for each update. The Claude Code version Validate installs is a shell command Dependabot doesn't read, so it's raised by hand.
- A release is the Release workflow, run by hand on `main`. It takes the next version from the labels merged since the last release, writes it to the three version fields (`plugin.json`, and the marketplace and its plugin entry in `marketplace.json`), commits, tags and publishes the notes. A major release is cut by hand. Nothing else changes a version.
- Commit, push or open a pull request only when asked. A subject line names the guidance in the imperative, such as "Run tenant use cases on the service role", not the files touched.
