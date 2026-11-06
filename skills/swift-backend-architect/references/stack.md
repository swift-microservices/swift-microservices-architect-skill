# Stack

The libraries the architecture is built on, what each provides, and which targets link it.

## Contents
- The swift-microservices libraries
- The server stack
- Choosing versions

## The swift-microservices libraries

Small libraries that give every service the same shape for identity, request-scoped context and transactions, each over one concern so a target links only what it uses:

| Package | Product | Provides | Linked by |
|---|---|---|---|
| [swift-operation-context](https://github.com/swift-microservices/swift-operation-context) | `OperationContext` | `OperationContext`, a task-local container of typed values for one operation (`OperationContext.current`, `withContext(_:operation:)`), keyed by `OperationContextKey` | XGRPC, `<Org>Authentication`, `<Org>Persistence` |
| [swift-authentication](https://github.com/swift-microservices/swift-authentication) | `Authentication` | `Authenticator<Credential, Identity>`, `CredentialIssuer<Identity, Credential>`, `Principal<Identity, Credential>` (the proved identity and the credential that proved it), `PrincipalKey` | XGRPC, XHTTP, `<Org>Authentication`, the gateway |
| [swift-authentication-jwt](https://github.com/swift-microservices/swift-authentication-jwt) | `AuthenticationJWT` | `JWTAuthenticator<Payload>` and `JWTIssuer<Payload>` over a `JWTKeyCollection` | `<Org>Authentication`, `<Org>Transport`, executables |
| [swift-authentication-grpc](https://github.com/swift-microservices/swift-authentication-grpc) | `AuthenticationGRPC` | `BearerAuthenticationInterceptor` (binds the principal a bearer token proves), `BearerPropagationInterceptor` (presents it on outgoing calls), `Metadata.bearer` | Executables |
| [swift-authentication-hummingbird](https://github.com/swift-microservices/swift-authentication-hummingbird) | `AuthenticationHummingbird` | `BearerAuthenticationMiddleware<Context>`, which sets the context's identity and binds the principal in `OperationContext` | The gateway, XHTTP |
| [swift-persistence](https://github.com/swift-microservices/swift-persistence) | `Persistence` | `Database<Scope>` and `withTransaction(_:)`: the transaction boundary and the scope of repositories a unit of work may touch | XCore, `<Org>Testing` |
| [swift-persistence-postgres](https://github.com/swift-microservices/swift-persistence-postgres) | `PersistencePostgres` | `PostgresDatabase<Scope>`, `PostgresScope`, `PostgresSettings` (transaction-local `set_config`, read from `OperationContext`), `PostgresClient.withClient` | XPostgres, `<Org>Persistence`, executables |
| [swift-openapi-token-authentication](https://github.com/swift-microservices/swift-openapi-token-authentication) | `OpenAPITokenAuthentication` | Client-side sessions and token refresh for generated OpenAPI clients | Client SDKs, out of this skill's scope |

How they fit together on a call:
1. `BearerAuthenticationInterceptor` proves the token with a `JWTAuthenticator<UserIdentity>` and binds a `Principal<UserIdentity, String>` in `OperationContext`.
2. The handler reads it through `OperationContext.current.user` (`<Org>Authentication`) and passes the identity to the use case.
3. `UserSettingsInterceptor` (`<Org>Persistence`) turns the principal into `PostgresSettings`, which `PostgresDatabase` applies at the start of every transaction, so row-level security sees the tenant.
4. `BearerPropagationInterceptor` on an outgoing client presents the same token to the next service.

## The server stack

| Package | Products | Used for | Linked by |
|---|---|---|---|
| [hummingbird](https://github.com/hummingbird-project/hummingbird) | `Hummingbird` | The HTTP server: router, request contexts, middleware, `Application` | The gateway, XHTTP, `<Org>Persistence` |
| [hummingbird-auth](https://github.com/hummingbird-project/hummingbird-auth) | `HummingbirdAuth`, `HummingbirdBcrypt` | `AuthRequestContext`, `IsAuthenticatedMiddleware`; bcrypt | The gateway; a password-hashing adapter |
| [swift-openapi-generator](https://github.com/apple/swift-openapi-generator), [swift-openapi-runtime](https://github.com/apple/swift-openapi-runtime) | `OpenAPIGenerator` plugin, `OpenAPIRuntime` | The gateway's types from `openapi.yaml` | The gateway |
| [grpc-swift-2](https://github.com/grpc/grpc-swift-2) | `GRPCCore` | Servers, clients, interceptors, `RPCError`, `ServiceConfig` | XGRPC, executables |
| [grpc-swift-nio-transport](https://github.com/grpc/grpc-swift-nio-transport) | `GRPCNIOTransportHTTP2` | HTTP/2 transports with TLS and mTLS | Executables, `<Org>Transport` |
| [grpc-swift-protobuf](https://github.com/grpc/grpc-swift-protobuf) | `GRPCProtobuf`, `GRPCProtobufGenerator` plugin | Protobuf serialization and code generation | `<org>-protos` |
| [grpc-swift-extras](https://github.com/grpc/grpc-swift-extras) | `GRPCServiceLifecycle`, `GRPCHealthService`, `GRPCOTelTracingInterceptors` | `GRPCServer` and `GRPCClient` as lifecycle services; health; tracing | Executables |
| [swift-protobuf](https://github.com/apple/swift-protobuf) | `SwiftProtobuf` | Messages, well-known types (`Google_Protobuf_Timestamp`, `Google_Protobuf_Empty`) | `<org>-protos`, XGRPC, the gateway |
| [swift-temporal-sdk](https://github.com/apple/swift-temporal-sdk) | `Temporal` | Workflows, activities, `TemporalClient`, `TemporalWorker` | XTemporal, executables |
| [valkey-swift](https://github.com/valkey-io/valkey-swift) | `Valkey` | `ValkeyClient`, commands, pipelines, transactions | XValkey, executables |
| postgres-nio | `PostgresNIO` | `PostgresClient` pools, prepared statements, row decoding | XPostgres, executables |
| [postgres-migrations](https://github.com/hummingbird-project/postgres-migrations) | `PostgresMigrations` | `DatabaseMigration`, `DatabaseMigrations` | XPostgres, executables |
| [swift-configuration](https://github.com/apple/swift-configuration) | `Configuration` | `ConfigReader`, providers, scoped readers, secrets | Executables, `<Org>Transport`, `<Org>Persistence` |
| [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) | `ServiceLifecycle`, `UnixSignals` | `Service`, `ServiceGroup`, graceful shutdown on signals | Executables |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | `ArgumentParser` | The executable's commands | Executables |
| [swift-nio-extras](https://github.com/apple/swift-nio-extras) | `NIOCertificateReloading` | `CertificateReloader`, `TimedCertificateReloader` | Executables, `<Org>Transport` |
| [swift-log](https://github.com/apple/swift-log) | `Logging` | `Logger`, `LoggingSystem`, metadata providers | Every target that logs |
| [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) | `AsyncAlgorithms` | Collecting a row sequence into an array | XPostgres |
| [swift-crypto](https://github.com/apple/swift-crypto) | `Crypto` | Digests of secrets, signing keys | A Core that hashes secrets |
| jwt-kit | `JWTKit` | `JWTPayload`, claims, EdDSA keys | `<Org>Authentication`, `<Org>Transport` |

Hummingbird is the only HTTP framework, and AsyncHTTPClient the only HTTP client when an adapter calls an HTTP API that has no SDK.

## Choosing versions

- A new package depends on each library `from:` its latest release; look it up with `git ls-remote --tags <url>` rather than copying a version from an example.
- `from:` is a lower bound up to the next major, so resolution picks up fixes and additions; raise it when the code needs a newer API.
- `from:` also accepts a pre-1.0 library's next minor, which may change its API. `.upToNextMinor(from:)` holds a pre-1.0 library, such as the swift-microservices libraries, at its minor when an unreviewed change must not arrive.
- A service's package commits `Package.resolved`; a library's ignores it.
