# Delivery

How each package is tested, released and deployed. A repository's CI workflows call only `swift-microservices/ci`, whose CI pipelines, `library.yml` and `service.yml`, build on swiftlang's and Apple's CI workflows. A repository declares its inputs and secrets and nothing else, so a change every repository needs, such as a flag or a check, lands once in `swift-microservices/ci`. [Its README](https://github.com/swift-microservices/ci#readme) gives each of its CI workflows' jobs and inputs, and what each requires of a repository.

## Contents
- Package kinds
- CI workflows
- Tests
- Foundation linking
- A library's CI workflows
- A service's CI workflows
- The Containerfile
- Dependabot

## Package kinds

| Kind | Packages | Ships as |
|---|---|---|
| Public library | The swift-microservices libraries, any open-source package | Semantic versions, for anyone |
| System library | `<project>-core`, `<project>-protos` | Semantic versions, for the project's services and gateway |
| Service | Each service, and the gateway | An image per commit on `main`, deployed to staging, then to production by hand; no versions or labels, and no long-lived branch but `main` |

## CI workflows

Each repository's `.github/workflows/` holds these, each file's `name:` in parentheses:

| File (`name:`) | Kind | Runs on | Calls in `swift-microservices/ci` | Job `permissions` |
|---|---|---|---|---|
| `ci.yml` (CI) | Library | Pull requests, pushes to `main`, a weekly `schedule` | `library.yml` | None of its own |
| `ci.yml` (CI) | Service | Pull requests, pushes to `main` | `service.yml`, then `deploy_dokploy.yml` for staging and `attest_image.yml` | `contents: read`, `packages: write`; staging: `contents: read`, `actions: read`, `packages: read`; attest: `contents: read`, `packages: write`, `id-token: write`, `attestations: write` |
| `pull_request_label.yml` (PR label) | Library | Pull requests and label changes | `pull_request_label.yml` | `contents: read`, `pull-requests: read` |
| `release.yml` (Release) | Library | By hand, on `main` | `release.yml` | `contents: write`, `pull-requests: read` |
| `deploy.yml` (Deploy to production) | Service | By hand, on `main` | `deploy_dokploy.yml` | `contents: read`, `actions: read`, `packages: read` |
| `cleanup_images.yml` (Clean up images) | Service | Weekly and by hand | `cleanup_images.yml` | `packages: write` |

- Each `uses:` is pinned to the full commit of `swift-microservices/ci`'s latest release, with the release in a comment: `@<commit>  # <release>`, looked up with `git ls-remote --tags <url>`. Dependabot moves the pin.
- `main` changes only through pull requests: a ruleset requires the CI workflow's jobs, and a library's label check.
- `ci.yml` cancels a superseded run on pull requests only, since a run on `main` ships its commit.
- Soundness checks every file's license header against `.license_header_template`, which holds the compact SPDX header with `@@` for the comment marker and `YEARS` for the year. `.licenseignore` lists `LICENSE` and `Package.swift`, whose tools-version line must come first.
- A library's pull request carries exactly one label: `⚠️ semver/major`, `🆕 semver/minor`, `🔨 semver/patch` or `semver/none`. Below 1.0, a breaking change is minor and an addition patch; a doc-comment fix is patch; a change to the README, tests or CI is none.
- Release tags the next version without a `v` and writes its notes grouped by `.github/release.yml`; the first release and every major one are tagged by hand. A tag never moves: a bad release is fixed forward with a new version.
- Secrets: `PACKAGES_TOKEN`, which only a package with private dependencies passes: a fine-grained token owned by `<owner>`, with read-only Contents on the private package repositories, stored as an Actions secret and as a Dependabot secret. A service adds `DOKPLOY_URL` and `DOKPLOY_TOKEN`, a Dokploy API key that can read, update and deploy its applications and read their containers, which the deploy reads to wait for the new image.

## Tests

The CI pipelines run the tests, and they're the gate:

| Flag | Packages | Holds every change to |
|---|---|---|
| `-Xswiftc -warnings-as-errors` | Every kind, except on nightly toolchains | No warnings |
| `--explicit-target-dependency-import-check error` | Every kind | Importing no module outside the target's dependency closure |
| `-Xswiftc -require-explicit-sendable` | Libraries | Every `public` type stating whether it's `Sendable` |

- The toolchain is the package's `swift-tools-version`. CI tests on it, on Ubuntu noble and linux/arm64 for a service and a system library, where services run, and the `Containerfile` builds on it, so moving a package to a newer Swift changes its tools version and its `Containerfile`'s `FROM` in one pull request.
- `XPostgresTests` need a real Postgres: `ci.yml` passes `postgres_image: postgres:<major>-alpine`, the major the services run, 18 or later, and the tests reach it through `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_DB`, which are unset without it. `XValkeyTests` need a real Valkey: a service with XValkey passes `valkey_image: valkey/valkey:<major>-alpine` too, the major its Valkey runs, 9 or later, and the tests reach it through `VALKEY_HOST` and `VALKEY_PORT`, unset without it.

