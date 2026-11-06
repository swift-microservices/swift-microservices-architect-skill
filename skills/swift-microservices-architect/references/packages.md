# Packages

The targets inside a service's package, how they depend on each other, its `Package.swift`, and the organization's shared packages. SPM and CI enforce each boundary: a target imports only the modules its declaration lists.

## Contents
- The targets of a service
- What Core may link
- Package.swift template
- Swift settings
- Traits and Foundation
- Folder layout
- The organization's core package
- The contracts package
- The gateway package
- Checking the boundaries

## The targets of a service

| Target | Holds | Imports |
|---|---|---|
| `XCore` | Domain models, errors, repository protocols and commands, ports, use cases | `Persistence`, `<Org>Authentication`, `Logging`, and what else [Core may link](#what-core-may-link) |
| `XPostgres` | A scope per database role, repositories, prepared statements, row decoding, migrations | `XCore`, `PersistencePostgres`, `PostgresNIO`, `PostgresMigrations`, `AsyncAlgorithms`, `Logging` |
| `XGRPC` | The service's proto services, `Protobuf/` conversions, gRPC clients for Core's ports | `XCore`, its own and its callees' `XProtos`, `GRPCCore`, `SwiftProtobuf`, `Authentication`, `OperationContext`, `<Org>Authentication` |
| `XTemporal` | Workflows, activity containers, the Temporal client for Core's workflow port | `XCore`, `Temporal`, and `Logging` where a workflow logs |
| `XValkey` | Repositories over Valkey | `XCore`, `Valkey` |
| `X<Provider>` | A third-party API behind a Core port (`LoansResend`) | `XCore`, the provider's SDK |
| `XHTTP` | HTTP the service serves itself, only for a caller that can't go through the gateway, named in the plan with the reason; a provider's webhook goes through the gateway | `XCore`, `Hummingbird`, `Authentication`, `AuthenticationHummingbird`, `<Org>Authentication` |
| `X` | The executable: commands, configuration defaults and readers, the migration list, composition roots | Every target above, `<Org>Transport`, `<Org>Persistence`, drivers, transports, `Configuration`, `ServiceLifecycle`, `ArgumentParser` |

A service declares only the targets its plan needs: Catalog is `CatalogCore`, `CatalogPostgres`, `CatalogGRPC` and `Catalog`.

- Adapter targets never import each other. They meet in the executable, which hands one to another through Core's protocols: `GRPCCatalogClient` from XGRPC goes into `BorrowBookUseCase`, which XTemporal's activities never see.
- Generated contract types stay in XGRPC and the executable (descriptors for interceptors, `Client(wrapping:)`); Postgres types stay in XPostgres and the executable; Temporal types in XTemporal and the executable.
- Nothing outside the package links a service, so a service has one product, its executable, and its cross-target API is `package` ([access control](style.md#access-control-and-imports)).

## What Core may link

Core links a library that saves every service re-declaring a concept, when the library:
- does no I/O and has nothing to `run()`;
- has no transport, driver or engine types in its API;
- doesn't pull full Foundation into the target;
- is stable enough for its types to appear in use case signatures.

`Persistence`, `<Org>Authentication`, `Logging`, `Authentication` for issuing credentials (Identity's `CredentialIssuer`), `Crypto` for hashing a token, and a focused standards library whose types the rules are written in (a WebAuthn ceremony's) qualify. `PostgresNIO`, `GRPCCore`, `Hummingbird`, `Temporal`, `Valkey`, `AsyncHTTPClient`, a provider's SDK, generated contracts and `Configuration` don't: Core declares a port, and an adapter target implements it.

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
        .package(url: "https://github.com/swift-microservices/swift-authentication.git", .upToNextMinor(from: "0.4.0")),
        .package(url: "https://github.com/swift-microservices/swift-authentication-grpc.git", .upToNextMinor(from: "0.5.0")),
        .package(url: "https://github.com/swift-microservices/swift-authentication-jwt.git", .upToNextMinor(from: "0.3.2")),
        .package(url: "https://github.com/swift-microservices/swift-operation-context.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/swift-microservices/swift-persistence.git", .upToNextMinor(from: "0.2.1")),
        .package(url: "https://github.com/swift-microservices/swift-persistence-postgres.git", .upToNextMinor(from: "0.3.0")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.1.5"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.5.0", traits: []),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.17.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.35.2"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.32.0", traits: []),
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
        .target(
            name: "LoansTemporal",
            dependencies: [
                "LoansCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Temporal", package: "swift-temporal-sdk"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "Loans",
            dependencies: [
                "LoansCore",
                "LoansGRPC",
                "LoansPostgres",
                "LoansTemporal",
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

- The tools version is the newest Swift release: the toolchain the services build and deploy with, which the system libraries share. A public library's is instead the oldest Swift its users build with. 6.2 is the floor for these settings, and the gateway has a higher one ([choosing versions](stack.md#choosing-versions)).
- `platforms: [.macOS(.v15)]` is the floor several dependencies declare; Linux ignores it. A dependency that requires a newer macOS raises it, with the reason in the package's README.
- Every target lists each module it imports, product by product; CI's `--explicit-target-dependency-import-check error` fails a target that imports one it doesn't list ([delivery](delivery.md#tests)).
- Each requirement follows [choosing versions](stack.md#choosing-versions).
- A provider target (`LoansResend`) and test targets follow the same form. No target sets `.treatAllWarnings(as: .error)`: warnings fail CI's test builds ([delivery](delivery.md#tests)), so a local or release build never stops on one. A warning in generated code fails the contracts package's CI, and its consumers never see it, since SwiftPM silences a dependency's warnings.

## Swift settings

Every target in every package, services and libraries, builds with the same settings:

| Setting | Proposal |
|---|---|
| `swiftLanguageModes: [.v6]` | Swift 6 language mode, with complete concurrency checking |
| `ExistentialAny` | [SE-0335](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0335-existential-any.md) |
| `MemberImportVisibility` | [SE-0444](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md) |
| `InternalImportsByDefault` | [SE-0409](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md) |
| `NonisolatedNonsendingByDefault` | [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md) |

The code also relies on `package` access ([SE-0386](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0386-package-access-modifier.md)), typed throws ([SE-0413](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md)) and package traits ([SE-0450](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md)). A server package never sets `.defaultIsolation(MainActor.self)` ([SE-0466](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)). How the code uses each: [style](style.md).

## Traits and Foundation

On Linux, full Foundation links `libFoundation`, `libFoundationInternationalization` and ICU's data, which alone outweighs a service's own code several times over. `FoundationEssentials` has the types a service uses (`Data`, `Date`, `URL`, `UUID`, `JSONEncoder` and `JSONDecoder`, `Date.ISO8601FormatStyle`, `Calendar`, `TimeZone`, `FileManager`) without them. A target links full Foundation through owned code, a dependency's own imports, or a dependency's default traits. Owned code takes the conditional import ([Foundation](style.md#foundation)); dependencies are declared here.

| Package | Traits that link full Foundation (`*` default) | Declare | Turning them off loses |
|---|---|---|---|
| hummingbird | `FullFoundation`* | `traits: ["ConfigurationSupport"]` where its configuration reader is used (the gateway), `traits: []` elsewhere | `DateEncodingStrategy.formatted(_:)` and `DateDecodingStrategy.formatted(_:)` over a `DateFormatter` in URL-encoded forms; `.iso8601` stays |
| swift-openapi-runtime | `FullFoundation`* | `traits: []` | `ISO8601DateTranscoder(options:)`, and `NSNull` and `NSNumber` in `OpenAPIValueContainer`; `.iso8601` stays |
| swift-configuration | `JSON`*, `YAML`, `PropertyList` | `traits: []`, plus `Reloading` or `CommandLineArguments` when used | The JSON, YAML and property list file providers |
| swift-protobuf | `BinaryDelimitedStreams`* | `traits: []`, plus `FieldMaskUtilities` when a contract uses field masks | Length-delimited message streams |

- Traits unify across the graph: a default trait is off only when every package that declares the dependency turns it off. `<org>-core`, `<org>-protos`, each service and the gateway turn off the same Foundation traits, and so must the libraries they depend on; the versions from which the stack's libraries do are in [the stack](stack.md#full-foundation).
- Other traits in the stack are Foundation-free and keep their defaults: valkey-swift's `ServiceLifecycleSupport` and `DistributedTracingSupport`, swift-temporal-sdk's `GRPCNIOTransport`, swift-http-types' `FoundationURL`.
- A few products link full Foundation and stay out of `dependencies`: `NIOFoundationCompat` (`NIOFoundationEssentialsCompat` instead), `NIOCertificateHelpers` (`NIOCertificateReloading` is Foundation-free), `HTTPTypesFoundation`. `HummingbirdTesting` links it, in test targets only.
- A dependency that still links full Foundation ([the stack](stack.md#full-foundation)) is recorded in the service's README. Owned code stays on `FoundationEssentials`, so the service sheds full Foundation when the dependency does, and CI checks it from then on ([Foundation linking](delivery.md#foundation-linking)).
- Before adding a dependency, list its traits with `swift package show-traits` and read its sources' Foundation imports. A library proves it in CI with the Foundation-linking check ([Foundation linking](delivery.md#foundation-linking)).
- A library's own feature that needs full Foundation goes behind a `FullFoundation` trait, the name hummingbird and swift-openapi-runtime use. It's off by default in a new library, so consumers opt in rather than out.
- A library that moves to the conditional import releases it as a minor version, noting that a consumer relying on the `Foundation` it imported may need its own import.

## Folder layout

```
bookshelf-loans/
├── Package.swift
└── Sources/
    ├── LoansCore/
    │   ├── Loans/
    │   │   ├── Loan.swift, LoanStatus.swift, LoanPolicy.swift
    │   │   ├── Repository/         LoanRepository.swift, LoanRepositoryError.swift, Commands/CreateLoanCommand.swift
    │   │   ├── UseCases/           BorrowBook/, ReturnBook/, ListLoans/, ListAllLoans/, MarkLoanOverdue/, ReceiveNoticeEvent/
    │   │   └── Workflow/           LoanWorkflowClient.swift
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
    ├── LoansTemporal/
    │   ├── Loan/                   LoanWorkflow.swift, LoanActivities.swift, TemporalLoanWorkflowClient.swift
    │   └── ActivityOptions+Loans.swift
    ├── LoansResend/                ResendNoticeSender.swift, ResendNoticeEventVerifier.swift
    └── Loans/
        ├── Loans.swift             the @main command
        ├── Configuration/          InMemoryProvider+ApplicationDefaults.swift, LoanPolicy+ConfigReader.swift
        ├── Database/               Migrations.swift
        ├── Serve/                  Serve.swift
        └── Worker/                 Worker.swift, Run.swift
```

Where each file goes: [folders](conventions.md#folders).

## The organization's core package

```
bookshelf-core/
├── Package.swift
└── Sources/
    ├── BookshelfAuthentication/    UserIdentity.swift, UserRole.swift, OperationContext+User.swift, JWT+EdDSA.swift
    ├── BookshelfPersistence/       PostgresSettings+User.swift, UserSettingsInterceptor.swift,
    │                               UserSettingsMiddleware.swift, PostgresClient.Configuration+ConfigReader.swift
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
- `BookshelfAuthentication` depends on swift-authentication, swift-authentication-jwt, jwt-kit, swift-log and swift-operation-context. `BookshelfPersistence` adds swift-persistence-postgres, grpc-swift-2 for the interceptor, Hummingbird for the middleware (`traits: []`) and swift-configuration; only executables link it, and each already links its transport. `BookshelfTransport` adds grpc-swift-nio-transport, swift-nio-extras and swift-configuration.
- Its API is `public`, with `public import` for every module whose types it exposes.
- It releases with semantic versions; services depend on a release of it, never a branch or `.package(path:)`. A change to it, or to `<org>-protos`, is released and tagged first; each consumer then raises its requirement.

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

SPM enforces what each target declares, but not what a declaration should be. Run these from a service's root, here Loans in Bookshelf; each finds nothing unless noted:

- Core imports no adapter technology: `grep -rlE '^(package |public )?import (GRPC[A-Za-z]*|Hummingbird[A-Za-z]*|PostgresNIO|PersistencePostgres|Temporal|Valkey|Configuration|ServiceLifecycle|SwiftProtobuf|AsyncHTTPClient)$' Sources/*Core`
- Adapters import no sibling adapter. This lists the service's own modules each target imports; an adapter lists only `LoansCore`, and XGRPC its contracts too: `for t in Sources/*/; do echo "$t: $(grep -rhoE '^(package |public )?import Loans[A-Za-z]+' "$t" | sort -u | tr '\n' ' ')"; done`
- Generated contract types stay in XGRPC and the executable: `grep -rlE 'Bookshelf_[A-Za-z]+_V[0-9]+_' Sources | grep -vE '^Sources/(LoansGRPC|Loans)/'`
- Only the executable reads configuration: `grep -rlE '^(package )?import Configuration$' Sources | grep -v '^Sources/Loans/'`
- Every Foundation import is the conditional one; this lists files importing Foundation without it: `grep -rlE '^(package |public )?import Foundation$' Sources | xargs -r grep -L 'canImport(FoundationEssentials)'`
- No unstructured tasks: `grep -rnE 'Task(\.detached)? *\{' Sources`
- Unchecked concurrency only where [concurrency](style.md#concurrency) allows it; this lists each, and every one is in an adapter target with its reason on the line above: `grep -rnE -B1 '@unchecked Sendable|nonisolated\(unsafe\)|@preconcurrency' Sources`
- Every use case protocol has typed throws: `grep -rL 'throws(' Sources/*Core/*/UseCases/*/*UseCaseProtocol.swift`
- No package defaults to the main actor: `grep -n 'defaultIsolation' Package.swift`
