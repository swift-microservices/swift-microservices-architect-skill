# Packages

The targets inside a service's package, how they depend on each other, its `Package.swift`, and the project's shared packages.

## Contents
- The targets of a service
- What Core may link
- Package.swift template
- Swift settings
- Traits and Foundation
- Folder layout
- The project's core package
- The contracts package
- The gateway package
- Checking the boundaries

## The targets of a service

| Target | Holds | Imports |
|---|---|---|
| `XCore` | Domain models, errors, repository protocols and commands, ports, use cases, workflows and activity containers | `Persistence`, `<Project>Authentication`, `Logging`, `Temporal` in a service with workflows, and what else [Core may link](#what-core-may-link) |
| `XPostgres` | A scope per database role, repositories, prepared statements, row decoding, migrations | `XCore`, `PersistencePostgres`, `PostgresNIO`, `PostgresMigrations`, `AsyncAlgorithms`, `Logging`; `<Project>Authentication` where a table stores a `UserRole` |
| `XGRPC` | The service's proto services, `Protobuf/` conversions, gRPC clients for Core's ports | `XCore`, its own and its callees' `XProtos`, `GRPCCore`, `SwiftProtobuf`, `Authentication`, `OperationContext`, `<Project>Authentication` |
| `XValkey` | Repositories over Valkey | `XCore`, `Valkey` |
| `XKafka` | Handlers for the topics it consumes, publishers for Core's event ports, `Protobuf/` conversions of events ([events](events.md)) | `XCore`, its own and its producers' `XProtos`, `Kafka`, `SwiftProtobuf`, `<Project>Events` |
| `X<Provider>` | A third-party API behind a Core port (`LoansResend`) | `XCore`, the provider's SDK; `NIOPosix` for work on `NIOThreadPool` |
| `X` | The executable: commands, configuration defaults and readers, applying the migrations, composition roots | Every target above, `<Project>Transport`, `<Project>Persistence`, drivers, transports, `Configuration`, `ServiceLifecycle`, `ArgumentParser`; `NIOSSL` with Valkey; `<Project>Events` with Kafka |

A service declares only the targets its plan needs: Catalog is `CatalogCore`, `CatalogPostgres`, `CatalogGRPC`, `CatalogKafka` and `Catalog`.

- Adapter targets never import each other. They meet in the executable, which hands one to another through Core's protocols: `GRPCCatalogClient` from XGRPC goes into `BorrowBookUseCase` and `LoanActivities`, which see only `any CatalogClient`.
- Generated contract types stay in XGRPC, XKafka and the executable (descriptors for interceptors, `Client(wrapping:)`); Postgres types stay in XPostgres and the executable; Temporal types in [Core's Temporal files](#what-core-may-link) and the executable.
- Nothing outside the package links a service, so a service has one product, its executable, and its cross-target API is `package` ([access control](style.md#access-control-and-imports)).

## What Core may link

Core links a library that saves every service re-declaring a concept, when the library:
- does no I/O and has nothing to `run()`;
- has no transport, driver or engine types in its API;
- doesn't pull full Foundation into the target;
- is stable enough for its types to appear in use case signatures.

`Persistence`, `<Project>Authentication`, `Logging`, `Authentication` for issuing credentials (Identity's `CredentialIssuer`), and `Crypto` for hashing a token qualify. `PostgresNIO`, `GRPCCore`, `Hummingbird`, `Valkey`, `Kafka`, `AsyncHTTPClient`, a provider's SDK, generated contracts and `Configuration` don't: Core declares a port, and an adapter target implements it.

`Temporal` is the one deliberate exception to these criteria: Core commits to it, as it does to the standard library. A workflow is the application's orchestration, and Temporal's determinism rules and macros make a wrapper cost more than it saves. It stays in its own corner of Core, file by file, since a module's types are visible only in files that import it:
- `import Temporal` appears only in `XCore/Workflows/**` and in the use cases that start, signal, query or update a workflow, in `XUseCase.swift` alone of their five files.
- A file whose `package` API names Temporal's types, including what a Temporal macro on a `package` type expands to, uses `package import Temporal`; the rest use the default internal import.
- Models, domain errors, repository protocols, ports and every other use case never import it.
- Only the executable constructs `TemporalClient` and `TemporalWorker`, reads their configuration and adds them to the `ServiceGroup`.
- Building Core links the SDK's prebuilt sdk-core binary, so the build machine must be able to fetch it.

## Package.swift template

Loans, the service with the most targets:

```swift
// swift-tools-version: 6.4

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
]

let package = Package(
    name: "bookshelf-loans",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "loans", targets: ["Loans"])
    ],
    dependencies: [
        .package(url: "https://github.com/bookshelf/bookshelf-core.git", from: "1.0.0"),
        .package(url: "https://github.com/bookshelf/bookshelf-protos.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.5.0", traits: []),
        .package(url: "https://github.com/apple/swift-temporal-sdk.git", from: "1.5.0"),
        // … one requirement per library a target imports, each from its latest release
    ],
    targets: [
        .target(
            name: "LoansCore",
            dependencies: [
                .product(name: "BookshelfAuthentication", package: "bookshelf-core"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Persistence", package: "swift-persistence"),
                .product(name: "Temporal", package: "swift-temporal-sdk"),
            ],
            swiftSettings: swiftSettings
        ),
        // … LoansPostgres, LoansGRPC and the executable the same way: each lists every module it imports,
        // product by product, with swiftSettings
    ],
    swiftLanguageModes: [.v6]
)
```

- The tools version is the newest Swift release: the toolchain the services build and deploy with, which the system libraries share. A public library's is instead the oldest Swift its users build with. 6.2 is the floor for these settings.
- `platforms: [.macOS(.v15)]` is the floor several dependencies declare; Linux ignores it. A dependency that requires a newer macOS raises it, with the reason in the package's README.
- Every target lists each module it imports, product by product. CI's `--explicit-target-dependency-import-check error` fails only an import the target can't reach ([the gate](delivery.md#the-gate)), so listing a module reached through another dependency, such as `GRPCCore` through `LoansCore`, is kept by review.
- Each requirement follows [choosing versions](stack.md#choosing-versions).
- A target joins `Package.swift` when its first source file is written: SPM refuses a target with no sources, so a package builds target by target, Core first.
- A provider target (`LoansResend`), a Kafka target (`LoansKafka`) and test targets follow the same form, and the executable lists each. No target sets `.treatAllWarnings(as: .error)`: warnings fail CI's test builds ([the gate](delivery.md#the-gate)), so a local or release build never stops on one.

## Swift settings

Every target in every package, services and libraries, builds in Swift 6 mode with the template's `swiftSettings`. Under `.strictMemorySafety()`, CI's warnings-as-errors fails an unsafe construct not marked `unsafe`; it doesn't flag `@unchecked Sendable`, which the boundary script checks. The code relies on `package` access, typed throws and package traits ([style](style.md)). A server package never sets `.defaultIsolation(MainActor.self)`.

## Traits and Foundation

On Linux, full Foundation brings `FoundationInternationalization` and ICU's data into the binary; `FoundationEssentials` has the types a service uses without them. A target links full Foundation through owned code, a dependency's own imports, or a dependency's default traits. Owned code takes the conditional import ([Foundation](style.md#foundation)); dependencies are declared here.

| Package | Traits that link full Foundation (`*` default) | Declare |
|---|---|---|
| hummingbird | `FullFoundation`* | `traits: ["ConfigurationSupport"]` where its configuration reader is used (the gateway), `traits: []` elsewhere |
| swift-openapi-runtime | `FullFoundation`* | `traits: []` |
| swift-configuration | `JSON`*, `YAML`, `PropertyList` | `traits: []`, plus `Reloading` or `CommandLineArguments` when used |
| swift-protobuf | `BinaryDelimitedStreams`* | `traits: []`, plus `FieldMaskUtilities` when a contract uses field masks |
| swift-otel | `OTLPHTTP`*, `OTLPGRPC`* | `traits: ["OTLPGRPC"]`: one exporter, over the gRPC stack every process links |

- Traits unify across the graph: a default trait is off only when every package that declares the dependency turns it off. `<project>-core`, `<project>-protos`, each service and the gateway turn off the same Foundation traits, and so must the libraries they depend on; the template's lower bounds are releases that do.
- A dependency that links full Foundation ([the stack](stack.md#full-foundation)) is recorded in the service's README, and owned code stays on `FoundationEssentials` ([Foundation linking](delivery.md#foundation-linking)).
- Before adding a dependency, list its traits with `swift package show-traits` and read its sources' Foundation imports. A library proves it in CI with the Foundation-linking check ([Foundation linking](delivery.md#foundation-linking)).

## Folder layout

```
bookshelf-loans/
├── Package.swift
└── Sources/
    ├── LoansCore/
    │   ├── Loans/
    │   │   ├── Loan.swift, LoanStatus.swift, LoanPolicy.swift, LoanEvent.swift, LoanEventKind.swift, NoticeEvent.swift
    │   │   ├── Repository/         LoanRepository.swift, LoanRepositoryError.swift, LoanEventRepository.swift,
    │   │   │                       LoanEventRepositoryError.swift, Commands/CreateLoanCommand.swift
    │   │   └── UseCases/           BorrowBook/, ReturnBook/, ListLoans/, ListAllLoans/, MarkLoanOverdue/, ReceiveNoticeEvent/,
    │   │                           PublishLoanEvents/
    │   ├── Workflows/
    │   │   └── LoanWorkflow/       LoanWorkflow.swift, LoanActivities.swift, ActivityOptions+Loans.swift
    │   ├── Catalog/                Book.swift
    │   ├── Identity/               Member.swift
    │   ├── Paging/                 Page.swift, KeyedPage.swift
    │   └── Ports/                  CatalogClient.swift, CatalogClientError.swift, IdentityClient.swift, IdentityClientError.swift,
    │                               NoticeSender.swift, NoticeEventVerifier.swift, LoanEventPublisher.swift,
    │                               LoanEventPublisherError.swift
    ├── LoansPostgres/
    │   ├── Scopes/                 PostgresLoansScope.swift, PostgresLoansInternalScope.swift, PostgresLoansWorkerScope.swift
    │   ├── Repositories/Loans/     PostgresLoanRepository.swift
    │   ├── Statements/Loans/       CreateLoanStatement.swift, ActiveLoansByUserIDStatement.swift, LoansByUserIDStatement.swift,
    │   │                           CountLoansByUserIDStatement.swift, Loan+PostgresRow.swift
    │   ├── Extensions/             LoanStatus+PostgresCodable.swift
    │   └── Migrations/             LoansMigrations.swift, Role/CreateServiceRole.swift, …, Loans/CreateLoansTable.swift, Loans/CreateLoansRLSPolicy.swift
    ├── LoansGRPC/
    │   ├── Loans/                  LoanService.swift, Protobuf/BorrowBookUseCaseInput+Protobuf.swift, Protobuf/Loan+Protobuf.swift
    │   └── Clients/                GRPCCatalogClient.swift, GRPCIdentityClient.swift, Protobuf/Book+Protobuf.swift
    ├── LoansResend/                ResendNoticeSender.swift, ResendNoticeEventVerifier.swift
    ├── LoansKafka/                 KafkaLoanEventPublisher.swift, Protobuf/LoanEvent+Protobuf.swift
    └── Loans/
        ├── Loans.swift             the @main command
        ├── Configuration/          InMemoryProvider+ApplicationDefaults.swift, LoanPolicy+ConfigReader.swift
        ├── Database/               Migrations.swift
        ├── Serve/                  Serve.swift
        ├── Migrate/                Migrate.swift
        ├── BuildIndexes/           BuildIndexes.swift
        └── Worker/                 Worker.swift, Run.swift
```

Where each file goes, a type two areas share included: [folders](conventions.md#folders).

## The project's core package

```
bookshelf-core/
├── Package.swift
└── Sources/
    ├── BookshelfAuthentication/    UserIdentity.swift, UserRole.swift, OperationContext+User.swift, JWT+EdDSA.swift
    ├── BookshelfPersistence/       PostgresSettings+User.swift, UserSettingsInterceptor.swift,
    │                               PostgresClient.Configuration+ConfigReader.swift
    ├── BookshelfTransport/         TimedCertificateReloader.Configuration+ConfigReader.swift,
    │                               HTTP2ServerTransport.Posix.TransportSecurity+ConfigReader.swift,
    │                               HTTP2ClientTransport.Posix.TransportSecurity+ConfigReader.swift,
    │                               HTTP2ServerTransport.Posix.Config+ConfigReader.swift,
    │                               HTTP2ClientTransport.Posix.Config+ConfigReader.swift,
    │                               ServiceConfig+ConfigReader.swift, JWTAuthenticator+ConfigReader.swift,
    │                               InternalCallerInterceptor.swift
    ├── BookshelfEvents/            KafkaProducerConfig+ConfigReader.swift, KafkaConsumerConfig+ConfigReader.swift,
    │                               OutboxRelay.swift, EventHandler.swift, EventRejection.swift, EventConsumer.swift
    └── BookshelfTesting/           MockDatabase.swift, MockAuthenticator.swift
```

- One product per target, each its own dependency set: a Core target that links `BookshelfAuthentication` acquires no transport, driver or configuration module.
- `BookshelfAuthentication` depends on swift-authentication, swift-authentication-jwt and jwt-kit for the issuer's and authenticator's initializers ([signing keys](security.md#signing-keys)), swift-log and swift-operation-context. `BookshelfPersistence` adds swift-persistence-postgres, postgres-nio, swift-nio-ssl for the TLS configuration, grpc-swift-2 for the interceptor, and swift-configuration; executables link it, and `XPostgresTests` for the settings it binds. `BookshelfTransport` adds grpc-swift-2 for `ServiceConfig` and the interceptor, grpc-swift-nio-transport, swift-certificates for the peer's DNS names, swift-nio-extras, swift-configuration, and swift-authentication-jwt for the authenticator's reader. `BookshelfEvents` depends on swift-kafka-client, swift-protobuf for the handlers' events, swift-configuration, swift-service-lifecycle and swift-log; only the services with [events](events.md) link it, so no other service builds librdkafka.
- Its API is `public`, with `public import` for every module whose types it exposes.
- It releases with semantic versions; services depend on a release of it, never a branch or `.package(path:)`. A change to it, or to `<project>-protos`, is released and tagged first; each service and the gateway then raise their requirement. Before the shared packages have a remote, each is a local repository with its releases tagged, and a dependent names it by its `file://` URL and the same `from:`, which resolves as a release does; the URL becomes the remote's in one change once it exists.

## The contracts package

```
bookshelf-protos/
├── .github/CODEOWNERS                                each target's folder to its service's owners (delivery.md)
├── Package.swift
├── buf.yaml                                          buf's modules, lint and breaking rules (delivery.md)
└── Sources/
    ├── CatalogProtos/
    │   ├── CatalogProtos.swift                       empty: the generated files are the sources
    │   ├── bookshelf/catalog/v1/catalog.proto
    │   └── grpc-swift-proto-generator-config.json
    ├── IdentityProtos/                               the same files for bookshelf.identity.v1
    └── LoansProtos/                                  the same files for bookshelf.loans.v1, plus its events.proto
```

- Each target depends on `GRPCCore`, `GRPCProtobuf` and `SwiftProtobuf`, and runs grpc-swift-protobuf's `GRPCProtobufGenerator` plugin, whose `grpc-swift-proto-generator-config.json` generates clients, servers and messages, `public`, with access levels on imports.
- One library product per target; swift-protobuf declared with `traits: []`.
- The plugin generates at build time with the `protoc` swift-protobuf builds from source (`PROTOC_PATH` overrides it), so a build machine installs nothing, and generated files are never committed or edited.
- The package holds the `.proto` files and nothing else in Swift: conversions and validation belong to each service's `Protobuf/` folders.

## The gateway package

`bookshelf-gateway` has two targets, laid out in [the gateway's package](gateway.md#the-package): `GatewayHTTP`, the HTTP surface, and `Gateway`, the executable. `GatewayHTTP` links Hummingbird (`traits: ["ConfigurationSupport"]`), HummingbirdAuth, swift-openapi-runtime with the generator plugin, `Authentication`, `AuthenticationHummingbird`, `BookshelfAuthentication`, `GRPCCore`, `SwiftProtobuf` for the well-known types' members (`Google_Protobuf_Timestamp.date`), `HTTPTypes` for the header names it reads, `Logging` for `ErrorMiddleware`'s log lines, and the `XProtos` of every upstream. It has no Core, Postgres or persistence target.

## Checking the boundaries

SPM checks that a target can reach what it imports, but not what a declaration should be. Two scripts check the rest, and each prints the rule it checks above its violations and exits non-zero if there is any, so they're run rather than read:

- `scripts/check_boundaries.sh <X> <Project>`, from a service's root (`check_boundaries.sh Loans Bookshelf`) or the gateway's (`check_boundaries.sh Gateway Bookshelf`): the hard rules in `SKILL.md`, Core's links, ports, repositories and use case protocols, the conditional Foundation import, unstructured tasks and the main actor. It also lists each use of unchecked concurrency for review, without failing: every one is in an adapter target with its reason on the line above, as [concurrency](style.md#concurrency) allows.
- `scripts/check_style.sh`, from any package's root with no arguments: the style rules a script can see, from build, then call to sentinels, `try?`, force unwraps, a handler's `default`, the unknown-error log line and where configuration is read. It also lists for review, without failing: each Core repository method with two parameters or more that isn't named for what it returns and takes no command or page size, since a write that takes more than an id takes a command ([repositories](use-cases.md#repositories-and-commands)); and each test file named for no type in `Sources/` ([test targets](testing.md#test-targets)).
