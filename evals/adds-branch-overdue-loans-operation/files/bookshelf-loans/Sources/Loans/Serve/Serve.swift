import ArgumentParser
import AuthenticationGRPC
import AuthenticationJWT
import BookshelfAuthentication
import BookshelfPersistence
import BookshelfTransport
import Configuration
import GRPCCore
import GRPCHealthService
import GRPCNIOTransportHTTP2
import GRPCOTelTracingInterceptors
import GRPCServiceLifecycle
import LoansCore
import LoansGRPC
import LoansPostgres
import LoansProtos
import Logging
import NIOCertificateReloading
import OTel
import PersistencePostgres
import PostgresNIO
import ServiceLifecycle
import UnixSignals

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Serve the loans gRPC services"
    )

    func run() async throws {
        // MARK: - Configuration
        let config = ConfigReader(providers: [
            EnvironmentVariablesProvider(),
            InMemoryProvider.applicationDefaults,
        ])

        // MARK: - Logging
        let logLevel = config.string(forKey: "logLevel", default: Logger.Level.info)
        let metadataProvider = Logger.MetadataProvider.multiplex([.user, .otel])
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
        var certificateReloaderConfiguration = try TimedCertificateReloader.Configuration(config: tlsConfig)
        certificateReloaderConfiguration.logger = logger
        certificateReloaderConfiguration.onCertificateLoadFailed = { error in
            logger.warning("Certificate reload failed: keeping the last pair", metadata: ["error": "\(error)"])
        }
        let certificateReloader = try TimedCertificateReloader.makeReloaderValidatingSources(
            configuration: certificateReloaderConfiguration
        )

        let postgresConfig = config.scoped(to: "postgres")
        let servicePostgresConfiguration = try PostgresClient.Configuration(config: postgresConfig, role: "service")
        let postgresClient = PostgresClient(configuration: servicePostgresConfiguration, backgroundLogger: logger)
        let internalPostgresConfiguration = try PostgresClient.Configuration(config: postgresConfig, role: "internal")
        let internalPostgresClient = PostgresClient(
            configuration: internalPostgresConfiguration,
            backgroundLogger: logger
        )

        let jwtConfig = config.scoped(to: "jwt")
        let authenticator = try await JWTAuthenticator<UserIdentity>(config: jwtConfig)

        // MARK: - Composition
        // The caller's own loans run on the tenant database, where the policy confines each
        // transaction to the caller; administrators' reads run on the internal one.
        let database = PostgresDatabase<PostgresLoansScope>(client: postgresClient, logger: logger)
        let internalDatabase = PostgresDatabase<PostgresLoansInternalScope>(
            client: internalPostgresClient,
            logger: logger
        )

        let listLoansUseCase = ListLoansUseCase(database: database, logger: logger)
        let listAllLoansUseCase = ListAllLoansUseCase(database: internalDatabase, logger: logger)
        let loanService = LoanService(
            listLoansUseCase: listLoansUseCase,
            listAllLoansUseCase: listAllLoansUseCase
        )

        // MARK: - gRPC
        let serverConfig = config.scoped(to: "grpc.server")
        let serverHost = try serverConfig.requiredString(forKey: "host")
        let serverPort = try serverConfig.requiredInt(forKey: "port")
        let serverTransportConfig = HTTP2ServerTransport.Posix.Config(config: serverConfig)
        let serverSecurity: HTTP2ServerTransport.Posix.TransportSecurity = try .mTLS(
            config: tlsConfig,
            certificateReloader: certificateReloader
        )
        let serverTransport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: serverHost, port: serverPort),
            transportSecurity: serverSecurity,
            config: serverTransportConfig
        )
        // Loans has no internal contract, so no RPC lists its callers.
        let internalCallers = InternalCallerInterceptor(callers: [:], logger: logger)
        let serverHostname = try serverConfig.requiredString(forKey: "hostname")
        let serverTracing = ServerOTelTracingInterceptor(serverHostname: serverHostname, networkTransportMethod: "tcp")
        let bearerAuthentication = BearerAuthenticationInterceptor(authenticator: authenticator)
        let userSettings = UserSettingsInterceptor()
        let healthService = HealthService()
        healthService.provider.updateStatus(.serving, forService: "")
        let server = GRPCServer(
            transport: serverTransport,
            services: [loanService, healthService],
            interceptorPipeline: [
                .apply(internalCallers, to: .all),
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
                postgresClient,
                internalPostgresClient,
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
