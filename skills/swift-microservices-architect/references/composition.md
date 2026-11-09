# Composition

The executable target: its commands, the composition root each command runs, configuration, logging, and the lifecycle that runs everything.

## Contents
- Commands
- The composition root
- Configuration
- Logging
- Lifecycle
- The worker's root
- The gateway's root

## Commands

```swift
import ArgumentParser

@main
struct Loans: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "loans",
        abstract: "The Bookshelf loans service",
        subcommands: [
            Serve.self,
            Worker.self,
        ],
        defaultSubcommand: Serve.self
    )
}
```

- One executable per service, its command named for the service in lowercase. `serve` is the default subcommand.
- `serve --migrate-database` applies pending migrations and sets the roles' passwords as the owner, then serves, in one process only ([migrations](persistence.md#migrations)). Without the flag it never reads the owner's credentials.
- A service with workflows adds the group `worker`, whose default subcommand `run` starts the Temporal worker: `loans worker run`. The serve process and the worker are separate processes from one image.
- An operation that must never be reachable over the network, such as a repair, a backfill or a one-off export, is a short-lived subcommand of the executable, never an administrators' RPC.
- Each command's `run()` is a composition root: the only code that reads configuration, constructs concrete types and runs them. Nothing below it reads configuration, builds a client or starts a task.

## The composition root

`Serve/Serve.swift`, in sections marked in this order:

