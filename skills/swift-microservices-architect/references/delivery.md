# Delivery

How each package is tested, released and deployed. A repository's CI workflows call only `swift-microservices/ci`, whose CI pipelines, `library.yml` and `service.yml`, build on swiftlang's and Apple's workflows. A repository declares its inputs and secrets and nothing else, so a change every repository needs, such as a flag or a check, lands once in `swift-microservices/ci`.

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
| System library | `<org>-core`, `<org>-protos` | Semantic versions, for the organization's services and gateway |
| Service | Each service, and the gateway | An image per commit on `main`, deployed to staging, then to production by hand; no versions or labels, and no long-lived branch but `main` |

## CI workflows

Each repository's `.github/workflows/` holds these, each file's `name:` in parentheses:

| File (`name:`) | Kind | Runs on | Calls in `swift-microservices/ci` | Job `permissions` |
|---|---|---|---|---|
| `ci.yml` (CI) | Library | Pull requests, pushes to `main`, a weekly `schedule` | `library.yml` | None of its own |
| `ci.yml` (CI) | Service | Pull requests, pushes to `main` | `service.yml`, then `deploy_dokploy.yml` for staging | `contents: read`, `packages: write`; staging: `contents: read`, `actions: read`, `packages: read` |
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
- Secrets: `PACKAGES_TOKEN`, passed only by a package with private dependencies, which is all that marks them: a fine-grained token owned by the organization, with read-only Contents on the private package repositories, stored as an Actions secret and as a Dependabot secret. A service adds `DOKPLOY_URL` and `DOKPLOY_TOKEN`, a Dokploy API key that can read, update and deploy its applications.

## Tests

The CI pipelines run the tests, and they're the gate:

| Flag | Packages | Holds every change to |
|---|---|---|
| `-Xswiftc -warnings-as-errors` | Every kind, except on nightly toolchains | No warnings |
| `--explicit-target-dependency-import-check error` | Every kind | Importing no module outside the target's dependency closure |
| `-Xswiftc -require-explicit-sendable` | Libraries | Every `public` type stating whether it's `Sendable` |

- The toolchain is the package's `swift-tools-version`. CI tests on it, a service and a system library on Ubuntu noble and linux/arm64, where services run, and the `Containerfile` builds on it, so moving a package to a newer Swift changes its tools version and its `Containerfile`'s `FROM` in one pull request.
- `XPostgresTests` need a real Postgres: `ci.yml` passes `postgres_image: postgres:<major>-alpine`, the major the services run, and the tests reach it through `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_DB`, which are unset without it.

## Foundation linking

Both CI pipelines build an executable that links every library product, and a service's executable product, and fail when one links full Foundation or ICU ([traits and Foundation](packages.md#traits-and-foundation)).

- `foundation_linking_check_excluded_products` names a product that links full Foundation only through a dependency: `BookshelfPersistence` over PostgresNIO, or a service's executable while a package it depends on still does ([full Foundation](stack.md#full-foundation)). The check skips it and says so.
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
      foundation_linking_check_excluded_products: '["BookshelfPersistence"]'
```

- `api_breakage_check_enabled` is `true` from 1.0, so a breaking change shows on its pull request, and `false` below 1.0, where a minor release may break the API.
- A public library builds on every toolchain its users may have: `linux_swift_versions` from its tools version up through the newest release, then `nightly-main` and the next release's nightly; `linux_host_archs: '["x86_64", "aarch64"]'`; `enable_linux_static_sdk_build: true`.
- A library with DocC catalogs lists their targets in `docs_check_targets`, and Soundness fails on any DocC warning in them.
- `<org>-protos`, which has no tests, passes `linux_build_command: swift build -c release`.

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
      application_ids: '["<loans serve>", "<loans worker>"]'
    secrets:
      DOKPLOY_URL: ${{ secrets.DOKPLOY_URL }}
      DOKPLOY_TOKEN: ${{ secrets.DOKPLOY_TOKEN }}
```

- `service.yml` publishes the image once, as `:<commit-sha>`, and every environment deploys it by digest. An environment runs it as one Dokploy application per process, `loans` (serve) and `loans worker run` ([commands](composition.md#commands)), and `application_ids` lists the one that runs `serve --migrate-database` first.
- The gateway's `ci.yml` has no `postgres_image` and one application per environment, since it has no worker, and excludes `gateway` while its generated OpenAPI code links full Foundation.
- `deploy.yml` takes an optional `commit` on `workflow_dispatch`, runs only on `refs/heads/main`, and calls `deploy_dokploy.yml` with `environment: production`, that `commit`, the `image_repository`, the production `application_ids` and the Dokploy secrets. It deploys only a commit that staging ran.
- `cleanup_images.yml` calls `cleanup_images.yml` with `package_name`, the image's package, keeping its 30 newest versions. A rollback deploys an older commit's image, rebuilding nothing, so it reaches only a kept image and runs on the current schema ([migrations](persistence.md#migrations)).

## The Containerfile

A service's `Containerfile`, at its root, builds the image `service.yml` publishes:

- A build stage on `swift:<tools version>-noble` resolves with `RUN --mount=type=secret,id=netrc,target=/root/.netrc swift package --disable-automatic-resolution resolve`, so the token never enters a layer, then runs `swift build --configuration release --disable-automatic-resolution --static-swift-stdlib --product loans`. It passes none of CI's flags: CI held the commit to them, and a warning a newer toolchain adds mustn't stop a deploy or a hotfix.
- A runtime stage on `ubuntu:noble` installs only `ca-certificates` and `tzdata`, creates an unprivileged user, and copies the product, `swift-backtrace-static` and any resource bundles to `/app`.
- It runs as that user from `WORKDIR /app`, with `ENTRYPOINT ["./loans"]` and `SWIFT_BACKTRACE` pointing at the static backtracer.
- A `.dockerignore` beside it keeps `.build`, `.swiftpm`, `.env*`, `.netrc`, secrets and key files out of the build context.

## Dependabot

`.github/dependabot.yml` checks weekly, groups each ecosystem's updates into one pull request, and sets `cooldown: { default-days: 7 }`, so a broken or compromised release is withdrawn before it's proposed:

| Kind | Ecosystems | Label |
|---|---|---|
| Public or system library | `github-actions` | `semver/none` |
| Service | `swift` and `github-actions` | None |

- A library ignores `Package.resolved` ([choosing versions](stack.md#choosing-versions)), so CI resolves its dependencies' newest releases within their ranges, and the weekly run catches one that breaks it. Its requirements are raised by hand.
- A service's `swift` updates move its `Package.resolved`. A private dependency needs a `registries` entry of type `git` for `https://github.com`, with `PACKAGES_TOKEN` as its password.
