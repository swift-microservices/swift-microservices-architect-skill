# Composition

The executable target: its commands, the composition root each command runs, configuration, logging, and the lifecycle that runs everything.

## Contents
- Commands
- The composition root
- Configuration
- Logging
- Lifecycle
- Health
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
            Health.self,
        ],
        defaultSubcommand: Serve.self
    )
}
```

- One executable per service, its command named for the service in lowercase. `serve` is the default subcommand.
- `serve --migrate-database` applies pending migrations as the owner, proved by the migrator's certificate, then serves, in one process only ([migrations](persistence.md#migrations)). Without the flag it never reads the owner's credentials.
- A service with workflows adds the group `worker`, whose default subcommand `run` starts the Temporal worker: `loans worker run`. The serve process and the worker are separate processes from one image.
- An operation that must never be reachable over the network, such as a repair, a backfill or a one-off export, is a short-lived command, a subcommand of the executable, never an administrators' RPC. It lives in `Sources/X/<Command>/<Command>.swift`, and its `run()` has the Configuration, Logging, Infrastructure and Composition sections, no Observability and no `ServiceGroup`: it opens its client with `PostgresClient.withClient(configuration:logger:operation:)`, as migrations do, runs its use case inside, and returns.
- A short-lived command's operands, such as whom it acts on, are its `@Option`s and go into the use case's input; only a value configuration also carries goes through the provider. It reports through its log line and exit status, and prints to standard output only a value the operator must read.
- A short-lived command connects as `<x>_internal`, since no caller is bound, and reads a secret it needs through the `ConfigReader` with `isSecret: true`, never from a flag, which the process list shows.
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
        let secrets = try await DirectoryFilesProvider(directoryPath: "/run/secrets", allowMissing: true)
        let config = ConfigReader(providers: [
            EnvironmentVariablesProvider(),
            secrets,
            InMemoryProvider.applicationDefaults,
        ])

        // MARK: - Logging
        let logLevel = config.string(forKey: "logLevel", default: Logger.Level.info)
        let traceMetadataProvider = OTel.makeLoggingMetadataProvider()
        let metadataProvider = Logger.MetadataProvider.multiplex([.user, traceMetadataProvider])
        LoggingSystem.bootstrap(
            { label, metadataProvider in
                var handler = StreamLogHandler.standardOutput(label: label, metadataProvider: metadataProvider)
                handler.logLevel = logLevel
                return handler
            },
            metadataProvider: metadataProvider
        )
        let logger = Logger(label: "bookshelf-loans")

        // MARK: - Observability
        var otelConfiguration = OTel.Configuration.default
        otelConfiguration.serviceName = "bookshelf-loans"
        otelConfiguration.logs.enabled = false
        let observability = try OTel.bootstrap(configuration: otelConfiguration)

        // MARK: - Infrastructure
        let tlsConfig = config.scoped(to: "tls")
        let certificateReloaderConfiguration = try TimedCertificateReloader.Configuration(
            config: tlsConfig,
            logger: logger
        )
        let certificateReloader = try TimedCertificateReloader.makeReloaderValidatingSources(
            configuration: certificateReloaderConfiguration
        )
        let clientSecurity: HTTP2ClientTransport.Posix.TransportSecurity = try .mTLS(
            config: tlsConfig,
            certificateReloader: certificateReloader
        )

        let postgresConfig = config.scoped(to: "postgres")
        if migrateDatabase {
            let migratorTLSConfig = postgresConfig.scoped(to: "owner.tls")
            let migratorCertificateReloaderConfiguration = try TimedCertificateReloader.Configuration(
                config: migratorTLSConfig,
                logger: logger
            )
            let migratorCertificateReloader = try TimedCertificateReloader.makeReloaderValidatingSources(
                configuration: migratorCertificateReloaderConfiguration
            )
            let ownerPostgresConfiguration = try PostgresClient.Configuration(
                config: postgresConfig,
                role: "owner",
                certificateReloader: migratorCertificateReloader
            )
            try await PostgresClient.withClient(configuration: ownerPostgresConfiguration, logger: logger) { client in
                let migrations = Migrations(client: client, …, logger: logger)
                try await migrations.apply()
            }
        }
        let servicePostgresConfiguration = try PostgresClient.Configuration(
            config: postgresConfig,
            role: "service",
            certificateReloader: certificateReloader
        )
        let internalPostgresConfiguration = try PostgresClient.Configuration(
            config: postgresConfig,
            role: "internal",
            certificateReloader: certificateReloader
        )
        let postgresClient = PostgresClient(configuration: servicePostgresConfiguration, backgroundLogger: logger)
        let internalPostgresClient = PostgresClient(
            configuration: internalPostgresConfiguration,
            backgroundLogger: logger
        )

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
        let catalogTracing = ClientOTelTracingInterceptor(serverHostname: catalogHost, networkTransportMethod: "tcp")
        let catalogGRPCClient = GRPCClient(
            transport: catalogTransport,
            interceptorPipeline: [.apply(catalogTracing, to: .all)]
        )

        let temporalConfig = config.scoped(to: "temporal")
        let temporalTLSConfig = temporalConfig.scoped(to: "tls")
        let temporalHost = try temporalConfig.requiredString(forKey: "host")
        let temporalPort = try temporalConfig.requiredInt(forKey: "port")
        let temporalCertificateReloaderConfiguration = try TimedCertificateReloader.Configuration(
            config: temporalTLSConfig,
            logger: logger
        )
        let temporalCertificateReloader = try TimedCertificateReloader.makeReloaderValidatingSources(
            configuration: temporalCertificateReloaderConfiguration
        )
        let temporalSecurity: HTTP2ClientTransport.Posix.TransportSecurity = try .mTLS(
            config: temporalTLSConfig,
            certificateReloader: temporalCertificateReloader
        )
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
        let internalDatabase = PostgresDatabase<PostgresLoansInternalScope>(
            client: internalPostgresClient,
            logger: logger
        )
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
        let serverHostname = try serverConfig.requiredString(forKey: "hostname")
        let serverSecurity: HTTP2ServerTransport.Posix.TransportSecurity = try .mTLS(
            config: tlsConfig,
            certificateReloader: certificateReloader
        )
        let serverTransportConfig = HTTP2ServerTransport.Posix.Config(config: serverConfig)
        let serverTransport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: serverHost, port: serverPort),
            transportSecurity: serverSecurity,
            config: serverTransportConfig
        )
        let serverTracing = ServerOTelTracingInterceptor(serverHostname: serverHostname, networkTransportMethod: "tcp")
        let bearerAuthentication = BearerAuthenticationInterceptor(authenticator: authenticator)
        let userSettings = UserSettingsInterceptor()
        let healthService = HealthService()
        healthService.provider.updateStatus(.serving, forService: "")
        let server = GRPCServer(
            transport: serverTransport,
            services: [loanService, healthService],
            interceptorPipeline: [
                .apply(serverTracing, to: .services([Bookshelf_Loans_V1_LoanService.descriptor])),
                .apply(bearerAuthentication, to: .services([Bookshelf_Loans_V1_LoanService.descriptor])),
                .apply(userSettings, to: .services([Bookshelf_Loans_V1_LoanService.descriptor])),
            ]
        )

        // MARK: - Lifecycle
        let serviceGroup = ServiceGroup(
            services: [
                observability,
                certificateReloader,
                temporalCertificateReloader,
                postgresClient,
                internalPostgresClient,
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

- **Configuration, Logging, Observability, Infrastructure, Composition, the server, Lifecycle**: every long-running root has these sections, in this order ([observability](observability.md)), and a short-lived command has Configuration, Logging, Infrastructure and Composition ([commands](#commands)).
- Infrastructure builds what talks to the outside: certificate reloaders, database clients per role, the authenticator, upstream clients, the Temporal and Valkey clients.
- Composition builds the application from them: a `PostgresDatabase` per role, adapters for Core's ports, use cases, and the services that hold them. A comment says which database each audience's use cases run on, since that choice is the authorization design.
- The use cases that start workflows take what [starting a workflow](workflows.md#starting-a-workflow-from-a-use-case) names.
- Each use case is a `let` named like the property that holds it, on the database its audience requires; the service then takes the names. Every value in a root is built this way ([build, then call](style.md#build-then-call)).

## Configuration

swift-configuration reads every value through one `ConfigReader`, built first in each root, except the OpenTelemetry variables swift-otel reads itself ([observability](observability.md#the-bootstrap)):

- Providers in order: `EnvironmentVariablesProvider()`, then `DirectoryFilesProvider` over `/run/secrets` for secrets ([secrets](security.md#secrets)), then `InMemoryProvider.applicationDefaults`. A value a command also takes as an option goes into an `InMemoryProvider` of the parsed options at the front.
- `Configuration/InMemoryProvider+ApplicationDefaults.swift` holds the deployment's layout, which environment variables override key by key:

```swift
import Configuration