```swift
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Serve the loans gRPC services"
    )

    @Flag(help: "Apply pending database migrations before serving")
    var migrateDatabase = false

    func run() async throws {
        // MARK: - Configuration
        let config = ConfigReader(providers: [
            EnvironmentVariablesProvider(),
            InMemoryProvider.applicationDefaults,
        ])

        // MARK: - Logging
        let logLevel = config.string(forKey: "logLevel", default: Logger.Level.info)
        LoggingSystem.bootstrap(
            { label, metadataProvider in
                var handler = StreamLogHandler.standardOutput(label: label, metadataProvider: metadataProvider)
                handler.logLevel = logLevel
                return handler
            },
            metadataProvider: .user
        )
        let logger = Logger(label: "bookshelf-loans")

        // MARK: - Infrastructure
        let postgresConfig = config.scoped(to: "postgres")
        if migrateDatabase {
            let ownerPostgresConfiguration = try PostgresClient.Configuration(config: postgresConfig, role: "owner")
            try await PostgresClient.withClient(configuration: ownerPostgresConfiguration, logger: logger) { client in
                let migrations = Migrations(client: client, …, logger: logger)
                try await migrations.apply()
            }
        }
        let servicePostgresConfiguration = try PostgresClient.Configuration(config: postgresConfig, role: "service")
        let internalPostgresConfiguration = try PostgresClient.Configuration(config: postgresConfig, role: "internal")
        let postgresClient = PostgresClient(configuration: servicePostgresConfiguration, backgroundLogger: logger)
        let internalPostgresClient = PostgresClient(configuration: internalPostgresConfiguration, backgroundLogger: logger)

        let tlsConfig = config.scoped(to: "tls")
        let certificateReloaderConfiguration = try TimedCertificateReloader.Configuration(config: tlsConfig, logger: logger)
        let certificateReloader = try TimedCertificateReloader.makeReloaderValidatingSources(configuration: certificateReloaderConfiguration)
        let clientSecurity: HTTP2ClientTransport.Posix.TransportSecurity = try .mTLS(config: tlsConfig, certificateReloader: certificateReloader)

        let jwtConfig = config.scoped(to: "jwt")
        let authenticator = try await JWTAuthenticator<UserIdentity>(config: jwtConfig)

        let catalogConfig = config.scoped(to: "grpc.catalog")
        let catalogHost = try catalogConfig.requiredString(forKey: "host")
        let catalogPort = try catalogConfig.requiredInt(forKey: "port")
        let catalogTransportConfig = HTTP2ClientTransport.Posix.Config(config: catalogConfig)
        let catalogServiceConfig = ServiceConfig(config: catalogConfig)
        let catalogTransport = try HTTP2ClientTransport.Posix(
            target: .dns(host: catalogHost, port: catalogPort),
            transportSecurity: clientSecurity,
            config: catalogTransportConfig,
            serviceConfig: catalogServiceConfig
        )
        let catalogGRPCClient = GRPCClient(transport: catalogTransport)

        let temporalConfig = config.scoped(to: "temporal")
        let temporalTLSConfig = temporalConfig.scoped(to: "tls")
        let temporalHost = try temporalConfig.requiredString(forKey: "host")
        let temporalPort = try temporalConfig.requiredInt(forKey: "port")
        let temporalCertificateReloaderConfiguration = try TimedCertificateReloader.Configuration(config: temporalTLSConfig, logger: logger)
        let temporalCertificateReloader = try TimedCertificateReloader.makeReloaderValidatingSources(configuration: temporalCertificateReloaderConfiguration)
        let temporalSecurity: HTTP2ClientTransport.Posix.TransportSecurity = try .mTLS(config: temporalTLSConfig, certificateReloader: temporalCertificateReloader)
        let temporalClientConfiguration = try TemporalClient.Configuration(configReader: temporalConfig)
        let temporalClient = try TemporalClient(
            target: .dns(host: temporalHost, port: temporalPort),
            transportSecurity: temporalSecurity,
            configuration: temporalClientConfiguration
        )

        // MARK: - Composition
        // The caller's own loans run on the tenant database, where the policy confines each
        // transaction to the caller; administrators' reads, and Resend's events, which bind no
        // caller, run on the internal one.
        let database = PostgresDatabase<PostgresLoansScope>(client: postgresClient, logger: logger)
        let internalDatabase = PostgresDatabase<PostgresLoansInternalScope>(client: internalPostgresClient, logger: logger)
        let catalogClient = GRPCCatalogClient(client: catalogGRPCClient)
        let taskQueue = try temporalConfig.requiredString(forKey: "worker.taskqueue")
        let loansConfig = config.scoped(to: "loans")
        let policy = try LoanPolicy(config: loansConfig)
        let resendConfig = config.scoped(to: "resend")
        let noticeEventVerifier = try ResendNoticeEventVerifier(config: resendConfig)

        let receiveNoticeEventUseCase = ReceiveNoticeEventUseCase(
            database: internalDatabase,
            noticeEventVerifier: noticeEventVerifier,
            logger: logger
        )
        let borrowBookUseCase = BorrowBookUseCase(
            database: database,
            catalogClient: catalogClient,
            temporalClient: temporalClient,
            taskQueue: taskQueue,
            policy: policy,
            logger: logger
        )
        let returnBookUseCase = ReturnBookUseCase(database: database, logger: logger)
        let listLoansUseCase = ListLoansUseCase(database: database, logger: logger)
        let listAllLoansUseCase = ListAllLoansUseCase(database: internalDatabase, logger: logger)
        let loanService = LoanService(
            receiveNoticeEventUseCase: receiveNoticeEventUseCase,
            borrowBookUseCase: borrowBookUseCase,
            returnBookUseCase: returnBookUseCase,
            listLoansUseCase: listLoansUseCase,
            listAllLoansUseCase: listAllLoansUseCase
        )

        // MARK: - gRPC
        let serverConfig = config.scoped(to: "grpc.server")
        let serverHost = try serverConfig.requiredString(forKey: "host")
        let serverPort = try serverConfig.requiredInt(forKey: "port")
        let serverSecurity: HTTP2ServerTransport.Posix.TransportSecurity = try .mTLS(config: tlsConfig, certificateReloader: certificateReloader)
        let serverTransportConfig = HTTP2ServerTransport.Posix.Config(config: serverConfig)
        let serverTransport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: serverHost, port: serverPort),
            transportSecurity: serverSecurity,
            config: serverTransportConfig
        )
        let bearerAuthentication = BearerAuthenticationInterceptor(authenticator: authenticator)
        let userSettings = UserSettingsInterceptor()
        let server = GRPCServer(
            transport: serverTransport,
            services: [loanService],
            interceptorPipeline: [
                .apply(bearerAuthentication, to: .services([Bookshelf_Loans_V1_LoanService.descriptor])),
                .apply(userSettings, to: .services([Bookshelf_Loans_V1_LoanService.descriptor])),
            ]
        )

        // MARK: - Lifecycle
        let serviceGroup = ServiceGroup(
            services: [
                postgresClient,
                internalPostgresClient,
                certificateReloader,
                temporalCertificateReloader,
                catalogGRPCClient,
                temporalClient,
                server,
            ],
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: logger
        )
        try await withLogger(logger) { _ in
            try await serviceGroup.run()
        }
    }
}
```

