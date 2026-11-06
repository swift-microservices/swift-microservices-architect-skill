# Delivery

How each package is built, tested, released and deployed: CI workflows on GitHub Actions that call one pipeline of `swift-microservices/ci` for the package's kind.

## Contents
- Package kinds
- CI workflows
- Tests
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

A public library is tested on every toolchain its users may build with. A system library and a service are tested on the one toolchain and architecture the services build and run with: the tools version, on linux/arm64.

## CI workflows

Each repository's `.github/workflows/` holds thin callers of `swift-microservices/ci`, each `name:` as given. They call nothing else: `swift-microservices/ci` routes to swiftlang's and Apple's workflows, so no repository pins those.

| File (`name:`) | Library | Service |
|---|---|---|
| `ci.yml` (CI) | `library.yml`, on pull requests, pushes to `main` and a weekly `schedule` | `service.yml`, on pull requests and pushes to `main` |
| `pull_request_label.yml` (PR label) | `pull_request_label.yml`: exactly one semver label | — |
| `release.yml` (Release) | `release.yml`, by hand on `main`: the next version from the merged labels | — |
| `deploy.yml` (Deploy to production) | — | `deploy.yml`, by hand on `main`, with `environment: production` |
| `cleanup-images.yml` (Clean up container images) | — | `cleanup-images.yml`, weekly |

The pipeline, not the repository, holds the standard, so a change every repository needs (a toolchain, a flag, a check) is made once in `swift-microservices/ci` and arrives through the pin Dependabot moves:

| Run | `library.yml` | `service.yml` |
|---|---|---|
| Pull request | Soundness, Tests, Foundation linking | Soundness, Tests, Foundation linking, Build image |
| Push to `main` | Tests, Foundation linking | Tests and Foundation linking, then Publish image, then Staging |
| Schedule | Tests, Foundation linking | — |

- `main` changes only through pull requests: a ruleset requires the CI workflow's jobs, and a library's label check. A push to `main` skips Soundness, which the pull request passed, and reruns Tests on the merged commit, which may differ from what the pull request tested.
- `ci.yml`'s `concurrency` group is the pull request's number or the commit, with `cancel-in-progress` on pull requests only: a run on `main` ships its commit.
- Each `uses:` is pinned to `swift-microservices/ci`'s latest release's full commit, with the release in a comment: `@<commit>  # <release>`. Look the commit up with `git ls-remote --tags <url>`.
- Every CI workflow grants `contents: read` at its top and more only on the job that needs it.
- A library's pull request carries exactly one label: `⚠️ semver/major`, `🆕 semver/minor`, `🔨 semver/patch` or `semver/none`. Release tags the version without a `v` and writes notes grouped by `.github/release.yml`. The first release, and a major one, is cut by hand.
- A service has no versions and no labels: `main` is its only long-lived branch, and a commit is what ships.

## Tests

The pipelines run the tests, and they're the gate. A library tests in release, which also proves its release build; a service tests its committed `Package.resolved`, and its release build is its image.

| Flag | Packages | Holds every change to |
|---|---|---|
| `-Xswiftc -warnings-as-errors` | Every kind, except on nightly toolchains | No warnings |
| `--explicit-target-dependency-import-check error` | Every kind | Importing only the modules its target declares |
| `-Xswiftc -require-explicit-sendable` | Libraries | Every `public` type stating whether it's `Sendable`; a service's `package` declarations aren't checked |

- The image build passes none of them. CI held the commit to them already, and a warning a newer toolchain adds mustn't stop a deploy or a hotfix.
- `XPostgresTests` need a real Postgres: the caller passes `postgres_image: postgres:18-alpine`, and the tests reach it through `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_DB`, unset without it.
- A package with private dependencies passes `PACKAGES_TOKEN`: a fine-grained token owned by the organization, with read-only Contents on the private package repositories and nothing else.

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
      docs_check_targets: "BookshelfAuthentication BookshelfPersistence BookshelfTesting BookshelfTransport"
      excluded_products: "BookshelfPersistence"