extension InMemoryProvider {
    static var applicationDefaults: Self {
        .init(values: [
            "grpc.server.host": "0.0.0.0",
            "grpc.server.port": 50051,
            "grpc.server.hostname": "loans",
            "grpc.catalog.port": 50051,
            "tls.certificatePath": "/run/tls/cert.pem",
            "tls.privateKeyPath": "/run/tls/key.pem",
            "tls.trustRootsPath": "/run/tls/ca.pem",
            "jwt.publicKeysPath": "/run/secrets/jwt-public",
            "postgres.port": 5432,
            "postgres.db": "bookshelf_loans",
            "postgres.tls.trustRootsPath": "/run/tls/ca.pem",
            "postgres.owner.user": "loans_owner",
            "postgres.owner.tls.certificatePath": "/run/postgres-owner-tls/cert.pem",
            "postgres.owner.tls.privateKeyPath": "/run/postgres-owner-tls/key.pem",
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
            "temporal.worker.gracefulShutdownPeriodSeconds": 30,
            "loans.maximumActiveLoans": 5,
            "loans.loanPeriodDays": 21,
        ])
    }
}
```

- Defaults hold mount paths, ports, an upstream's included, the database's name, role names, the Temporal namespace, task queues and policies' standard values. Never a secret, and never a host of another system: those are required, so a missing one fails at startup with the key's name.
- A type is read by a reader, `Type+ConfigReader.swift`, an `init(config: ConfigReader)` over relative keys, which its caller scopes first: `let tlsConfig = config.scoped(to: "tls")`, then `TimedCertificateReloader.Configuration(config: tlsConfig, logger: logger)`. Required keys and validation live in the reader, not in the root.
- A read with a default also returns the default when the supplied value is malformed. A setting that governs security or a business rule (`LoanPolicy`) uses a throwing read, with its standard value in the defaults, so a bad override fails startup.
- A library's native reader comes first: `ApplicationConfiguration(reader:)`, `TemporalClient.Configuration(configReader:)`, `TemporalWorker.Configuration(configReader:)`, `ValkeyClientConfiguration(configReader:)` ([with TLS set on it](persistence.md#valkey)), with the key names that library chose. A service's own readers are in the executable's `Configuration/`: its policies' (`LoanPolicy+ConfigReader.swift`), and its provider clients', as extensions on the provider target's types (`ResendNoticeEventVerifier+ConfigReader.swift`), since a provider target never reads configuration.
- Readers every executable shares are `<Project>Transport`'s and `<Project>Persistence`'s, under these keys, relative to the scopes the roots give them:

| Reader | Scopes | Keys, with tuning defaults |
|---|---|---|
| `TimedCertificateReloader.Configuration(config:logger:)` | `tls`, `temporal.tls`, `postgres.owner.tls` | `certificatePath`, `privateKeyPath`; `refreshIntervalSeconds` (60) |
| The server's and the client's `TransportSecurity.mTLS(config:certificateReloader:)` | `tls`, `temporal.tls` | `trustRootsPath` |
| `HTTP2ServerTransport.Posix.Config(config:)` | `grpc.server` | `maxConnectionAgeSeconds` (1800), `connectionGraceTimeSeconds` (30), `minPingIntervalSeconds` (10) |
| `HTTP2ClientTransport.Posix.Config(config:)`, `ServiceConfig(config:)` | `grpc.<upstream>` | `keepaliveTimeSeconds` (30), `keepaliveTimeoutSeconds` (10); `deadlineSeconds` (10) |
| `InternalCallerInterceptor(config:)` | `grpc.server` | `internalCallers`, the common names of the processes that call `XInternalService` |
| `JWTAuthenticator<UserIdentity>(config:)`, Identity's `JWTIssuer<UserIdentity>(config:)` | `jwt` | `publicKeysPath`, a directory of PEM files; `privateKeyPath` |
| `PostgresClient.Configuration(config:role:certificateReloader:)` | `postgres` | `host`, `port`, `db`, `tls.trustRootsPath`, `<role>.user`; `<role>.maximumConnections` (10), `statementTimeoutSeconds` (5), `idleInTransactionTimeoutSeconds` (10), `lockTimeoutSeconds` (5) ([connections and timeouts](persistence.md#connections-and-timeouts)); the password fallback's `(config:role:)` adds `<role>.password`, a secret (the file `postgres-service-password`) |

- A `<project>-core` reader requires every value a deployment sets, such as a path, host, port or user, and defaults only tuning; the executable's defaults hold the deployment's values.
- Keys are named as [naming](conventions.md#naming) gives them, and environment and secret file names derive from them: `postgres.service.user` is `POSTGRES_SERVICE_USER`, `tls.refreshIntervalSeconds` is `TLS_REFRESH_INTERVAL_SECONDS`, and the secret `postgres.service.password` is the file `postgres-service-password`.
- A duration's key names its unit and reads as a `Duration`: `config.int(forKey: "refreshIntervalSeconds", as: Duration.self, default: .seconds(60))`.
- Secrets and key material follow [secrets](security.md#secrets).
- A reader's doc comment lists its keys, their types, defaults and whether they're secret.

## Logging

- `LoggingSystem.bootstrap` runs once, first after configuration, with a metadata provider that multiplexes `.user` from `<Project>Authentication` ([user tokens](security.md#user-tokens)) and swift-otel's, which adds the trace and span ids.
- The level comes from `logLevel`, defaulting to `info`; the label is as [naming](conventions.md#naming) gives it.
- The root's `logger` is passed to every client, database, use case and server that takes one, and bound around the group's run with `withLogger(logger)` for the libraries that log through `Logger.current`, such as swift-temporal-sdk. Nothing creates a logger of its own.

## Lifecycle

A root lists its long-lived components in one `ServiceGroup` and nothing else: no detached tasks, shutdown calls, `defer` blocks or ordering code.

- Every owned component with a `run()` is in the root's one `ServiceGroup`: `PostgresClient`, `ValkeyClient`, `GRPCClient` and `GRPCServer` (through `GRPCServiceLifecycle`), Hummingbird's `Application`, `TimedCertificateReloader`, `TemporalClient`, `TemporalWorker`.
- Order is dependency order: the observability service first, so it flushes last, then certificate reloaders, database clients, upstream and store clients, the Temporal client, and the server, application or worker last, so it drains before the clients it uses close.
- `gracefulShutdownSignals: [.sigterm, .sigint]`, from `UnixSignals`. Running the group is the root's last line.
- A process-wide singleton a library owns, such as `HTTPClient.shared` or `NIOThreadPool.singleton`, is borrowed and never shut down, and noted as such.
- A long-running component of the service's own is a `Service` whose `run()` returns on graceful shutdown: its loop iterates `sequence.cancelOnGracefulShutdown()`, or wraps its work in `withGracefulShutdownHandler`.

## Health

Each serve process reports its health over gRPC, and the gateway over HTTP, so the deployment sends traffic only to a process that's up:

- Serve registers grpc-swift-extras' `HealthService` beside its services and marks the server serving before the group runs, as [the composition root](#the-composition-root) shows. No interceptor applies to its descriptor, so a probe needs no token.
- The gateway answers `GET /health` with `200 OK`, outside `/v1` and every tier ([the gateway's root](#the-gateways-root)).
- Health reports the process, never its dependencies: a status that followed Postgres or an upstream would mark every replica unhealthy when one dependency fails, and the platform would restart them all at once.
- The image holds no probe tool, so each executable has a short-lived `health` command ([commands](#commands)), which the deployment runs as the health check of every serve application and of the gateway. A service's dials its own server on `127.0.0.1` with its own certificate pair, the client config's HTTP/2 `authority` set to its certificate's name from `grpc.server.hostname`, calls `Check`, and exits non-zero unless the status is `SERVING`. The gateway's sends `GET /health` with AsyncHTTPClient.
- The worker serves nothing and has no health check; Temporal shows whether it polls.

## The worker's root

`Worker/Run.swift` follows the same sections, with the worker's own infrastructure:

```swift
// MARK: - Infrastructure
…  // tls, temporal, and each upstream's transport and traced GRPCClient, as in Serve
let workerPostgresConfiguration = try PostgresClient.Configuration(
    config: postgresConfig,
    role: "worker",
    certificateReloader: certificateReloader
)
let workerPostgresClient = PostgresClient(configuration: workerPostgresConfiguration, backgroundLogger: logger)

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
var workerConfiguration = try TemporalWorker.Configuration(configReader: temporalConfig)
workerConfiguration.gracefulShutdownPeriod = try temporalConfig.requiredInt(
    forKey: "worker.gracefulShutdownPeriodSeconds",
    as: Duration.self
)
let worker = try TemporalWorker(
    configuration: workerConfiguration,
    target: .dns(host: temporalHost, port: temporalPort),
    transportSecurity: temporalSecurity,
    activityContainers: loanActivities,
    workflows: [LoanWorkflow.self]
)

