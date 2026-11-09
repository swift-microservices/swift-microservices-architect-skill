# Packages

The targets inside a service's package, how they depend on each other, its `Package.swift`, and the project's shared packages. The build fails an import the target can't reach; [the boundary script](#checking-the-boundaries) and review hold the rest.

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
| `XPostgres` | A scope per database role, repositories, prepared statements, row decoding, migrations | `XCore`, `PersistencePostgres`, `PostgresNIO`, `PostgresMigrations`, `AsyncAlgorithms`, `Logging` |
| `XGRPC` | The service's proto services, `Protobuf/` conversions, gRPC clients for Core's ports | `XCore`, its own and its callees' `XProtos`, `GRPCCore`, `SwiftProtobuf`, `Authentication`, `OperationContext`, `<Project>Authentication` |
| `XValkey` | Repositories over Valkey | `XCore`, `Valkey` |
| `X<Provider>` | A third-party API behind a Core port (`LoansResend`) | `XCore`, the provider's SDK |
| `X` | The executable: commands, configuration defaults and readers, the migration list, composition roots | Every target above, `<Project>Transport`, `<Project>Persistence`, drivers, transports, `Configuration`, `ServiceLifecycle`, `ArgumentParser` |

A service declares only the targets its plan needs: Catalog is `CatalogCore`, `CatalogPostgres`, `CatalogGRPC` and `Catalog`.