```

- The pipeline tests on the services' platform by default: Swift 6.3, the tools version, on Ubuntu noble and linux/arm64. A public library widens it to every toolchain its users may build with: `linux_swift_versions: '["6.2", "6.3", "6.4", "nightly-main", "nightly-6.4.x"]'` from its tools version up, `linux_host_archs: '["x86_64", "aarch64"]'` and `enable_linux_static_sdk_build: true`.
- `api_breakage_check_enabled` stays `false` below 1.0, where a minor release may break the API, and is `true` from 1.0, so a breaking change shows on its pull request before it merges.
- Foundation linking always runs. It builds an executable that links every library product and fails if it links Foundation's full library or ICU ([traits and Foundation](packages.md#traits-and-foundation)). `excluded_products` lists only a product that links Foundation through a dependency, such as `BookshelfPersistence` over PostgresNIO, and loses it when the dependency stops.
- `<org>-protos`, with no tests, passes `build_command: swift build -c release`. A library with Postgres tests or private dependencies passes `postgres_image` or `private_dependencies: true`, with `PACKAGES_TOKEN`.
- Soundness checks license headers against `.license_header_template`; a file without one, such as `LICENSE`, is listed in `.licenseignore`.
- `pull_request_label.yml` calls the label check on `[labeled, unlabeled, opened, reopened, synchronize]` with `pull-requests: read`; `release.yml` calls Release on `workflow_dispatch` with `contents: write` and `pull-requests: read`.

## A service's CI workflows

Loans' `ci.yml`:

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
      actions: read
    uses: swift-microservices/ci/.github/workflows/service.yml@<commit>  # <release>
    with:
      service_product: loans
      image_repository: ghcr.io/bookshelf/bookshelf-loans
      staging_application_ids: '["<loans serve>", "<loans worker>"]'
      postgres_image: postgres:18-alpine
      excluded_products: loans
    secrets:
      PACKAGES_TOKEN: ${{ secrets.PACKAGES_TOKEN }}
      DOKPLOY_URL: ${{ secrets.DOKPLOY_URL }}
      DOKPLOY_TOKEN: ${{ secrets.DOKPLOY_TOKEN }}
```

- The job grants what Publish and Staging need, since a called workflow holds no more than its caller gives it. The gateway's `ci.yml` has no `postgres_image` and one application per environment, since it has no worker.
- Foundation linking checks the service's executable, and Publish waits for it. While a package it depends on still links full Foundation ([full Foundation](stack.md#full-foundation)), the service passes `excluded_products: loans` and its README lists that package; the exclusion goes as soon as nothing does.
- `deploy.yml` takes an optional `commit` on `workflow_dispatch`, runs only on `refs/heads/main`, and calls `deploy.yml` with `environment: production` and the production application ids. It deploys only a commit that staging ran; deploying an older commit is the rollback, and nothing is rebuilt.
- `cleanup-images.yml` runs weekly and by hand, calling `cleanup-images.yml` with the image's package name.
- An image is published once, as `:<commit-sha>`, and deployed by its digest. Each environment runs it as one Dokploy application per process: `loans` (serve) and `loans worker run` ([commands](composition.md#commands)). The application that runs `serve --migrate-database` is listed first.
- A rollback runs the previous image on the current schema, which its migrations keep compatible ([migrations](persistence.md#migrations)).
- Secrets: `PACKAGES_TOKEN`, and `DOKPLOY_URL` with `DOKPLOY_TOKEN`, a Dokploy API key that can read, update and deploy the applications.

## The Containerfile

A service's `Containerfile`, at its root, builds the image `build-image.yml` checks:

- A build stage on `swift:<tools version>-noble` resolves with `RUN --mount=type=secret,id=netrc,target=/root/.netrc swift package --disable-automatic-resolution resolve`, so the token never enters a layer, then runs `swift build --configuration release --disable-automatic-resolution --static-swift-stdlib --product loans`, with none of CI's flags ([tests](#tests)).
- A runtime stage on `ubuntu:noble` installs only `ca-certificates` and `tzdata`, creates an unprivileged user, and copies the product, `swift-backtrace-static` and any resource bundles to `/app`.
- It runs as that user, with `ENTRYPOINT ["./loans"]` and `SWIFT_BACKTRACE` pointing at the static backtracer.

## Dependabot

`.github/dependabot.yml` checks weekly, groups each ecosystem's updates into one pull request, and sets `cooldown: { default-days: 7 }`, so a release is proposed only after a week in which a broken or compromised one is usually withdrawn:

| Kind | Ecosystems | Label |
|---|---|---|
| Public or system library | `github-actions` | `semver/none` |
| Service | `swift` and `github-actions` | None |

- `github-actions` moves the `swift-microservices/ci` pin, which brings every change to the pipelines.
- A library ignores `Package.resolved`, so each CI run resolves its dependencies' newest releases within their `from:` ranges, and its weekly run catches a release that breaks it without a pull request. Its lower bounds are raised by hand ([choosing versions](stack.md#choosing-versions)).
- A service's `swift` updates move its `Package.resolved`. A private dependency needs a `registries` entry of type `git` for `https://github.com`, with `PACKAGES_TOKEN` also stored as a Dependabot secret.