// MARK: - Lifecycle
// observability, certificateReloader, temporalCertificateReloader, workerPostgresClient,
// identityGRPCClient, catalogGRPCClient, worker
```

- The root builds each activity container from system use cases and port implementations, here XGRPC's and the provider target's, so no adapter target imports another, and registers the workflows. `activityContainers:` takes each container as its own argument.
- The SDK's reader leaves `gracefulShutdownPeriod` at zero, which cancels in-flight activities at every deploy and retries them, repeating their effects. The root sets it from `temporal.worker.gracefulShutdownPeriodSeconds`, defaulting to the longest activity's `startToCloseTimeout` (30), and the deployment's stop timeout exceeds it.
- Before its `ServiceGroup`, it applies the service's schedules over a short-lived Temporal client ([recurring work](workflows.md#recurring-work)).
- The worker builds no server and no authenticator: it serves no RPCs, and the users it acts for are named in workflow inputs.

## The gateway's root

`Gateway/Serve/Serve.swift`:

```swift
// MARK: - Infrastructure
let jwtConfig = config.scoped(to: "jwt")
let authenticator = try await JWTAuthenticator<UserIdentity>(config: jwtConfig)
let propagation = BearerPropagationInterceptor<UserIdentity>()
…  // each upstream's transport, as in a service's Serve
let loansTracing = ClientOTelTracingInterceptor(serverHostname: loansHost, networkTransportMethod: "tcp")
let loansGRPCClient = GRPCClient(
    transport: loansTransport,
    interceptorPipeline: [
        .apply(loansTracing, to: .all),
        .apply(propagation, to: .services([Bookshelf_Loans_V1_LoanService.descriptor])),
    ]
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
let allowedHeaders: [HTTPField.Name] = …  // content type, authorization, Idempotency-Key, If-Match
let cors = CORSMiddleware<BasicRequestContext>(
    allowOrigin: .originBased,
    allowHeaders: allowedHeaders,
    allowMethods: [.get, .post, .put, .delete]
)
let requestLogging = LogRequestsMiddleware<BasicRequestContext>(logLevel)
let router = Router(context: BasicRequestContext.self)
router.add(middleware: cors)
router.add(middleware: TracingMiddleware())
router.add(middleware: MetricsMiddleware())
router.add(middleware: ErrorMiddleware())
router.add(middleware: requestLogging)
router.get("health") { _, _ in HTTPResponse.Status.ok }
api.addRoutes(to: router.group("v1"))

// MARK: - Hummingbird
let httpServerConfig = config.scoped(to: "http.server")
let applicationConfiguration = ApplicationConfiguration(reader: httpServerConfig)
let application = Application(router: router, configuration: applicationConfiguration, logger: logger)

// MARK: - Lifecycle
// observability, certificateReloader, every upstream client, application
```

The gateway's root has the same Logging and Observability sections as a service's. Its defaults hold `http.server.host` and `http.server.port`; Hummingbird's configuration reader comes from its `ConfigurationSupport` trait.
