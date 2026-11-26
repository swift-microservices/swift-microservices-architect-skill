// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "bookshelf-loans",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "loans", targets: ["Loans"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.8.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.26.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.1.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/bookshelf/bookshelf-core.git", from: "1.0.0"),
        .package(url: "https://github.com/bookshelf/bookshelf-protos.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "LoansCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "BookshelfAuthentication", package: "bookshelf-core"),
            ]
        ),
        .target(
            name: "LoansPostgres",
            dependencies: [
                "LoansCore",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        .target(
            name: "LoansGRPC",
            dependencies: [
                "LoansCore",
                "LoansPostgres",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "LoansProtos", package: "bookshelf-protos"),
                .product(name: "Configuration", package: "swift-configuration"),
            ]
        ),
        .executableTarget(
            name: "Loans",
            dependencies: [
                "LoansCore", "LoansPostgres", "LoansGRPC",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Configuration", package: "swift-configuration"),
            ]
        ),
    ]
)
