# Delivery

How each package is built, tested, released and deployed: GitHub Actions workflows that call shared reusable workflows, chosen by the package's kind.

## Contents
- Package kinds
- Workflows
- Reusable workflows
- Tests
- A library's workflows
- A service's workflows
- The Containerfile
- Dependabot

## Package kinds

| Kind | Packages | Depended on by | Ships as |
|---|---|---|---|
| Public library | The swift-microservices libraries, any open-source package | Anyone | Semantic versions, released by hand |
| System library | `<org>-core`, `<org>-protos` | The organization's services and gateway | Semantic versions, released by hand; services depend `from:` a release |
| Service | Each service, the gateway | Nothing | An image per commit on `main`, deployed to staging, then to production by hand |

A public library is tested on every toolchain its users may build with. A system library and a service are tested on the one toolchain and architecture the services build and run with: the tools version, on linux/arm64.

## Workflows

Each repository's `.github/workflows/` holds these files, each `name:` as given:

| File (`name:`) | Runs on | Public or system library | Service |
|---|---|---|---|
| `pull_request.yml` (PR) | Every pull request | Soundness, Tests, Foundation linking | Soundness, Tests, Build image |
| `main.yml` (Main) | Every push to `main` | Tests, Foundation linking | Soundness, Tests, then Publish image, then Staging |
| `pull_request_label.yml` (PR label) | Every pull request and label change | Semantic version label check | — |
| `release.yml` (Release) | By hand, on `main` | The next release from the merged labels | — |
| `deploy.yml` (Deploy to production) | By hand, on `main` | — | Production |
| `cleanup-images.yml` (Clean up container images) | Weekly | — | Clean up |

- Every workflow grants `contents: read` at its top and more only on the job that needs it: `packages: write` to publish an image, `actions: read` and `packages: read` to deploy one.
- A library's pull request carries exactly one label: `⚠️ semver/major`, `🆕 semver/minor`, `🔨 semver/patch` or `semver/none`. Release reads them to choose the next version, tags it without a `v`, and writes notes grouped by `.github/release.yml`. The first release, and a major one, is cut by hand.
- A service has no versions and no labels: `main` is its only long-lived branch, and a commit is what ships.

## Reusable workflows

| Job | Calls |
|---|---|
| Soundness | `swiftlang/github-workflows` `soundness.yml` |
| Tests | `swiftlang/github-workflows` `swift_package_test.yml`; `swift-microservices/ci` `tests.yml` for a package with private dependencies or a Postgres |
| Foundation linking | `swift-microservices/ci` `foundation-linking.yml` |
| Semantic version label check | The `pull_request_semver_label_checker` action of `apple/swift-nio` |
| Release | `apple/swift-temporal-sdk` `auto-release.yml` |
| Build image, Publish image | `swift-microservices/ci` `build-image.yml` |
| Staging, Production | `swift-microservices/ci` `deploy.yml` |
| Clean up | `swift-microservices/ci` `cleanup-images.yml` |

- swiftlang's workflows come first. `swift-microservices/ci` holds only what they can't do, and a repository writes a job of its own only for what neither has. Its `tests.yml` takes `swift_package_test.yml`'s Linux inputs, plus `postgres_image`; `foundation-linking.yml` takes `excluded_products`, and `container_image` for a toolchain other than its default.
- Each `uses:` is pinned to its latest release's full commit, with the release in a comment: `@<commit>  # <release>`. Look the commit up with `git ls-remote --tags <url>`; Dependabot moves the pins.

## Tests

Every build and test passes the same flags:

```
-Xswiftc -warnings-as-errors --explicit-target-dependency-import-check error -Xswiftc -require-explicit-sendable
```

Nightly toolchains, which a public library also tests on, take them without `-warnings-as-errors` in `swift_nightly_flags`, since a nightly may warn about code a release accepts.

