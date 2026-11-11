# Stack

The libraries the architecture is built on, what each provides, which targets link it, and whether it links full Foundation.

## Contents
- The swift-microservices libraries
- The server stack
- Full Foundation
- Choosing versions

## The swift-microservices libraries

Small libraries that give every service the same shape for identity, request-scoped context and transactions, each over one concern so a target links only what it uses:

| Package | Product | Provides | Linked by |
|---|---|---|---|
| [swift-operation-context](https://github.com/swift-microservices/swift-operation-context) | `OperationContext` | `OperationContext`, a task-local container of typed values for one operation (`OperationContext.current`, `withContext(_:operation:)`), keyed by `OperationContextKey` | XGRPC, `<Project>Authentication`, `<Project>Persistence` |
| [swift-authentication](https://github.com/swift-microservices/swift-authentication) | `Authentication` | `Authenticator<Credential, Identity>`, `CredentialIssuer<Identity, Credential>`, `Principal<Identity, Credential>` (the proved identity and the credential that proved it), `PrincipalKey` | XGRPC, `<Project>Authentication`, the gateway, a Core that issues credentials |
| [swift-authentication-jwt](https://github.com/swift-microservices/swift-authentication-jwt) | `AuthenticationJWT` | `JWTAuthenticator<Payload>` and `JWTIssuer<Payload>` over a `JWTKeyCollection` | `<Project>Authentication`, `<Project>Transport`, executables |
| [swift-authentication-grpc](https://github.com/swift-microservices/swift-authentication-grpc) | `AuthenticationGRPC` | `BearerAuthenticationInterceptor` (binds the principal a bearer token proves), `BearerPropagationInterceptor` (presents it on outgoing calls), `Metadata.bearer` | Executables |
| [swift-authentication-hummingbird](https://github.com/swift-microservices/swift-authentication-hummingbird) | `AuthenticationHummingbird` | `BearerAuthenticationMiddleware<Context>`, which sets the context's identity and binds the principal in `OperationContext` | The gateway |
| [swift-persistence](https://github.com/swift-microservices/swift-persistence) | `Persistence` | `Database<Scope>` and `withTransaction(_:)`: the transaction boundary and the scope of repositories a unit of work may touch | XCore, `<Project>Testing` |
| [swift-persistence-postgres](https://github.com/swift-microservices/swift-persistence-postgres) | `PersistencePostgres` | `PostgresDatabase<Scope>`, `PostgresScope`, `PostgresSettings` (transaction-local `set_config`, read from `OperationContext`), `PostgresClient.withClient` | XPostgres, `<Project>Persistence`, executables |

On a call, `BearerAuthenticationInterceptor` binds the caller's principal in `OperationContext`, the handler passes its identity to the use case ([user tokens](security.md#user-tokens)), and `UserSettingsInterceptor` binds the tenant for every transaction ([binding the tenant](persistence.md#binding-the-tenant)).

## The server stack

| Package | Products | Used for | Linked by |
|---|---|---|---|
| [hummingbird](https://github.com/hummingbird-project/hummingbird) | `Hummingbird` | The HTTP server: router, request contexts, middleware, `Application` | The gateway |
| [hummingbird-auth](https://github.com/hummingbird-project/hummingbird-auth) | `HummingbirdAuth`, `HummingbirdBcrypt` | `AuthRequestContext`, `IsAuthenticatedMiddleware`; bcrypt | The gateway; a password-hashing adapter |
| [swift-http-types](https://github.com/apple/swift-http-types) | `HTTPTypes` | `HTTPField.Name` for a header the gateway reads or CORS allows | The gateway |
| [swift-openapi-generator](https://github.com/apple/swift-openapi-generator), [swift-openapi-runtime](https://github.com/apple/swift-openapi-runtime) | `OpenAPIGenerator` plugin, `OpenAPIRuntime` | The gateway's types from `openapi.yaml` | The gateway |
| [grpc-swift-2](https://github.com/grpc/grpc-swift-2) | `GRPCCore` | Servers, clients, interceptors, `RPCError`, `ServiceConfig` | XGRPC, executables, `<Project>Persistence`, `<Project>Transport`, the gateway |
| [grpc-swift-nio-transport](https://github.com/grpc/grpc-swift-nio-transport) | `GRPCNIOTransportHTTP2` | HTTP/2 transports with TLS and mTLS | Executables, `<Project>Transport` |
| [grpc-swift-protobuf](https://github.com/grpc/grpc-swift-protobuf) | `GRPCProtobuf`, `GRPCProtobufGenerator` plugin | Protobuf serialization and code generation | `<project>-protos` |
| [grpc-swift-extras](https://github.com/grpc/grpc-swift-extras) | `GRPCServiceLifecycle` | `GRPCServer` and `GRPCClient` as lifecycle services | Executables |
| [swift-protobuf](https://github.com/apple/swift-protobuf) | `SwiftProtobuf` | Messages, well-known types (`Google_Protobuf_Timestamp`, `Google_Protobuf_Empty`) | `<project>-protos`, XGRPC, the gateway |
| [swift-temporal-sdk](https://github.com/apple/swift-temporal-sdk) | `Temporal`, `TemporalTestKit` | Workflows, activities, `TemporalClient`, `TemporalWorker`; the test servers | XCore in a service with workflows, executables, and no adapter target; `Temporal` and `TemporalTestKit` in `XCoreTests` |
| [valkey-swift](https://github.com/valkey-io/valkey-swift) | `Valkey` | `ValkeyClient`, commands, pipelines, transactions | XValkey, executables |
| [swift-nio-ssl](https://github.com/apple/swift-nio-ssl) | `NIOSSL` | `TLSConfiguration` for the Valkey client | Executables with XValkey |
| postgres-nio | `PostgresNIO` | `PostgresClient` pools, prepared statements, row decoding | XPostgres, executables |
| [postgres-migrations](https://github.com/hummingbird-project/postgres-migrations) | `PostgresMigrations` | `DatabaseMigration`, `DatabaseMigrations` | XPostgres, executables |
| [swift-configuration](https://github.com/apple/swift-configuration) | `Configuration` | `ConfigReader`, providers, scoped readers, secrets | Executables, `<Project>Transport`, `<Project>Persistence` |
| [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) | `ServiceLifecycle`, `UnixSignals` | `Service`, `ServiceGroup`, graceful shutdown on signals | Executables |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | `ArgumentParser` | The executable's commands | Executables |
| [swift-nio-extras](https://github.com/apple/swift-nio-extras) | `NIOCertificateReloading` | `CertificateReloader`, `TimedCertificateReloader` | Executables, `<Project>Transport`, `<Project>Persistence` |
| [swift-log](https://github.com/apple/swift-log) | `Logging` | `Logger`, `LoggingSystem`, metadata providers | Every target that logs |
| [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) | `AsyncAlgorithms` | Collecting a row sequence into an array | XPostgres |
| [swift-crypto](https://github.com/apple/swift-crypto) | `Crypto` | Digests of secrets, signing keys, a key's thumbprint | A Core that hashes secrets, `<Project>Authentication` |
| jwt-kit | `JWTKit` | `JWTPayload`, claims, EdDSA keys | `<Project>Authentication` |

Hummingbird is the only HTTP framework, and AsyncHTTPClient the only HTTP client when an adapter calls an HTTP API that has no SDK.

## Full Foundation

These link full Foundation on Linux whatever their traits, so the products that depend on them are listed in `foundation_linking_check_excluded_products` ([Foundation linking](delivery.md#foundation-linking)):
- postgres-nio, and so postgres-migrations and swift-persistence-postgres: every service with XPostgres
- swift-openapi-generator's generated files, which `public import Foundation`: the gateway
- swift-temporal-sdk through 1.5.0, whose scoped `import struct Foundation.Data` imports link it: every service with workflows

Every other package in the stack is Foundation-free with the traits [traits and Foundation](packages.md#traits-and-foundation) declares, and CI's check finds one that isn't.

## Choosing versions

- A new package depends on each library from its latest release; look it up with `git ls-remote --tags <url>` rather than copying a version from an example.
- A library from 1.0, such as the swift-microservices libraries, is `from:`, a lower bound up to the next major, so resolution picks up fixes and additions; raise it when the code needs a newer API, or to the version from which a package stops linking full Foundation ([full Foundation](#full-foundation)).
- A library below 1.0 is `.upToNextMinor(from:)`, since its next minor may change its API. Moving to that minor is a change of its own, made by hand.
- A service's package commits `Package.resolved`; a library's ignores it.
- The gateway requires swift-openapi-generator `from: "1.14.3"`, whose generated imports don't warn.
