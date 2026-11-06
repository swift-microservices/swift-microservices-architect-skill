# Delivery

How each package is built, tested, released and deployed: CI workflows on GitHub Actions that call `swift-microservices/ci`, and nothing else.

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

| Kind | Packages | Depended on by | Ships as |
|---|---|---|---|
| Public library | The swift-microservices libraries, any open-source package | Anyone | Semantic versions, released by hand |
| System library | `<org>-core`, `<org>-protos` | The organization's services and gateway | Semantic versions, released by hand; services depend `from:` a release |
| Service | Each service, and the gateway | Nothing | An image per commit on `main`, deployed to staging, then to production by hand |

## CI workflows

Each repository's `.github/workflows/` holds these CI workflows, each `name:` as given. They call only `swift-microservices/ci`, which routes to swiftlang's and Apple's workflows, so no repository pins those:

| File (`name:`) | Kind | Runs on | Calls in `swift-microservices/ci` | Job `permissions` |
|---|---|---|---|---|
| `ci.yml` (CI) | Library | Pull requests, pushes to `main`, a weekly `schedule` | `library.yml` | None beyond the workflow's `contents: read` |
| `ci.yml` (CI) | Service | Pull requests, pushes to `main` | `service.yml`, then `deploy_dokploy.yml` for staging | `contents: read`, `packages: write`; staging: `contents: read`, `actions: read`, `packages: read` |
| `pull_request_label.yml` (PR label) | Library | Pull requests and label changes | `pull_request_label.yml` | `contents: read`, `pull-requests: read` |
| `release.yml` (Release) | Library | By hand, on `main` | `release.yml` | `contents: write`, `pull-requests: read` |
| `deploy.yml` (Deploy to production) | Service | By hand, on `main` | `deploy_dokploy.yml` | `contents: read`, `actions: read`, `packages: read` |
| `cleanup_images.yml` (Clean up images) | Service | Weekly and by hand | `cleanup_images.yml` | `packages: write` |

`library.yml` and `service.yml` are the CI pipelines: they hold the standard, so a change every repository needs, such as a flag or a check, is made once in `swift-microservices/ci` and arrives through the pin Dependabot moves. Each runs these jobs:

| Run | `library.yml` | `service.yml` |
|---|---|---|
| Pull request | Soundness, Tests, Foundation linking | Soundness, Tests, Foundation linking, Build image |
| Push to `main` | Tests, Foundation linking | Tests and Foundation linking, then Publish image |
| Schedule | Tests, Foundation linking | — |

- `main` changes only through pull requests: a ruleset requires the CI workflow's jobs, and a library's label check. A push to `main` skips Soundness, which the pull request passed, and reruns Tests on the merged commit, which may differ from what the pull request tested.
- `ci.yml`'s `concurrency` group is the pull request's number or the commit, with `cancel-in-progress` on pull requests only: a run on `main` ships its commit.
- Each `uses:` is pinned to `swift-microservices/ci`'s latest release's full commit, with the release in a comment: `@<commit>  # <release>`. Look the commit up with `git ls-remote --tags <url>`.
- A workflow grants `contents: read` at its top. A job that sets `permissions` gets only those, so it lists `contents: read` again beside what it adds, as the table does.
- Soundness checks every file's license header against the repository's `.license_header_template`; a file without one, such as `LICENSE`, is listed in `.licenseignore`.
- A library's pull request carries exactly one label: `⚠️ semver/major`, `🆕 semver/minor`, `🔨 semver/patch` or `semver/none`. Release tags the version without a `v` and writes notes grouped by `.github/release.yml`. The first release, and a major one, is cut by hand.
- A service has no versions and no labels: `main` is its only long-lived branch, and a commit is what ships.

## Tests

The CI pipelines run the tests, and they're the gate. A library tests in release, which also proves its release build; a service tests its committed `Package.resolved`, and its release build is its image.

| Flag | Packages | Holds every change to |
|---|---|---|
| `-Xswiftc -warnings-as-errors` | Every kind, except on nightly toolchains | No warnings |
| `--explicit-target-dependency-import-check error` | Every kind | Importing only the modules its target declares |
| `-Xswiftc -require-explicit-sendable` | Libraries | Every `public` type stating whether it's `Sendable`; a service's `package` declarations aren't checked |

- The toolchain is the package's `swift-tools-version`, which the CI pipelines read: a service and a system library test on it, on Ubuntu noble and linux/arm64, the platform services run on, and the `Containerfile` builds on it. Moving a package to a newer Swift is its tools version and its `Containerfile`'s `FROM`, in one pull request.
- The image build passes none of the flags. CI held the commit to them already, and a warning a newer toolchain adds mustn't stop a deploy or a hotfix.
- `XPostgresTests` need a real Postgres: the CI workflow passes `postgres_image: postgres:<major>-alpine`, the major the services run, and the tests reach it through `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_DB`, unset without it.
- Private dependencies are marked by passing `PACKAGES_TOKEN`, and nothing else: a fine-grained token owned by the organization, with read-only Contents on the private package repositories, stored as an Actions secret and as a Dependabot secret.