- Adapter targets never import each other. They meet in the executable, which hands one to another through Core's protocols: `GRPCCatalogClient` from XGRPC goes into `BorrowBookUseCase` and `LoanActivities`, which see only `any CatalogClient`.
- Generated contract types stay in XGRPC and the executable (descriptors for interceptors, `Client(wrapping:)`); Postgres types stay in XPostgres and the executable; Temporal types in [Core's Temporal files](#what-core-may-link) and the executable.
- Nothing outside the package links a service, so a service has one product, its executable, and its cross-target API is `package` ([access control](style.md#access-control-and-imports)).

## What Core may link

Core links a library that saves every service re-declaring a concept, when the library:
- does no I/O and has nothing to `run()`;
- has no transport, driver or engine types in its API;
- doesn't pull full Foundation into the target;
- is stable enough for its types to appear in use case signatures.

`Persistence`, `<Project>Authentication`, `Logging`, `Authentication` for issuing credentials (Identity's `CredentialIssuer`), and `Crypto` for hashing a token qualify. `PostgresNIO`, `GRPCCore`, `Hummingbird`, `Valkey`, `AsyncHTTPClient`, a provider's SDK, generated contracts and `Configuration` don't: Core declares a port, and an adapter target implements it.

`Temporal` is the one deliberate exception to these criteria: Core commits to it, as it does to the standard library. A workflow is the application's orchestration, and Temporal's determinism rules and macros make a wrapper cost more than it saves. It stays in its own corner of Core, file by file, since a module's types are visible only in files that import it:
- `import Temporal` appears only in `XCore/Workflows/**` and in the use cases that start, signal, query or update a workflow, in `XUseCase.swift` alone of their five files.
- A file whose `package` API names Temporal's types, including what a Temporal macro on a `package` type expands to, uses `package import Temporal`; the rest use the default internal import.
- Models, domain errors, repository protocols, ports and every other use case never import it, and neither does an adapter target.
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
        .package(url: "https://github.com/swift-microservices/swift-authentication.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-microservices/swift-authentication-grpc.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-microservices/swift-authentication-jwt.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-microservices/swift-operation-context.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-microservices/swift-persistence.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-microservices/swift-persistence-postgres.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.1.5"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.5.0", traits: []),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.17.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.35.2"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.36.0", traits: []),
        .package(url: "https://github.com/apple/swift-temporal-sdk.git", from: "1.5.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-extras.git", from: "2.2.2"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.12.0"),
        .package(url: "https://github.com/hummingbird-project/postgres-migrations.git", from: "1.2.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.13.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.2"),
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
        .target(
            name: "LoansPostgres",
            dependencies: [
                "LoansCore",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PersistencePostgres", package: "swift-persistence-postgres"),
                .product(name: "PostgresMigrations", package: "postgres-migrations"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "LoansGRPC",
            dependencies: [
                "LoansCore",
                .product(name: "Authentication", package: "swift-authentication"),
                .product(name: "BookshelfAuthentication", package: "bookshelf-core"),
                .product(name: "CatalogProtos", package: "bookshelf-protos"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "IdentityProtos", package: "bookshelf-protos"),
                .product(name: "LoansProtos", package: "bookshelf-protos"),
                .product(name: "OperationContext", package: "swift-operation-context"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "Loans",
            dependencies: [
                "LoansCore",
                "LoansGRPC",
                "LoansPostgres",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AuthenticationGRPC", package: "swift-authentication-grpc"),
                .product(name: "AuthenticationJWT", package: "swift-authentication-jwt"),
                .product(name: "BookshelfAuthentication", package: "bookshelf-core"),
                .product(name: "BookshelfPersistence", package: "bookshelf-core"),
                .product(name: "BookshelfTransport", package: "bookshelf-core"),
                .product(name: "CatalogProtos", package: "bookshelf-protos"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCServiceLifecycle", package: "grpc-swift-extras"),
                .product(name: "IdentityProtos", package: "bookshelf-protos"),
                .product(name: "LoansProtos", package: "bookshelf-protos"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCertificateReloading", package: "swift-nio-extras"),
                .product(name: "PersistencePostgres", package: "swift-persistence-postgres"),
                .product(name: "PostgresMigrations", package: "postgres-migrations"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Temporal", package: "swift-temporal-sdk"),
                .product(name: "UnixSignals", package: "swift-service-lifecycle"),
            ],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

- The tools version is the newest Swift release: the toolchain the services build and deploy with, which the system libraries share. A public library's is instead the oldest Swift its users build with. 6.2 is the floor for these settings.
- `platforms: [.macOS(.v15)]` is the floor several dependencies declare; Linux ignores it. A dependency that requires a newer macOS raises it, with the reason in the package's README.
- Every target lists each module it imports, product by product. CI's `--explicit-target-dependency-import-check error` fails only an import the target can't reach ([delivery](delivery.md#tests)), so listing a module reached through another dependency, such as `GRPCCore` through `LoansCore`, is kept by review.
- Each requirement follows [choosing versions](stack.md#choosing-versions).
- A provider target (`LoansResend`) and test targets follow the same form, and the executable lists the provider target. No target sets `.treatAllWarnings(as: .error)`: warnings fail CI's test builds ([delivery](delivery.md#tests)), so a local or release build never stops on one.

## Swift settings

Every target in every package, services and libraries, builds in Swift 6 mode with the template's `swiftSettings`. The code relies on `package` access, typed throws and package traits ([style](style.md)). A server package never sets `.defaultIsolation(MainActor.self)`.

## Traits and Foundation

On Linux, full Foundation brings `FoundationInternationalization` and ICU's data into the binary; `FoundationEssentials` has the types a service uses without them. A target links full Foundation through owned code, a dependency's own imports, or a dependency's default traits. Owned code takes the conditional import ([Foundation](style.md#foundation)); dependencies are declared here.

| Package | Traits that link full Foundation (`*` default) | Declare |
|---|---|---|
| hummingbird | `FullFoundation`* | `traits: ["ConfigurationSupport"]` where its configuration reader is used (the gateway), `traits: []` elsewhere |
| swift-openapi-runtime | `FullFoundation`* | `traits: []` |
| swift-configuration | `JSON`*, `YAML`, `PropertyList` | `traits: []`, plus `Reloading` or `CommandLineArguments` when used |
| swift-protobuf | `BinaryDelimitedStreams`* | `traits: []`, plus `FieldMaskUtilities` when a contract uses field masks |

- Traits unify across the graph: a default trait is off only when every package that declares the dependency turns it off. `<project>-core`, `<project>-protos`, each service and the gateway turn off the same Foundation traits, and so must the libraries they depend on; the template's lower bounds are releases that do.
- A few products link full Foundation and stay out of `dependencies`: `NIOFoundationCompat` (`NIOFoundationEssentialsCompat` instead), `NIOCertificateHelpers` (`NIOCertificateReloading` is Foundation-free), `HTTPTypesFoundation`. `HummingbirdTesting` links it, in test targets only.
- A dependency that still links full Foundation ([the stack](stack.md#full-foundation)) is recorded in the service's README. Owned code stays on `FoundationEssentials`, so the service sheds full Foundation when the dependency does, and CI checks it from then on ([Foundation linking](delivery.md#foundation-linking)).
- Before adding a dependency, list its traits with `swift package show-traits` and read its sources' Foundation imports. A library proves it in CI with the Foundation-linking check ([Foundation linking](delivery.md#foundation-linking)).

## Folder layout

```
bookshelf-loans/
├── Package.swift
└── Sources/
    ├── LoansCore/
    │   ├── Loans/
    │   │   ├── Loan.swift, LoanStatus.swift, LoanPolicy.swift
    │   │   ├── Repository/         LoanRepository.swift, Commands/CreateLoanCommand.swift
    │   │   └── UseCases/           BorrowBook/, ReturnBook/, ListLoans/, ListAllLoans/, MarkLoanOverdue/, ReceiveNoticeEvent/
    │   ├── Workflows/
    │   │   └── LoanWorkflow/       LoanWorkflow.swift, LoanActivities.swift, ActivityOptions+Loans.swift
    │   ├── Paging/                 Page.swift, KeyedPage.swift
    │   └── Ports/                  Book.swift, CatalogClient.swift, CatalogClientError.swift,
    │                               Member.swift, IdentityClient.swift, OverdueNotice.swift, NoticeSender.swift,
    │                               NoticeEvent.swift, NoticeEventVerifier.swift
    ├── LoansPostgres/
    │   ├── Scopes/                 PostgresLoansScope.swift, PostgresLoansInternalScope.swift, PostgresLoansWorkerScope.swift
    │   ├── Repositories/Loans/     PostgresLoanRepository.swift
    │   ├── Statements/Loans/       CreateLoanStatement.swift, ActiveLoansByUserIDStatement.swift, LoansByUserIDStatement.swift,
    │   │                       CountLoansByUserIDStatement.swift, Loan+PostgresRow.swift
    │   ├── Extensions/             LoanStatus+PostgresCodable.swift
    │   └── Migrations/             Role/CreateServiceRole.swift, …, Loans/CreateLoansTable.swift, Loans/CreateLoansRLSPolicy.swift
    ├── LoansGRPC/
    │   ├── Loans/                  LoanService.swift, Protobuf/BorrowBookUseCaseInput+Protobuf.swift, Protobuf/Loan+Protobuf.swift
    │   └── Clients/                GRPCCatalogClient.swift, GRPCIdentityClient.swift, Protobuf/Book+Protobuf.swift
    ├── LoansResend/                ResendNoticeSender.swift, ResendNoticeEventVerifier.swift
    └── Loans/
        ├── Loans.swift             the @main command
        ├── Configuration/          InMemoryProvider+ApplicationDefaults.swift, LoanPolicy+ConfigReader.swift
        ├── Database/               Migrations.swift
        ├── Serve/                  Serve.swift
        └── Worker/                 Worker.swift, Run.swift
```

Where each file goes: [folders](conventions.md#folders).

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
    │                               JWTIssuer+ConfigReader.swift
    └── BookshelfTesting/           MockDatabase.swift, MockAuthenticator.swift
```

- One product per target, each its own dependency set: a Core target that links `BookshelfAuthentication` acquires no transport, driver or configuration module.
- `BookshelfAuthentication` depends on swift-authentication, swift-authentication-jwt, jwt-kit, swift-log and swift-operation-context. `BookshelfPersistence` adds swift-persistence-postgres, grpc-swift-2 for the interceptor and swift-configuration; only executables link it. `BookshelfTransport` adds grpc-swift-nio-transport, swift-nio-extras and swift-configuration.
- Its API is `public`, with `public import` for every module whose types it exposes.
- It releases with semantic versions; services depend on a release of it, never a branch or `.package(path:)`. A change to it, or to `<project>-protos`, is released and tagged first; each service and the gateway then raise their requirement.

## The contracts package

```
bookshelf-protos/
├── Package.swift
└── Sources/
    ├── CatalogProtos/
    │   ├── CatalogProtos.swift                       empty: the generated files are the sources
    │   ├── bookshelf/catalog/v1/catalog.proto
    │   └── grpc-swift-proto-generator-config.json
    ├── IdentityProtos/                               the same files for bookshelf.identity.v1
    └── LoansProtos/                                  the same files for bookshelf.loans.v1
```

Each target:

```swift
.target(
    name: "LoansProtos",
    dependencies: [
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
    ],
    swiftSettings: swiftSettings,
    plugins: [
        .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")
    ]
),
```

with `grpc-swift-proto-generator-config.json`:

```json
{
  "generate": {
    "clients": true,
    "servers": true,
    "messages": true
  },
  "generatedSource": {
    "accessLevel": "public",
    "accessLevelOnImports": true
  }
}
```

- One library product per target; swift-protobuf declared with `traits: []`.
- The plugin generates at build time with the `protoc` swift-protobuf builds from source (`PROTOC_PATH` overrides it), so a build machine installs nothing, and generated files are never committed or edited.
- The package holds the `.proto` files and nothing else in Swift: conversions and validation belong to each service's `Protobuf/` folders.

## The gateway package

`bookshelf-gateway` has two targets, laid out in [the gateway's package](gateway.md#the-package): `GatewayHTTP`, the HTTP surface, and `Gateway`, the executable. `GatewayHTTP` links Hummingbird (`traits: ["ConfigurationSupport"]`), HummingbirdAuth, swift-openapi-runtime with the generator plugin, `Authentication`, `AuthenticationHummingbird`, `BookshelfAuthentication`, `GRPCCore`, `SwiftProtobuf` for the well-known types' members (`Google_Protobuf_Timestamp.date`), `Logging` for `ErrorMiddleware`'s log lines, and the `XProtos` of every upstream. It has no Core, Postgres or persistence target.

## Checking the boundaries

SPM checks that a target can reach what it imports, but not what a declaration should be. This skill's `scripts/check_boundaries.sh <X> <Project>` checks the rest, run from a service's root (`check_boundaries.sh Loans Bookshelf`). It prints each violation under its rule and exits non-zero if there is any:

- Core imports no adapter technology or contract.
- Temporal stays out of the adapter targets.
- Inside Core, only `Workflows/` and use case implementations import Temporal, and a use case that imports it names `TemporalClient`.
- Only the executable builds a Temporal client or worker.
- An activity container stores only use case and port protocols and a `Logger`.
- Activities call system use cases only, so nothing in `Workflows/` names a caller.
- Adapters import no sibling adapter, and only XGRPC imports the service's contract.
- Generated contract types stay in XGRPC and the executable.
- Only the executable reads configuration.
- Every Foundation import is the conditional one.
- There are no unstructured tasks.
- Every use case protocol has typed throws.
- No package defaults to the main actor.

It also lists each use of unchecked concurrency for review, without failing: every one is in an adapter target with its reason on the line above, as [concurrency](style.md#concurrency) allows.