| Input | Public library | System library | Service |
|---|---|---|---|
| `linux_swift_versions` | swiftlang's default, with `linux_exclude_swift_versions` for those below the tools version | The tools version, such as `'["6.3"]'` | The tools version |
| `linux_os_versions` | `'["noble"]'` | `'["noble"]'` | `'["noble"]'` |
| `linux_host_archs` | swiftlang's default | `'["aarch64"]'` | `'["aarch64"]'` |
| `linux_build_command` | `swift test -c release` | `swift test -c release`; `<org>-protos`, with no tests, `swift build -c release` | `swift test --disable-automatic-resolution` |
| `enable_linux_static_sdk_build` | `true` | `false` | — |
| `enable_windows_checks` | `false` | `false` | — |

- A library tests in release, which also proves its release build. A service's release build is its image.
- A service builds and tests its committed `Package.resolved`, never a newer resolution.
- `XPostgresTests` need a real Postgres: the package calls `swift-microservices/ci` `tests.yml` with `postgres_image: postgres:18-alpine`, and the tests reach it through `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_DB`.
- A package with private dependencies passes `PACKAGES_TOKEN`: a fine-grained token owned by the organization, with read-only Contents on the private package repositories and nothing else.

## A library's workflows

`bookshelf-core`'s pull request workflow; `main.yml` runs the same `tests` and `foundation-linking` jobs on every push to `main`:

```yaml
name: PR

permissions:
  contents: read

on:
  pull_request:
    types: [opened, reopened, synchronize]

jobs:
  soundness:
    name: Soundness
    uses: swiftlang/github-workflows/.github/workflows/soundness.yml@<commit>  # <release>
    with:
      api_breakage_check_enabled: false
      docs_check_targets: "BookshelfAuthentication BookshelfPersistence BookshelfTesting BookshelfTransport"

  tests:
    name: Tests
    uses: swiftlang/github-workflows/.github/workflows/swift_package_test.yml@<commit>  # <release>
    with:
      linux_swift_versions: '["6.3"]'
      linux_os_versions: '["noble"]'
      linux_host_archs: '["aarch64"]'
      linux_build_command: swift test -c release
      swift_flags: >-
        -Xswiftc -warnings-as-errors
        --explicit-target-dependency-import-check error
        -Xswiftc -require-explicit-sendable
      enable_windows_checks: false

  foundation-linking:
    name: Foundation linking
    uses: swift-microservices/ci/.github/workflows/foundation-linking.yml@<commit>  # <release>
    with:
      excluded_products: "BookshelfPersistence"
```

- Soundness checks formatting, YAML, shell, license headers against `.license_header_template`, language, symlinks and documentation. A file without a header, such as `LICENSE`, is listed in `.licenseignore`.
- `api_breakage_check_enabled` stays `false` below 1.0, where a minor release may break the API, and is `true` from 1.0, so a breaking change shows on its pull request before it merges.
- Foundation linking builds an executable that links every library product and fails if it links Foundation's full library or ICU ([traits and Foundation](packages.md#traits-and-foundation)). `excluded_products` lists only a product whose dependency links Foundation, such as `BookshelfPersistence` over PostgresNIO.
- `pull_request_label.yml` runs the label check on `[labeled, unlabeled, opened, reopened, synchronize]`, and `release.yml` is a `workflow_dispatch` job named `release`, with `contents: write` and `pull-requests: read`.

## A service's workflows

Loans' `main.yml`. The gateway's has the same jobs:

```yaml
name: Main

permissions:
  contents: read

on:
  push:
    branches: [main]

jobs:
  soundness:
    name: Soundness
    uses: swiftlang/github-workflows/.github/workflows/soundness.yml@<commit>  # <release>
    with:
      api_breakage_check_enabled: false
      docs_check_enabled: false

  tests:
    name: Tests
    uses: swift-microservices/ci/.github/workflows/tests.yml@<commit>  # <release>
    with:
      linux_swift_versions: '["6.3"]'
      linux_host_archs: '["aarch64"]'
      linux_build_command: swift test --disable-automatic-resolution
      swift_flags: >-
        -Xswiftc -warnings-as-errors
        --explicit-target-dependency-import-check error
        -Xswiftc -require-explicit-sendable
      postgres_image: postgres:18-alpine
    secrets:
      PACKAGES_TOKEN: ${{ secrets.PACKAGES_TOKEN }}

  publish:
    name: Publish image
    needs: [soundness, tests]
    permissions:
      contents: read
      packages: write
    uses: swift-microservices/ci/.github/workflows/build-image.yml@<commit>  # <release>
    with:
      service_product: loans
      image_repository: ghcr.io/bookshelf/bookshelf-loans
      publish: true
    secrets:
      PACKAGES_TOKEN: ${{ secrets.PACKAGES_TOKEN }}

  staging:
    name: Staging
    needs: [publish]
    permissions:
      contents: read
      actions: read
      packages: read
    uses: swift-microservices/ci/.github/workflows/deploy.yml@<commit>  # <release>
    with:
      environment: staging
      image_repository: ghcr.io/bookshelf/bookshelf-loans
      application_ids: '["<loans serve>", "<loans worker>"]'
    secrets:
      DOKPLOY_URL: ${{ secrets.DOKPLOY_URL }}
      DOKPLOY_TOKEN: ${{ secrets.DOKPLOY_TOKEN }}
```

- `pull_request.yml` runs the same `soundness` and `tests` jobs, and an `image` job, named Build image, calling `build-image.yml` without `publish`. Its `concurrency` group is the pull request's number, with `cancel-in-progress: true`.
- `deploy.yml` takes an optional `commit` on `workflow_dispatch`, runs only on `refs/heads/main`, and calls `swift-microservices/ci` `deploy.yml` with `environment: production` and the production application ids. It deploys only a commit that staging ran; deploying an older commit is the rollback, and nothing is rebuilt.
- `cleanup-images.yml` runs weekly and by hand, calling `cleanup-images.yml` with the image's package name.
- An image is published once, as `:<commit-sha>`, and deployed by its digest. Each environment runs it as one Dokploy application per process: `loans` (serve) and `loans worker run` ([commands](composition.md#commands)). The application that runs `serve --migrate-database` is listed first.
- Migrations expand, then contract in a later release, since a rollback runs the previous image on the current schema.
- Secrets: `PACKAGES_TOKEN`, and `DOKPLOY_URL` with `DOKPLOY_TOKEN`, a Dokploy API key that can read, update and deploy the applications.

## The Containerfile

A service's `Containerfile`, at its root, builds the image `build-image.yml` checks:

- A build stage on `swift:<tools version>-noble` resolves with `RUN --mount=type=secret,id=netrc,target=/root/.netrc swift package --disable-automatic-resolution resolve`, so the token never enters a layer, then builds `--configuration release --disable-automatic-resolution --static-swift-stdlib --product loans` with the flags above.
- A runtime stage on `ubuntu:noble` installs only `ca-certificates` and `tzdata`, creates an unprivileged user, and copies the product, `swift-backtrace-static` and any resource bundles to `/app`.
- It runs as that user, with `ENTRYPOINT ["./loans"]` and `SWIFT_BACKTRACE` pointing at the static backtracer.

## Dependabot

`.github/dependabot.yml` checks weekly, each ecosystem's updates grouped into one pull request:

| Kind | Ecosystems | Label |
|---|---|---|
| Public or system library | `github-actions` | `semver/none` |
| Service | `swift` and `github-actions` | None |

- A library's dependencies are `from:` lower bounds raised only when code needs a newer API ([choosing versions](stack.md#choosing-versions)), so Dependabot moves only its workflow pins.
- A service's `swift` updates move its `Package.resolved`. A private dependency needs a `registries` entry of type `git` for `https://github.com`, with `PACKAGES_TOKEN` also stored as a Dependabot secret.
