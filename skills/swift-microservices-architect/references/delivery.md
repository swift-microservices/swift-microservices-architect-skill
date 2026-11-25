# Delivery

How each package is tested, released and deployed. On GitHub, a repository's CI workflows call only `swift-microservices/ci`, whose CI pipelines, `library.yml` and `service.yml`, build on swiftlang's and Apple's CI workflows. A repository declares its inputs and secrets and nothing else, so a change every repository needs, such as a flag or a check, lands once in `swift-microservices/ci`. [Its README](https://github.com/swift-microservices/ci#readme) gives each of its CI workflows' jobs and inputs, and what each requires of a repository.

A repository on another CI host holds every change to the same gate: its pipeline runs `scripts/swift_ci.sh` and each check this reference names, as `swift-microservices/ci`'s README describes it.

Where a service runs is the plan's platform ([the plan](system.md#the-plan)). Every platform meets [the deployment contract](#the-deployment-contract), and a platform's own reference gives its deploy jobs, secrets and settings:

| Platform | Reference |
|---|---|
| Dokploy | [delivery-dokploy.md](delivery-dokploy.md) |

A platform without a reference here deploys by the contract alone, and the response tells the user that the skill has no reference for it.

## Contents
- Package kinds
- CI workflows
- Tests
- Foundation linking
- A library's CI workflows
- A service's CI workflows
- The deployment contract
- The Containerfile
- Dependabot

## Package kinds

| Kind | Packages | Ships as |
|---|---|---|
| Public library | The swift-microservices libraries, any open-source package | Semantic versions, for anyone |
| System library | `<project>-core`, `<project>-protos` | Semantic versions, for the project's services and gateway |
| Service | Each service, and the gateway | An image per commit on `main`, deployed to staging, then promoted to production by hand; no versions or labels, and no long-lived branch but `main` |

## CI workflows

Each repository's `.github/workflows/` holds these, each file's `name:` in parentheses:

| File (`name:`) | Kind | Runs on | Calls in `swift-microservices/ci` | Job `permissions` |
|---|---|---|---|---|
| `pull_request.yml` (PR) | Every kind | Pull requests | `library.yml` or `service.yml` | None of its own |
| `main.yml` (Main) | Library | Pushes to `main`, a weekly `schedule` | `library.yml` | None of its own |
| `main.yml` (Main) | Service | Pushes to `main` | `service.yml`, then the platform's staging deploy and `attest_image.yml` | service: `contents: read`, `packages: write`; staging: `contents: read`, `deployments: write`; attest: `contents: read`, `packages: write`, `id-token: write`, `attestations: write` |
| `pull_request_label.yml` (PR label) | Library | Pull requests and label changes | `pull_request_label.yml` | `contents: read`, `pull-requests: read` |
| `release.yml` (Release) | Library | By hand, on `main` | `release.yml` | `contents: write`, `pull-requests: read` |
| `deploy.yml` (Deploy) | Service | By hand, on `main` | The platform's deploy, promoting from staging | `contents: read`, `deployments: write` |
| `cleanup_images.yml` (Clean up images) | Service | Weekly and by hand | `cleanup_images.yml` | `packages: write` |

- Each `uses:` is pinned to the full commit of `swift-microservices/ci`'s latest release, with the release in a comment: `@<commit>  # <release>`, looked up with `git ls-remote --tags <url>`. Dependabot moves the pin.
- `pull_request.yml` and `main.yml` pass the CI pipeline the same inputs and secrets. `pull_request.yml` grants only `contents: read`, so nothing a pull request runs can publish or deploy.
- `main` changes only through pull requests: a ruleset requires the CI pipeline's `Passed` check, `Library / Passed` or `Service / Passed`, which fails when any of the pipeline's jobs failed, and a library's `PR label / Semver label / Semantic version label check`.
- `gh pr merge --auto` waits only for the checks the base branch requires, and merges at once on a base that requires none. It's used only once `gh api repos/<owner>/<repo>/rules/branches/main` lists a `required_status_checks` rule; otherwise `gh pr checks --watch` waits for the pull request's CI to pass, and the merge follows.
- `pull_request.yml` cancels a superseded run of the same pull request. A service's `main.yml` runs one push at a time, in order, and cancels none, since each run ships its commit to staging.
- Soundness checks every file's license header against `.license_header_template`, which holds the compact SPDX header with `@@` for the comment marker and `YEARS` for the year. `.licenseignore` lists `LICENSE` and `Package.swift`, whose tools-version line must come first.
- A library's pull request carries exactly one label: `⚠️ semver/major`, `🆕 semver/minor`, `🔨 semver/patch` or `semver/none`. Below 1.0, a breaking change is minor and an addition patch; a doc-comment fix is patch; a change to the README, tests or CI is none.
- Release tags the next version without a `v` and writes its notes grouped by `.github/release.yml`; the first release and every major one are tagged by hand. A tag never moves: a bad release is fixed forward with a new version.
- Secrets: `PACKAGES_TOKEN`, which only a package with private dependencies passes: a fine-grained token owned by `<owner>`, with read-only Contents on the private package repositories, stored as an Actions secret and as a Dependabot secret. A service adds the platform's deploy secrets, which its reference names.

