# Delivery

How each package is tested, released and deployed: the package kinds, the gate every change passes, and the deployment contract every platform meets. On GitHub, a repository's CI workflows call `swift-microservices/ci`, whose [README](https://github.com/swift-microservices/ci#readme) gives its CI workflows, their inputs and secrets, and what each requires of a repository; read it before setting one up. A repository on another CI host runs `scripts/swift_ci.sh` and the same checks.

Where a service runs is the plan's platform ([the plan](system.md#the-plan)). Every platform meets [the deployment contract](#the-deployment-contract), and a platform's own reference gives its deploy jobs, secrets and settings:

| Platform | Reference |
|---|---|
| Dokploy | [delivery-dokploy.md](delivery-dokploy.md) |

A platform without a reference here deploys by the contract alone, and the response tells the user that the skill has no reference for it.

## Contents
- Package kinds
- The gate
- Tests
- Foundation linking
- The deployment contract

## Package kinds

| Kind | Packages | Ships as |
|---|---|---|
| Public library | The swift-microservices libraries, any open-source package | Semantic versions, for anyone |
| System library | `<project>-core`, `<project>-protos` | Semantic versions, for the project's services and gateway |
| Service | Each service, and the gateway | An image per commit on `main`, deployed to staging, then promoted to production by hand; no versions, and no long-lived branch but `main` |

## The gate

Every CI host holds each change to the same gate: these flags on `swift build` and `swift test`, which `scripts/swift_ci.sh` applies, then Soundness, Foundation linking and, for a service, the image's checks.

| Flag | Packages | Holds every change to |
|---|---|---|
| `-Xswiftc -warnings-as-errors` | Every kind, except on nightly toolchains | No warnings |
| `--explicit-target-dependency-import-check error` | Every kind | Importing no module outside the target's dependency closure |
| `-Xswiftc -require-explicit-sendable` | Libraries | Every `public` type stating whether it's `Sendable` |

The tests run on Ubuntu noble, on these toolchains and architectures:

| | Library | Service |
|---|---|---|
| Swift | Each supported release from the package's `swift-tools-version` up, `nightly-release` and `nightly-main` | The package's `swift-tools-version` |
| Architectures | `x86_64` and `aarch64`; a system library the plan's | The plan's |
| Also builds with | The Static Linux SDK | Nothing else |

- A library builds wherever its users do, on toolchains and machines it doesn't choose, so its tests cover them, such as aarch64's weaker memory ordering, which surfaces a race x86_64 hides. A service ships one binary to servers it knows, so it tests exactly what it ships. Soundness and Foundation linking run on the package's `swift-tools-version` for both.
- A service's `Containerfile` builds on its `swift-tools-version` too, so moving a service to a newer Swift changes its tools version and its `Containerfile`'s `FROM` in one pull request.
- The plan's architectures are the ones the platform's servers run. A service passes them as `linux_host_archs` (`'["aarch64"]'`, `'["x86_64"]'` or both), which `service.yml` requires, and its image builds for the same ones; with several, the commit's image is an index from which each server pulls its own. A system library passes the same `linux_host_archs`, since only the project's services build it; a public library passes none.
- A library's pull request carries exactly one semver label, and its release tags the next version without a `v`; a tag never moves, and a bad release is fixed forward.
- `<project>-protos` also runs buf, which fails a pull request that breaks the wire, such as a renumbered field or a reused tag. The gateway's CI fails a pull request whose `openapi.yaml` breaks a client of its base's ([versions](gateway.md#versions)); removing a route the base marks `deprecated: true` passes, as its sunset's pull request does.

## Tests

- `XPostgresTests` need a real Postgres: the CI workflows pass `postgres_image: postgres:<major>-alpine`, the major the services run, 18 or later, and the tests reach it through `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_DB`, which are unset without it. `XValkeyTests` need a real Valkey: a service with XValkey passes `valkey_image: valkey/valkey:<major>-alpine` too, the major its Valkey runs, 9 or later, and the tests reach it through `VALKEY_HOST` and `VALKEY_PORT`, unset without it.

## Foundation linking

Both CI pipelines build every product, library and executable, and fail when one links full Foundation or ICU ([traits and Foundation](packages.md#traits-and-foundation)).

- `foundation_linking_check_excluded_products` names a product that links full Foundation only through a dependency: `BookshelfPersistence` over PostgresNIO, or a service's executable while a package it depends on does ([full Foundation](stack.md#full-foundation)). The check skips it and says so.
- A product leaves the list in the pull request that raises the dependency to a release that stops linking full Foundation.

## The deployment contract

What every platform's deploy does, whatever runs it:

- CI publishes each commit's image once, by its commit, and every environment deploys it by its digest.
- Each command runs as its own process ([commands](composition.md#commands)): `loans migrate` at one replica, alone holding the owner's login ([Postgres](security.md#postgres)), then `loans serve` and `loans worker run`.
- `migrate` runs to completion: serve and the worker deploy only once migrate's container of the new image exits 0, and a failed migration stops the deploy with serve and the worker on the previous image ([migrations](persistence.md#migrations)). Nothing restarts a migrate that exited.
- Each other process waits for the one before it to run, and to pass its health check where it has one ([health](composition.md#health)).
- Staging deploys each push to `main`; production deploys by hand, promoting the image staging ran for a commit, so it runs only what staging ran.
- Deployments to one environment run one at a time and are never cancelled midway; who may approve production is the user's answer.
- The stop timeout exceeds the worker's shutdown period ([the worker's root](composition.md#the-workers-root)).
- A client's host resolves to every replica of its upstream ([transports](grpc.md#transports)); the platform's reference names it.
- Certificates, keys and secrets are files mounted read-only at configured paths ([mutual TLS](security.md#mutual-tls), [secrets](security.md#secrets)).
- The image runs its product directly as an unprivileged numeric user and writes only to standard output and standard error, so the platform may mount its root filesystem read-only.