## Foundation linking

Both CI pipelines build an executable that links every library product, and a service's executable product, and fail when one links full Foundation or ICU ([traits and Foundation](packages.md#traits-and-foundation)).

- `foundation_linking_check_excluded_products` names a product that links full Foundation only through a dependency: `BookshelfPersistence` over PostgresNIO, or a service's executable while a package it depends on does ([full Foundation](stack.md#full-foundation)). The check skips it and says so.
- A product leaves the list in the pull request that raises the dependency to a release that stops linking full Foundation.

## A library's CI workflows

`bookshelf-core`'s `ci.yml`:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: "0 6 * * 1"

permissions:
  contents: read

concurrency:
  group: ci-${{ github.event.pull_request.number || github.sha }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  ci:
    name: CI
    uses: swift-microservices/ci/.github/workflows/library.yml@<commit>  # <release>
    with:
      api_breakage_check_enabled: true
      docs_check_targets: "BookshelfAuthentication BookshelfPersistence BookshelfTransport BookshelfTesting"
      foundation_linking_check_excluded_products: '["BookshelfPersistence"]'
```

- `api_breakage_check_enabled` is `true` from 1.0, so a breaking change shows on its pull request, and `false` below 1.0, where a minor release may break the API.
- A public library builds on every toolchain its users may have: `linux_swift_versions` from its tools version up through the newest release, then `nightly-main` and the next release's nightly; `linux_host_archs: '["x86_64", "aarch64"]'`; `enable_linux_static_sdk_build: true`.
- A library with DocC catalogs lists their targets in `docs_check_targets`, and Soundness fails on any DocC warning in them. Each of `<project>-core`'s products has one (`Sources/BookshelfTransport/BookshelfTransport.docc`), since every service builds on its public API.
- `<project>-protos` has no tests and only builds: its `ci.yml` passes `linux_build_command: swift build -c release`, and `swift build` stands in for `swift test`, which fails on a package with no tests.
- `<project>-protos` also has a `buf.yaml` at its root, which `library.yml` reads to run buf: it lints the `.proto` files and fails a pull request that breaks the wire, such as a renumbered field or a reused tag, which the Swift API breakage check can't see. Its `buf.yaml` lists each target's folder as a module (`Sources/LoansProtos`), lints with `STANDARD` except `RPC_RESPONSE_STANDARD_NAME` and `RPC_REQUEST_RESPONSE_UNIQUE`, since an RPC returns its resource ([contracts](grpc.md#contracts-in-the-protos-package)), and checks `WIRE_JSON` for breaking changes.
- Once services have separate owners, `<project>-protos`' `.github/CODEOWNERS` gives each target's folder to the owners of its service (`/Sources/LoansProtos/ @bookshelf/loans`), and its ruleset requires a code owner's review, so a contract changes only with its service's approval. A sole maintainer leaves it out: GitHub never counts an author's own review.

## A service's CI workflows

Loans' `ci.yml` has the library's `name`, `on` without its `schedule`, `permissions` and `concurrency`, and these jobs:

```yaml
jobs:
  ci:
    name: CI
    permissions:
      contents: read
      packages: write
    uses: swift-microservices/ci/.github/workflows/service.yml@<commit>  # <release>
    with:
      executable_product: loans
      image_repository: ghcr.io/bookshelf/bookshelf-loans
      postgres_image: postgres:<major>-alpine
      foundation_linking_check_excluded_products: '["loans"]'
    secrets:
      PACKAGES_TOKEN: ${{ secrets.PACKAGES_TOKEN }}

  staging:
    name: Staging
    needs: [ci]
    if: github.event_name == 'push'
    permissions:
      contents: read
      actions: read
      packages: read
    uses: swift-microservices/ci/.github/workflows/deploy_dokploy.yml@<commit>  # <release>
    with:
      environment: staging
      image_repository: ghcr.io/bookshelf/bookshelf-loans
      application_ids: '["<loans migrate>", "<loans serve>", "<loans worker>"]'
      run_to_completion_application_ids: '["<loans migrate>"]'
    secrets:
      DOKPLOY_URL: ${{ secrets.DOKPLOY_URL }}
      DOKPLOY_TOKEN: ${{ secrets.DOKPLOY_TOKEN }}

  attest:
    name: Attest
    needs: [ci]
    if: github.event_name == 'push'
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
    uses: swift-microservices/ci/.github/workflows/attest_image.yml@<commit>  # <release>
    with:
      image_repository: ghcr.io/bookshelf/bookshelf-loans
```

- `service.yml` publishes the image once, as `:<commit-sha>`, and every environment deploys it by digest. An environment runs it as one Dokploy application per command ([commands](composition.md#commands)), in `application_ids`' order: `loans migrate` at one replica, alone holding the owner's login ([Postgres](security.md#postgres)), then `loans serve` and `loans worker run`. `run_to_completion_application_ids` lists `loans migrate`, so `deploy_dokploy.yml` deploys serve only once migrate's container of the new image exits 0, and a failed migration stops the deploy with serve and the worker on the previous image ([migrations](persistence.md#migrations)). Each other application waits for the one before it to run, and to pass its health check where it has one ([health](composition.md#health)). The migrate application has no health check, and its Swarm settings in Dokploy give it a restart policy whose condition is `none` and an update config whose failure action is `continue`, as swift-microservices/ci requires of an application that runs to completion.
- Every image build keeps the image's SBOM as a workflow artifact. A pull request's build fails on a critical vulnerability that has a fixed version, which a base image update or a dependency bump resolves; the publish on `main` reports one without failing, so a deploy or a hotfix never waits on a vulnerability disclosed after its pull request passed.
- `attest_image.yml` signs each published image's build provenance and SBOM and pushes them beside the image, where they last as long as the image, so the deployment can verify an image with `gh attestation verify oci://<image> --owner <owner>`. GitHub stores attestations for a private repository only on Enterprise Cloud, so a service on another plan leaves out the `attest` job.
- The gateway's `ci.yml` has no `postgres_image` and one application per environment, since it has no worker or database, and excludes `gateway` while its generated OpenAPI code links full Foundation.
- The gateway's `ci.yml` also passes `openapi_breakage_check_path: Sources/GatewayHTTP/openapi.yaml`, so oasdiff fails a pull request whose `openapi.yaml` breaks a client of the base's, such as a route removed or an input newly required ([versions](gateway.md#versions)). Removing a route the base marks `deprecated: true` passes, as its sunset's pull request does. `oasdiff breaking main:Sources/GatewayHTTP/openapi.yaml Sources/GatewayHTTP/openapi.yaml --fail-on ERR` runs the same check locally.
- `deploy.yml` takes an optional `commit` on `workflow_dispatch`, runs only on `refs/heads/main`, and calls `deploy_dokploy.yml` with `environment: production`, that `commit`, the `image_repository`, the production `application_ids` and `run_to_completion_application_ids`, and the Dokploy secrets. It deploys only a commit that staging ran, and may skip the commits between ([migrations](persistence.md#migrations)).
- `cleanup_images.yml` calls `cleanup_images.yml` with `package_name`, the image's package, keeping its 30 newest versions. A rollback deploys an older commit's image, rebuilding nothing, so it reaches only a kept image and runs on the current schema ([migrations](persistence.md#migrations)).

## The Containerfile

A service's `Containerfile`, at its root, builds the image `service.yml` publishes:

- A build stage on `swift:<tools version>-noble` resolves with `RUN --mount=type=secret,id=netrc,target=/root/.netrc swift package --disable-automatic-resolution resolve`, so the token never enters a layer, then runs `swift build --configuration release --disable-automatic-resolution --static-swift-stdlib --product loans`. It passes none of CI's flags: CI held the commit to them, and a warning a newer toolchain adds mustn't stop a deploy or a hotfix.
- A runtime stage on `ubuntu:noble` installs only `ca-certificates`, `tzdata` and `libjemalloc2`, creates an unprivileged user with a fixed numeric id (`useradd --uid 10001 loans`), and copies the product, `swift-backtrace-static` and any resource bundles to `/app`.
- It runs as `USER 10001:10001`, the numeric id, so the platform can tell from the image's configuration alone that it isn't root, from `WORKDIR /app`, with `ENTRYPOINT ["./loans"]` and `SWIFT_BACKTRACE` pointing at the static backtracer.
- It preloads `libjemalloc.so.2` from `/usr/lib/aarch64-linux-gnu` through the dynamic loader's preload variable, so the process allocates with jemalloc: glibc's allocator keeps the memory a long-running server's many threads fragment, and its resident size grows for days.
- The process writes nothing inside the image, only to standard output and standard error, so the deployment may mount its root filesystem read-only.
- A `.dockerignore` beside it keeps `.build`, `.swiftpm`, `.env*`, `.netrc`, secrets and key files out of the build context.

## Dependabot

`.github/dependabot.yml` checks weekly, groups each ecosystem's updates into one pull request, and sets `cooldown: { default-days: 7 }`, so a broken or compromised release is withdrawn before it's proposed:

| Kind | Ecosystems | Label |
|---|---|---|
| Public or system library | `github-actions` | `semver/none` |
| Service | `swift` and `github-actions` | None |

- A library ignores `Package.resolved` ([choosing versions](stack.md#choosing-versions)), so CI resolves its dependencies' newest releases within their ranges, and the weekly run catches one that breaks it. Its requirements are raised by hand.
- A service's `swift` updates move its `Package.resolved`. A private dependency needs a `registries` entry of type `git` for `https://github.com`, with `PACKAGES_TOKEN` as its password.