## Tests

The CI pipelines run the tests, and they're the gate:

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
- `XPostgresTests` need a real Postgres: the CI workflows pass `postgres_image: postgres:<major>-alpine`, the major the services run, 18 or later, and the tests reach it through `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_DB`, which are unset without it. `XValkeyTests` need a real Valkey: a service with XValkey passes `valkey_image: valkey/valkey:<major>-alpine` too, the major its Valkey runs, 9 or later, and the tests reach it through `VALKEY_HOST` and `VALKEY_PORT`, unset without it.

## Foundation linking

Both CI pipelines build every product, library and executable, and fail when one links full Foundation or ICU ([traits and Foundation](packages.md#traits-and-foundation)).

- `foundation_linking_check_excluded_products` names a product that links full Foundation only through a dependency: `BookshelfPersistence` over PostgresNIO, or a service's executable while a package it depends on does ([full Foundation](stack.md#full-foundation)). The check skips it and says so.
- A product leaves the list in the pull request that raises the dependency to a release that stops linking full Foundation.

## A library's CI workflows

`bookshelf-core`'s `pull_request.yml`:

```yaml
name: PR

on:
  pull_request:
    types: [opened, reopened, synchronize]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  library:
    name: Library
    uses: swift-microservices/ci/.github/workflows/library.yml@<commit>  # <release>
    with:
      linux_host_archs: '["aarch64"]'
      foundation_linking_check_excluded_products: '["BookshelfPersistence"]'
```

- Its `main.yml` is named `Main`, runs on pushes to `main` and on a weekly `schedule` (`cron: "0 6 * * 1"`), and has the same `permissions` and `library` job, without `concurrency`.
- The API breakage check runs by default, so a breaking change shows on its pull request; a library below 1.0, where a minor release may break the API, passes `api_breakage_check_enabled: false`.
- A library with DocC catalogs lists their targets in `.spi.yml`'s `documentation_targets`, and Soundness fails on any DocC warning in them. Each of `<project>-core`'s products has one (`Sources/BookshelfTransport/BookshelfTransport.docc`), since every service builds on its public API.
- `<project>-protos` has no tests and only builds: its CI workflows pass `linux_command: swift build -c release`, and `swift build` stands in for `swift test`, which fails on a package with no tests.
- `<project>-protos` also has a `buf.yaml` at its root, which `library.yml` reads to run buf: it lints the `.proto` files and fails a pull request that breaks the wire, such as a renumbered field or a reused tag, which the Swift API breakage check can't see. Its `buf.yaml` lists each target's folder as a module (`Sources/LoansProtos`), lints with `STANDARD` except `RPC_RESPONSE_STANDARD_NAME` and `RPC_REQUEST_RESPONSE_UNIQUE`, since an RPC returns its resource ([contracts](grpc.md#contracts-in-the-protos-package)), and checks `WIRE_JSON` for breaking changes.
- Once services have separate owners, `<project>-protos`' `.github/CODEOWNERS` gives each target's folder to the owners of its service (`/Sources/LoansProtos/ @bookshelf/loans`), and its ruleset requires a code owner's review, so a contract changes only with its service's approval. A sole maintainer leaves it out: GitHub never counts an author's own review.

## A service's CI workflows

Loans' `main.yml` has these jobs, and the platform's `staging` job after `service` ([Dokploy's](delivery-dokploy.md#staging-and-production)):

```yaml
name: Main

on:
  push:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}
  cancel-in-progress: false

jobs:
  service:
    name: Service
    permissions:
      contents: read
      packages: write
    uses: swift-microservices/ci/.github/workflows/service.yml@<commit>  # <release>
    with:
      linux_host_archs: '["aarch64"]'
      postgres_image: postgres:<major>-alpine
      foundation_linking_check_excluded_products: '["loans"]'
    secrets:
      PACKAGES_TOKEN: ${{ secrets.PACKAGES_TOKEN }}

  attest:
    name: Attest
    needs: [service]
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
    uses: swift-microservices/ci/.github/workflows/attest_image.yml@<commit>  # <release>
    with:
      image: ${{ needs.service.outputs.image }}
```

- Loans' `pull_request.yml` is `bookshelf-core`'s with this `service` job, without its `permissions`, in place of `library`.
- `service.yml` defaults `image_repository` to the service's image on GHCR, `ghcr.io/<owner>/<repository>` lowercased ([naming](conventions.md#naming)), and `cleanup_images.yml` defaults `package_name` to its package, the repository's name, so Loans' CI workflows pass neither. An image in another registry passes its `image_repository` to `service.yml`, and the `REGISTRY_USERNAME` and `REGISTRY_PASSWORD` secrets to `service.yml` and `attest_image.yml`.
- `service.yml` labels the image from the repository with the OCI keys GHCR shows: `org.opencontainers.image.source`, which links the package to the repository from its first push so the package inherits the repository's access, `.description`, `.licenses` and `.revision`, the commit. The package page shows the repository's description and license, and the Containerfile sets no labels.
- Every image build keeps the image's SBOM as a workflow artifact. A pull request's build fails on a critical vulnerability that has a fixed version, which a base image update or a dependency bump resolves; the publish on `main` reports one without failing, so a deploy or a hotfix never waits on a vulnerability disclosed after its pull request passed.
- `attest_image.yml` signs each published image's build provenance, and each of its architectures' SBOMs, and pushes them beside the image, where they last as long as the image, so the deployment can verify an image with `gh attestation verify oci://<image> --owner <owner>`. GitHub stores attestations for a private repository only on Enterprise Cloud, so a service on another plan leaves out the `attest` job.
- The gateway runs one process per environment and its CI workflows pass no `postgres_image`, since it has no worker or database; they exclude `gateway` while its generated OpenAPI code links full Foundation.
- The gateway's CI workflows also pass `openapi_breakage_check_path: Sources/GatewayHTTP/openapi.yaml`, so oasdiff fails a pull request whose `openapi.yaml` breaks a client of the base's, such as a route removed or an input newly required ([versions](gateway.md#versions)). Removing a route the base marks `deprecated: true` passes, as its sunset's pull request does. `oasdiff breaking main:Sources/GatewayHTTP/openapi.yaml Sources/GatewayHTTP/openapi.yaml --fail-on ERR` runs the same check locally.
- `deploy.yml` takes an optional `commit` input on `workflow_dispatch`, has `run-name: Deploy ${{ inputs.commit || 'what staging runs' }} to production`, runs its `production` job only on `refs/heads/main`, and calls the platform's deploy with `environment: production`, `promote_from: staging` and `commit: ${{ inputs.commit }}`. It deploys the image staging's newest successful deployment of that commit ran, by default what staging runs now, and production may skip the commits between ([migrations](persistence.md#migrations)).
- `cleanup_images.yml` calls `cleanup_images.yml`, which keeps the 30 newest commits' images of the image's package on GHCR, each with its platform images and attestations. A registry other than GHCR keeps as many through its own retention rules. A rollback runs `deploy.yml` with an older commit, rebuilding nothing, so it reaches only a kept image and runs on the current schema ([migrations](persistence.md#migrations)); staging goes back by re-running an older commit's `Staging` job.

## The deployment contract

What every platform's deploy does, whatever runs it:

- `service.yml` publishes the image once, as `:<commit-sha>`, and outputs it by digest as `image` (`<image_repository>:<commit-sha>@sha256:<hex>`), which `attest_image.yml` and the staging deploy take. Every environment deploys an image by its digest.
- Each command runs as its own process ([commands](composition.md#commands)): `loans migrate` at one replica, alone holding the owner's login ([Postgres](security.md#postgres)), then `loans serve` and `loans worker run`.
- `migrate` runs to completion: serve and the worker deploy only once migrate's container of the new image exits 0, and a failed migration stops the deploy with serve and the worker on the previous image ([migrations](persistence.md#migrations)). Nothing restarts a migrate that exited.
- Each other process waits for the one before it to run, and to pass its health check where it has one ([health](composition.md#health)).
- Staging deploys each push to `main` after `service`, taking its `image`; production deploys by hand through `deploy.yml`, promoting staging's image of a commit, so it runs only what staging ran.
- Each deployment runs in a GitHub environment, `staging` or `production`, one at a time and never cancelled midway, and records a GitHub deployment of the commit carrying its image, from which production's promotion reads staging's. The repository defines both environments: production allows only `main` to deploy, and its required reviewers are the user's answer. Staging and production may hold different platform keys as environment secrets.
- The stop timeout exceeds the worker's shutdown period ([the worker's root](composition.md#the-workers-root)).
- A client's host resolves to every replica of its upstream ([transports](grpc.md#transports)); the platform's reference names it.
- Certificates, keys and secrets are files mounted read-only at configured paths ([mutual TLS](security.md#mutual-tls), [secrets](security.md#secrets)), and the root filesystem may be read-only ([the Containerfile](#the-containerfile)).

## The Containerfile

A service's `Containerfile`, at its root, builds the image `service.yml` publishes:

- A build stage on `swift:<tools version>-noble` installs `libjemalloc-dev`, resolves with `RUN --mount=type=secret,id=netrc,target=/root/.netrc swift package --disable-automatic-resolution resolve`, so the token never enters a layer, then runs `swift build --configuration release --disable-automatic-resolution --static-swift-stdlib -Xlinker -ljemalloc --product loans`. It passes none of CI's flags: CI held the commit to them, and a warning a newer toolchain adds mustn't stop a deploy or a hotfix.
- A runtime stage on `ubuntu:noble` installs only `ca-certificates`, `tzdata` and `libjemalloc2`, creates an unprivileged user with a fixed numeric id (`useradd --uid 10001 loans`), and copies the product, `swift-backtrace-static` and any resource bundles to `/app`.
- It runs as `USER 10001:10001`, the numeric id, so the platform can tell from the image's configuration alone that it isn't root, from `WORKDIR /app`, with `ENTRYPOINT ["./loans"]` and `SWIFT_BACKTRACE` pointing at the static backtracer. CI's image check finds the executable through the `ENTRYPOINT`, so it starts the product itself, never a script, whose libraries the check can't see.
- The product links jemalloc's shared library, so the process allocates with jemalloc on every architecture: glibc's allocator keeps the memory a long-running server's many threads fragment, and its resident size grows for days. Jemalloc's static library doesn't work with the static Swift runtime. Linked rather than preloaded, a `libjemalloc2` missing from the runtime stage fails CI's check of the image's libraries, where a preload that misses only warns and the process runs on glibc's allocator.
- The process writes nothing inside the image, only to standard output and standard error, so the deployment may mount its root filesystem read-only.
- A `.dockerignore` beside it keeps `.build`, `.swiftpm`, `.env*`, `.netrc`, secrets and key files out of the build context.

## Dependabot

`.github/dependabot.yml` checks weekly, groups each ecosystem's updates into one pull request, and sets `cooldown: { default-days: 7 }`, so a broken or compromised release is withdrawn before it's proposed:

| Kind | Ecosystems | Label |
|---|---|---|
| Public or system library | `github-actions` | `semver/none` |
| Service | `swift` and `github-actions` | None |

- A library ignores `Package.resolved` ([choosing versions](stack.md#choosing-versions)), so CI resolves its dependencies' newest releases within their ranges, and `main.yml`'s weekly run catches one that breaks it. Its requirements are raised by hand.
- A service's `swift` updates move its `Package.resolved`. A private dependency needs a `registries` entry of type `git` for `https://github.com`, with `PACKAGES_TOKEN` as its password.
