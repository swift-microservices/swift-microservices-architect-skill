import ArgumentParser
import AuthenticationGRPC
import AuthenticationJWT
import BookshelfAuthentication
import BookshelfTransport
import Configuration
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCOTelTracingInterceptors
import GRPCServiceLifecycle
import GatewayHTTP
import Hummingbird
import LoansProtos
import Logging
import NIOCertificateReloading
import OTel
import ServiceLifecycle
import UnixSignals

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Serve the public HTTP API"
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
        let logger = Logger(label: "bookshelf-gateway")

        // MARK: - Observability
        var otelConfiguration = OTel.Configuration.default
        otelConfiguration.serviceName = "bookshelf-gateway"
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
        let clientSecurity: HTTP2ClientTransport.Posix.TransportSecurity = try .mTLS(
            config: tlsConfig,
            certificateReloader: certificateReloader
        )

        let jwtConfig = config.scoped(to: "jwt")
        let authenticator = try await JWTAuthenticator<UserIdentity>(config: jwtConfig)
        let propagation = BearerPropagationInterceptor<UserIdentity>()

        let loansConfig = config.scoped(to: "grpc.loans")
        let loansHost = try loansConfig.requiredString(forKey: "host")
        let loansPort = try loansConfig.requiredInt(forKey: "port")
        let loansTransportConfig = HTTP2ClientTransport.Posix.Config(config: loansConfig)
        let loansServiceConfig = ServiceConfig(config: loansConfig)
        let loansTransport = try HTTP2ClientTransport.Posix(
            target: .dns(host: loansHost, port: loansPort),
            transportSecurity: clientSecurity,
            config: loansTransportConfig,
            serviceConfig: loansServiceConfig
        )
        let loansTracing = ClientOTelTracingInterceptor(serverHostname: loansHost, networkTransportMethod: "tcp")
        let loansGRPCClient = GRPCClient(
            transport: loansTransport,
            interceptorPipeline: [
                .apply(loansTracing, to: .all),
                .apply(propagation, to: .services([Bookshelf_Loans_V1_LoanService.descriptor])),
            ]
        )

        // MARK: - Composition
        let loanClient = Bookshelf_Loans_V1_LoanService.Client(wrapping: loansGRPCClient)
        let api = BookshelfAPI(
            authenticator: authenticator,
            loanClient: loanClient
        )

        // MARK: - Router
        let cors = CORSMiddleware<BasicRequestContext>(
            allowOrigin: .all,
            allowHeaders: [.accept, .authorization, .contentType],
            allowMethods: [.get]
        )
        let requestLogging = LogRequestsMiddleware<BasicRequestContext>(logLevel)
        let router = Router(context: BasicRequestContext.self)
        // First, so no middleware traces, measures or logs a probe.
        router.get("health") { _, _ in HTTPResponse.Status.ok }
        router.add(middleware: cors)
        router.add(middleware: TracingMiddleware())
        router.add(middleware: MetricsMiddleware())
        router.add(middleware: ErrorMiddleware())
        router.add(middleware: requestLogging)
        api.addRoutes(to: router.group("v1"))

        // MARK: - Hummingbird
        let httpServerConfig = config.scoped(to: "http.server")
        let applicationConfiguration = ApplicationConfiguration(reader: httpServerConfig)
        let application = Application(router: router, configuration: applicationConfiguration, logger: logger)

        // MARK: - Lifecycle
        let serviceGroup = ServiceGroup(
            services: [
                observability,
                certificateReloader,
                loansGRPCClient,
                application,
            ],
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: logger
        )
        try await withLogger(logger) { _ in
            try await serviceGroup.run()
        }
    }
}