## Foundation linking

Foundation linking always runs, in both CI pipelines. It builds an executable that links every library product, and a service's executable product, and fails if one links Foundation's full library or ICU ([traits and Foundation](packages.md#traits-and-foundation)).

- `foundation_linking_check_excluded_products` names a product that links full Foundation only through a dependency, such as `BookshelfPersistence` over PostgresNIO, or a service's executable while a package it depends on still does ([full Foundation](stack.md#full-foundation)). The check skips it and notes so; with every product excluded, it passes.
- The product leaves the list in the pull request that raises the dependency to a release that stops linking full Foundation, so the check covers it from then on.

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
      foundation_linking_check_excluded_products: "BookshelfPersistence"
```

- A public library widens the platforms to every toolchain its users may build with: `linux_swift_versions` from its tools version up through the newest release, then `nightly-main` and the next release's nightly; `linux_host_archs: '["x86_64", "aarch64"]'`; and `enable_linux_static_sdk_build: true`.
- `api_breakage_check_enabled` stays `false` below 1.0, where a minor release may break the API, and is `true` from 1.0, so a breaking change shows on its pull request before it merges.
- The documentation check is optional, for a library that writes DocC catalogs: `docs_check_targets` lists the targets with a DocC catalog, and Soundness builds their documentation, failing on any DocC warning. A library without a DocC catalog lists none, and the check doesn't run.
- `<org>-protos`, with no tests, passes `linux_build_command: swift build -c release`.

## A service's CI workflows

Loans' `ci.yml`. `service.yml` ends at a published image; the `staging` job deploys each push to `main` through the Dokploy adapter:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ci-${{ github.event.pull_request.number || github.sha }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

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
      foundation_linking_check_excluded_products: loans
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

- The gateway's `ci.yml` has no `postgres_image` and one application per environment, since it has no worker; it excludes `gateway` while its generated OpenAPI code links full Foundation.
- `deploy.yml` takes an optional `commit` on `workflow_dispatch`, runs only on `refs/heads/main`, and calls `swift-microservices/ci`'s `deploy_dokploy.yml` with `environment: production`, that `commit`, the `image_repository`, the production `application_ids`, and `DOKPLOY_URL` and `DOKPLOY_TOKEN`. It deploys only a commit that staging ran.
- `cleanup_images.yml` calls `cleanup_images.yml` with `package_name`, the image's package, which keeps its 30 newest versions. Deploying an older commit is the rollback, nothing is rebuilt, and it reaches only a commit whose image cleanup kept; its schema is the current one ([migrations](persistence.md#migrations)).
- An image is published once, as `:<commit-sha>`, and deployed by its digest. Each environment runs it as one Dokploy application per process: `loans` (serve) and `loans worker run` ([commands](composition.md#commands)). The application that runs `serve --migrate-database` is listed first.
- Secrets: `PACKAGES_TOKEN` ([tests](#tests)), and `DOKPLOY_URL` with `DOKPLOY_TOKEN`, a Dokploy API key that can read, update and deploy the applications.

## The Containerfile

A service's `Containerfile`, at its root, builds the image `service.yml` checks and publishes:

- A build stage on `swift:<tools version>-noble` resolves with `RUN --mount=type=secret,id=netrc,target=/root/.netrc swift package --disable-automatic-resolution resolve`, so the token never enters a layer, then runs `swift build --configuration release --disable-automatic-resolution --static-swift-stdlib --product loans`, with none of CI's flags ([tests](#tests)).
- A runtime stage on `ubuntu:noble` installs only `ca-certificates` and `tzdata`, creates an unprivileged user, and copies the product, `swift-backtrace-static` and any resource bundles to `/app`.
- It runs as that user, with `ENTRYPOINT ["./loans"]` and `SWIFT_BACKTRACE` pointing at the static backtracer.

## Dependabot

`.github/dependabot.yml` checks weekly, groups each ecosystem's updates into one pull request, and sets `cooldown: { default-days: 7 }`, so a release is proposed only after a week in which a broken or compromised one is withdrawn:

| Kind | Ecosystems | Label |
|---|---|---|
| Public or system library | `github-actions` | `semver/none` |
| Service | `swift` and `github-actions` | None |

- `github-actions` moves the `swift-microservices/ci` pin ([CI workflows](#ci-workflows)).
- A library ignores `Package.resolved`, so each CI run resolves its dependencies' newest releases within their `from:` ranges, and its weekly run catches a release that breaks it without a pull request. Its lower bounds are raised by hand ([choosing versions](stack.md#choosing-versions)).
- A service's `swift` updates move its `Package.resolved`. A private dependency needs a `registries` entry of type `git` for `https://github.com`, with `PACKAGES_TOKEN` as its password.
