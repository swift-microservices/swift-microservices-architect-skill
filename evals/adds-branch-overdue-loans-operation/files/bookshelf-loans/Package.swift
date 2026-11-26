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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.2"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.5.0", traits: []),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.31.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.33.3", traits: []),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.2.1"),
        .package(url: "https://github.com/grpc/grpc-swift-extras.git", from: "2.1.1"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.4.0"),
        .package(url: "https://github.com/hummingbird-project/postgres-migrations.git", from: "1.1.0"),
        .package(url: "https://github.com/swift-microservices/swift-authentication.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-microservices/swift-authentication-grpc.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-microservices/swift-authentication-jwt.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-microservices/swift-operation-context.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-microservices/swift-persistence.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-microservices/swift-persistence-postgres.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.0.4", traits: ["OTLPGRPC"]),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.9.1"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.29.0"),
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
                .product(name: "GRPCCore", package: "grpc-swift-2"),
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
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCHealthService", package: "grpc-swift-extras"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCOTelTracingInterceptors", package: "grpc-swift-extras"),
                .product(name: "GRPCServiceLifecycle", package: "grpc-swift-extras"),
                .product(name: "LoansProtos", package: "bookshelf-protos"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCertificateReloading", package: "swift-nio-extras"),
                .product(name: "OTel", package: "swift-otel"),
                .product(name: "PersistencePostgres", package: "swift-persistence-postgres"),
                .product(name: "PostgresMigrations", package: "postgres-migrations"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "UnixSignals", package: "swift-service-lifecycle"),
            ],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