- **Configuration, Logging, Infrastructure, Composition, the server, Lifecycle**: every root has these sections, in this order.
- Infrastructure builds what talks to the outside: database clients per role, certificate reloaders, the authenticator, upstream clients, the Temporal and Valkey clients.
- Composition builds the application from them: a `PostgresDatabase` per role, adapters for Core's ports, use cases, and the services that hold them. A comment says which database each audience's use cases run on, since that choice is the authorization design.
- The use cases that start workflows take what [starting a workflow](workflows.md#starting-a-workflow-from-a-use-case) names.
- Each use case is a `let` named like the property that holds it, on the database its audience requires; the service then takes the names. Every value in a root is built this way ([build, then call](style.md#build-then-call)).

## Configuration

swift-configuration reads every value through one `ConfigReader`, built first in each root:

- Providers in order: `EnvironmentVariablesProvider()` first, then `InMemoryProvider.applicationDefaults`. A value a command also takes as an option goes into an `InMemoryProvider` of the parsed options at the front.
- `Configuration/InMemoryProvider+ApplicationDefaults.swift` holds the deployment's layout, which environment variables override key by key:

```swift
import Configuration

extension InMemoryProvider {
    static var applicationDefaults: Self {
        .init(values: [
            "grpc.server.host": "0.0.0.0",
            "grpc.server.port": 50051,
            "tls.certificatePath": "/run/tls/cert.pem",
            "tls.privateKeyPath": "/run/tls/key.pem",
            "tls.trustRootsPath": "/run/tls/ca.pem",
            "jwt.publicKeysPath": "/run/secrets/jwt-public",
            "postgres.db": "bookshelf_loans",
            "postgres.tls.trustRootsPath": "/run/tls/ca.pem",
            "postgres.service.user": "loans_service",
            "postgres.internal.user": "loans_internal",
            "postgres.worker.user": "loans_worker",
            "temporal.tls.certificatePath": "/run/temporal-tls/cert.pem",
            "temporal.tls.privateKeyPath": "/run/temporal-tls/key.pem",
            "temporal.tls.trustRootsPath": "/run/temporal-tls/ca.pem",
            "temporal.port": 7233,
            "temporal.client.namespace": "bookshelf",
            "temporal.worker.namespace": "bookshelf",
            "temporal.worker.taskqueue": "loans",
            "loans.maximumActiveLoans": 5,
            "loans.loanPeriodDays": 21,
        ])
    }
}
```

- Defaults hold mount paths, ports, the database's name, role names, the Temporal namespace, task queues and policies' standard values. Never a secret, and never a host of another system: those are required, so a missing one fails at startup with the key's name.
- A type is read by a reader, `Type+ConfigReader.swift`, an `init(config: ConfigReader)` over relative keys, which its caller scopes first: `let tlsConfig = config.scoped(to: "tls")`, then `TimedCertificateReloader.Configuration(config: tlsConfig, logger: logger)`. Required keys and validation live in the reader, not in the root.
- A read with a default also returns the default when the supplied value is malformed. A setting that governs security or a business rule (`LoanPolicy`) uses a throwing read, with its standard value in the defaults, so a bad override fails startup.
- Readers every executable shares are `<Org>Transport`'s and `<Org>Persistence`'s; a service's own, for its policies and provider clients, are in its `Configuration/`. A library's native reader comes first: `ApplicationConfiguration(reader:)`, `TemporalClient.Configuration(configReader:)`, `TemporalWorker.Configuration(configReader:)`, `ValkeyClientConfiguration(configReader:)` ([with TLS set on it](persistence.md#valkey)), with the key names that library chose.
- Keys are named as [naming](conventions.md#naming) gives them, and environment names derive from them: `postgres.service.password` is `POSTGRES_SERVICE_PASSWORD`, `tls.refreshIntervalSeconds` is `TLS_REFRESH_INTERVAL_SECONDS`.
- A duration's key names its unit and reads as a `Duration`: `config.int(forKey: "refreshIntervalSeconds", as: Duration.self, default: .seconds(60))`.
- Secrets and key material follow [secrets](security.md#secrets).
- A reader's doc comment lists its keys, their types, defaults and whether they're secret.

## Logging

- `LoggingSystem.bootstrap` runs once, first after configuration, with `metadataProvider: .user` from `<Org>Authentication` ([user tokens](security.md#user-tokens)).
- The level comes from `logLevel`, defaulting to `info`; the label is as [naming](conventions.md#naming) gives it.
- The root's `logger` is passed to every client, database, use case and server that takes one, and bound around the group's run with `withLogger(logger)` for the libraries that log through `Logger.current`, such as swift-temporal-sdk. Nothing creates a logger of its own.

## Lifecycle

A root lists its long-lived components in one `ServiceGroup` and nothing else: no detached tasks, shutdown calls, `defer` blocks or ordering code.

- Every owned component with a `run()` is in the root's one `ServiceGroup`: `PostgresClient`, `ValkeyClient`, `GRPCClient` and `GRPCServer` (through `GRPCServiceLifecycle`), Hummingbird's `Application`, `TimedCertificateReloader`, `TemporalClient`, `TemporalWorker`.
- Order is dependency order: database clients, certificate reloaders, upstream and store clients, the Temporal client, and the server, application or worker last, so it drains before the clients it uses close.
- `gracefulShutdownSignals: [.sigterm, .sigint]`, from `UnixSignals`. Running the group is the root's last line.
- A process-wide singleton a library owns, such as `HTTPClient.shared` or `NIOThreadPool.singleton`, is borrowed and never shut down, and noted as such.
- A long-running component of the service's own is a `Service` whose `run()` returns on graceful shutdown: its loop iterates `sequence.cancelOnGracefulShutdown()`, or wraps its work in `withGracefulShutdownHandler`.

## The worker's root

`Worker/Run.swift` follows the same sections, with the worker's own infrastructure:

```swift
// MARK: - Infrastructure
let workerPostgresConfiguration = try PostgresClient.Configuration(config: postgresConfig, role: "worker")
let workerPostgresClient = PostgresClient(configuration: workerPostgresConfiguration, backgroundLogger: logger)
…  // tls, temporal and each client's transport, as in Serve
let identityGRPCClient = GRPCClient(transport: identityTransport)
let catalogGRPCClient = GRPCClient(transport: catalogTransport)

// MARK: - Composition
let workerDatabase = PostgresDatabase<PostgresLoansWorkerScope>(client: workerPostgresClient, logger: logger)
let markLoanOverdueUseCase = MarkLoanOverdueUseCase(database: workerDatabase, logger: logger)
let identityClient = GRPCIdentityClient(client: identityGRPCClient)
let catalogClient = GRPCCatalogClient(client: catalogGRPCClient)
let noticeSender = ResendNoticeSender(…)
let loanActivities = LoanActivities(
    markLoanOverdueUseCase: markLoanOverdueUseCase,
    identityClient: identityClient,
    catalogClient: catalogClient,
    noticeSender: noticeSender
)

// MARK: - Worker
let workerConfiguration = try TemporalWorker.Configuration(configReader: temporalConfig)
let worker = try TemporalWorker(
    configuration: workerConfiguration,
    target: .dns(host: temporalHost, port: temporalPort),
    transportSecurity: temporalSecurity,
    activityContainers: loanActivities,
    workflows: [LoanWorkflow.self]
)

// MARK: - Lifecycle
// workerPostgresClient, certificateReloader, temporalCertificateReloader, identityGRPCClient, catalogGRPCClient, worker
```

- The root builds each activity container from system use cases and port implementations, here XGRPC's and the provider target's, so no adapter target imports another, and registers the workflows. `activityContainers:` takes each container as its own argument.
- The worker builds no server and no authenticator: it serves no RPCs, and the users it acts for are named in workflow inputs.

## The gateway's root

`Gateway/Serve/Serve.swift`:

```swift
// MARK: - Infrastructure
let jwtConfig = config.scoped(to: "jwt")
let authenticator = try await JWTAuthenticator<UserIdentity>(config: jwtConfig)
let propagation = BearerPropagationInterceptor<UserIdentity>()
…  // each upstream's transport, as in a service's Serve
let loansGRPCClient = GRPCClient(
    transport: loansTransport,
    interceptorPipeline: [.apply(propagation, to: .services([Bookshelf_Loans_V1_LoanService.descriptor]))]
)
…  // identityGRPCClient and catalogGRPCClient the same way

// MARK: - Composition
let identityClient = Bookshelf_Identity_V1_IdentityService.Client(wrapping: identityGRPCClient)
let bookClient = Bookshelf_Catalog_V1_BookService.Client(wrapping: catalogGRPCClient)
let loanClient = Bookshelf_Loans_V1_LoanService.Client(wrapping: loansGRPCClient)
let api = BookshelfAPI(
    authenticator: authenticator,
    identityClient: identityClient,
    bookClient: bookClient,
    loanClient: loanClient
)

// MARK: - Router
let cors = CORSMiddleware<BasicRequestContext>(allowOrigin: .originBased, allowHeaders: [.contentType, .authorization], allowMethods: [.get, .post, .put, .delete])
let requestLogging = LogRequestsMiddleware<BasicRequestContext>(logLevel)
let router = Router(context: BasicRequestContext.self)
router.add(middleware: cors)
router.add(middleware: ErrorMiddleware())
router.add(middleware: requestLogging)
api.addRoutes(to: router.group("v1"))

// MARK: - Hummingbird
let httpServerConfig = config.scoped(to: "http.server")
let applicationConfiguration = ApplicationConfiguration(reader: httpServerConfig)
let application = Application(router: router, configuration: applicationConfiguration, logger: logger)

// MARK: - Lifecycle
// certificateReloader, every upstream client, application
```

The gateway's defaults hold `http.server.host` and `http.server.port`; Hummingbird's configuration reader comes from its `ConfigurationSupport` trait.
