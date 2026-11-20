# Security

Who proves what on each hop, mutual TLS with certificate reloading, user tokens, authorization in layers, and secrets.

## Contents
- The trust model
- Mutual TLS
- User tokens
- Authorization
- Secrets
- Attempt limits
- Webhooks

## The trust model

| Hop | Transport | Proves |
|---|---|---|
| Client to the edge | TLS | The edge to the client |
| Edge to the gateway | TLS between proxies, as the deployment chooses; plain HTTP on the gateway's private interface | Nothing more: the gateway trusts its private network for this hop only |
| Gateway to a service's `XService` | gRPC over mTLS, with the caller's token | Both processes by certificate; the user by the token, verified again by the service |
| A service or worker to another's `XInternalService` | gRPC over mTLS | Both processes by certificate; the request names the user it acts for |
| A process to Temporal | mTLS with a certificate pair of its own | Both sides by certificate |
| A process to Postgres | TLS, required (`.require(…)`), against the environment's authority, with the process's certificate, as one of the service's roles | Both sides by certificate; the server's map admits the process to its roles only ([Postgres](#postgres)) |
| A process to Valkey | TLS, required, against the environment's authority, with a username and password (`authentication.*`) | The server by certificate; the process by its password |
| Inside the database | Row-level security | The tenant, by the setting bound to the transaction |

The edge proxy and certificate issuance belong to the deployment; this skill fixes what each process presents and checks.

## Mutual TLS

Every gRPC connection and every connection to Temporal or Postgres is mutual TLS against a private certificate authority per environment. Valkey connections are TLS against that authority, with a password proving the process. Each process has a certificate and key, mounted read-only at configured paths, whose DNS names cover the hosts its clients dial and whose common name is its identity (`loans`, `loans-worker`).

`<Project>Transport` holds the readers every executable uses:

```swift
public import Configuration
public import GRPCNIOTransportHTTP2
public import Logging
public import NIOCertificateReloading

extension HTTP2ServerTransport.Posix.TransportSecurity {
    /// Requires every peer to present a certificate the trust roots signed.
    ///
    /// ## Configuration keys
    /// - `trustRootsPath` (string, required): the PEM bundle of the authority that signs peers.
    public static func mTLS(config: ConfigReader, certificateReloader: any CertificateReloader) throws -> Self {
        let trustRootsPath = try config.requiredString(forKey: "trustRootsPath")
        return try .mTLS(certificateReloader: certificateReloader) {
            $0.trustRoots = .certificates([.file(path: trustRootsPath, format: .pem)])
            $0.clientCertificateVerification = .noHostnameVerification
        }
    }
}

extension TimedCertificateReloader.Configuration {
    /// The process's certificate and key, reloaded from disk as the deployment renews them.
    ///
    /// ## Configuration keys
    /// - `certificatePath`, `privateKeyPath` (string, required): the PEM pair.
    /// - `refreshIntervalSeconds` (int, default 60): how often the files are read.
    public init(config: ConfigReader, logger: Logger) throws {
        let refreshInterval = config.int(forKey: "refreshIntervalSeconds", as: Duration.self, default: .seconds(60))
        let certificatePath = try config.requiredString(forKey: "certificatePath")
        let privateKeyPath = try config.requiredString(forKey: "privateKeyPath")
        let certificateSource = TimedCertificateReloader.CertificateSource(
            location: .file(path: certificatePath),
            format: .pem
        )
        let privateKeySource = TimedCertificateReloader.PrivateKeySource(
            location: .file(path: privateKeyPath),
            format: .pem
        )

        self.init(
            refreshInterval: refreshInterval,
            certificateSource: certificateSource,
            privateKeySource: privateKeySource
        )
        self.logger = logger
        self.onCertificateLoadFailed = { failure in
            logger.warning("TLS certificate reload failed", metadata: ["error": "\(failure.error)"])
        }
    }
}
```

- The server requires a client certificate signed by the trust roots and doesn't match it against a hostname; the client verifies the server's chain and hostname in full. The client's reader, on `HTTP2ClientTransport.Posix.TransportSecurity`, differs in one line: `$0.serverCertificateVerification = .fullVerification`.
- `TimedCertificateReloader` from swift-nio-extras is the `CertificateReloader` that `.mTLS(certificateReloader:)` takes. `makeReloaderValidatingSources(configuration:)` loads the pair before any transport is built, so missing, malformed or mismatched files fail startup.
- The reloader runs in the `ServiceGroup`, re-reading the files every interval. New handshakes use the new pair, and servers bound connection age so every connection handshakes again ([transports](grpc.md#transports)); a failed reload keeps the last good pair and logs a warning.
- One reloader per certificate pair: the process's pair under `tls` for gRPC and Postgres, a separate pair under `temporal.tls` for Temporal, whose trust is independent of the services', and the migrator's under `postgres.owner.tls`.
- Issuing and renewing certificates is the deployment's job; the process only reads files. A new trust root needs a restart.
- A local run uses the same mTLS, with a development authority and pairs whose common names are the production identities (`loans`, `loans-worker`, `loans-migrator`). No process has a plaintext or no-verification mode, so nothing that only works locally ships.
- Internal RPCs take business input and enforce the resource's rules, never trusting the caller to have checked.

An internal RPC admits only the processes its service lists as callers. `<Project>Transport`'s `InternalCallerInterceptor`, applied to each `XInternalService` descriptor ([interceptors](grpc.md#interceptors)), reads the common name of the peer's certificate and refuses any identity not in `grpc.server.internalCallers` with `permissionDenied`:

```swift
public import Configuration
public import GRPCCore
import GRPCNIOTransportHTTP2
import X509

/// Admits to an internal service only the processes whose certificates name a listed caller.
///
/// ## Configuration keys
/// - `internalCallers` (string array, required): the common names of the processes that may call.
public struct InternalCallerInterceptor: ServerInterceptor {
    private let callers: Set<String>

    public init(config: ConfigReader) throws {
        …
    }

    public func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next:
            @concurrent @Sendable (
                _ request: StreamingServerRequest<Input>,
                _ context: ServerContext
            ) async throws -> StreamingServerResponse<Output>
    ) async throws -> StreamingServerResponse<Output> {
        …  // the common name of `HTTP2ServerTransport.Posix.Context`'s `peerCertificate`, or `permissionDenied`
    }
}
```

- Catalog lists `loans` and `loans-worker`, the identities of the processes that call `BookInternalService`, as the plan's contracts name its callers ([the plan](system.md#the-plan)).
- The gateway is never a caller: it faces the internet, and an internal RPC takes the user it acts for in its input, past tokens and row-level security.

### Postgres

A process proves its database role with its certificate, the pair its gRPC connections present, and Postgres maps the certificate's common name to the roles that identity may use:

```
# pg_hba.conf
hostssl  bookshelf_loans  all  all  cert  map=bookshelf_loans

# pg_ident.conf
# MAPNAME         SYSTEM-USERNAME  PG-USERNAME
bookshelf_loans   loans            loans_service
bookshelf_loans   loans            loans_internal
bookshelf_loans   loans-worker     loans_worker
bookshelf_loans   loans-migrator   loans_owner
```

- The deployment provides these lines; the service names the identities and roles in them ([naming](conventions.md#naming)).
- The migrator is an identity of its own, whose pair only the one process running `serve --migrate-database` mounts, so no other replica can connect as the owner.
- `PostgresClient.Configuration(config:role:certificateReloader:)` presents the reloader's pair over required TLS. Serve and the worker pass their `tls` reloader, so each new connection presents a renewed pair; `serve --migrate-database` passes a reloader of the migrator's pair, which its short-lived client uses before the `ServiceGroup` starts and which is never run.
- Where a managed Postgres takes no client certificates, each role proves itself with a SCRAM-SHA-256 password from the secret store instead: `PostgresClient.Configuration(config:role:)` reads it as a secret, and migrations set it ([migrations](persistence.md#migrations)).

## User tokens

One issuer signs every access token. Identity alone holds the EdDSA private key and issues tokens with `JWTIssuer<UserIdentity>`; every other process holds the public key and verifies with `JWTAuthenticator<UserIdentity>`.

The token's payload is `<project>-core`'s `UserIdentity`:

```swift
public struct UserIdentity: JWTPayload, Equatable, Sendable {
    public let userID: UUID
    public let role: UserRole
    public let organizationID: UUID?
    public let issuer: String
    public let issueDate: Date
    public let expirationDate: Date

    private enum CodingKeys: String, CodingKey {
        case userID = "sub"
        case role
        case organizationID = "org"
        case issuer = "iss"
        case issueDate = "iat"
        case expirationDate = "exp"
    }

    /// Writes `sub` and `org` lowercase, as every id on the wire is; `UUID`'s own encoding is uppercase.
    public func encode(to encoder: any Encoder) throws {
        let subject = userID.uuidString.lowercased()
        let organization = organizationID?.uuidString.lowercased()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(subject, forKey: .userID)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(organization, forKey: .organizationID)
        try container.encode(issuer, forKey: .issuer)
        try container.encode(issueDate, forKey: .issueDate)
        try container.encode(expirationDate, forKey: .expirationDate)
    }

    public func verify(using algorithm: some JWTAlgorithm) throws {
        try ExpirationClaim(value: expirationDate).verifyNotExpired()
    }
}

/// A role as the token names it, open so a role added later decodes everywhere.
///
/// The standard library codes a `RawRepresentable` string as its raw value, so `Codable` needs no code.
public struct UserRole: RawRepresentable, Hashable, Codable, ExpressibleByStringLiteral, Sendable {
    public static let user: UserRole = "user"
    public static let librarian: UserRole = "librarian"
    public static let admin: UserRole = "admin"

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}
```

- The token carries identity only: `sub`, `role`, `iss`, `iat`, `exp`, `aud` where an audience is used, and `org` where callers act for an organization ([organization tenants](persistence.md#organization-tenants)). It carries no permissions, entitlements, business state or personal data; a use case reads those from the service that owns them.
- The subject is the user's id and nothing else: a token whose `sub` isn't a UUID fails to decode, so no handler sees an identity without a user. `verify(using:)` checks every claim the system relies on: the expiry, and the issuer and audience where more than one exists.
- `<Project>Transport` reads the keys by path. `JWTAuthenticator<UserIdentity>(config:)` loads every PEM file in the directory `jwt.publicKeysPath`; Identity's `JWTIssuer<UserIdentity>(config:)` loads the private key from `jwt.privateKeyPath`. Each key is registered under its `kid`, the RFC 7638 thumbprint of the public key, which the issuer writes in the token's header.
- Identity's use cases issue access tokens through `any CredentialIssuer<UserIdentity, String>`, swift-authentication's protocol, which IdentityCore links as a library [Core may link](packages.md#what-core-may-link); the executable passes the `JWTIssuer`.
- An access token lives 15 minutes, `SessionPolicy.accessTokenLifetime`, a policy value Identity reads from configuration: a revoked session or a changed role reaches every service within that time, since no service asks Identity about a token it can verify.
- A refresh token is an opaque random secret Identity stores only as a digest and accepts only on its refresh and sign-out RPCs, which the gateway routes in the tier with no caller ([request contexts](gateway.md#request-contexts-and-tiers)). Sign-out ends the one session that refresh token belongs to.
- Each refresh replaces the refresh token: in one transaction, the use case moves the presented token from active to used with a conditional write, and stores its successor in the same session. A used token presented again was copied, by whoever holds either copy, so the use case ends the whole session and refuses; the holder of the real one signs in again.
- The gateway verifies the token to pick a tier and forwards the original with `BearerPropagationInterceptor`; each service's `BearerAuthenticationInterceptor` verifies it again. A token never travels on an internal RPC, into a workflow's input, or into a log.

`<Project>Authentication` spells the lookup of the bound principal once, for handlers, interceptors and logging:

```swift
extension OperationContext {
    /// The user behind the current request: the verified identity and the token that proved it.
    public var user: Principal<UserIdentity, String>? {
        get { self[PrincipalKey<UserIdentity, String>.self] }
        set { self[PrincipalKey<UserIdentity, String>.self] = newValue }
    }
}

extension Logger.MetadataProvider {
    /// The bound user's id on every log line of a request; nothing when no user is bound.
    public static let user = Logger.MetadataProvider {
        guard let user = OperationContext.current.user else {
            return [:]
        }

        return ["userID": "\(user.identity.userID)"]
    }
}
```

## Authorization

Each layer refuses what it can see; the use case decides.

| Layer | Checks |
|---|---|
| The gateway's tier | A valid token where the route needs a caller; the role where it needs an administrator, and no other role |
| The handler | `requireUser()` where the RPC acts for a caller, before converting the request |
| The use case | The rule: the role, the resource's ownership and state ([authorization](use-cases.md#authorization)) |
| Row-level security | The tenant: a caller's transaction sees only the caller's rows ([row-level security](persistence.md#row-level-security)) |

- Every layer but the use case is defense in depth. A rule that exists only in the gateway or only in a policy is missing from the domain.
- An anonymous RPC that could confirm whether an account exists answers the same either way: a password reset for an unknown address succeeds and sends nothing. Registration is the one exception: an address already registered answers `duplicateEmail` as `alreadyExists`, so sign-up stays one step, at the cost of revealing which addresses are registered.
- A caller asking for another user's resource gets the answer a missing resource gets.

## Secrets

- Configuration reads passwords, API keys and webhook secrets with `isSecret: true`, so access reporting redacts them; keys and certificates are files at configured paths, never in an image or a repository.
- A secret value reaches the process as a file in `/run/secrets` named for its key, which `DirectoryFilesProvider` reads ([configuration](composition.md#configuration)), never as an environment variable: `docker inspect` and `/proc/<pid>/environ` show those to anyone who can read the container's configuration.
- Secrets the service issues, such as refresh tokens and reset codes, are random. Postgres stores their SHA-256 digest (`Crypto`), never the secret; Valkey stores a short-lived one with its expiry.
- Passwords are hashed with bcrypt in a provider target (`IdentityBcrypt`'s `BcryptPasswordHasher`), on `NIOThreadPool.singleton.runIfActive { … }`, so the hash never blocks the cooperative pool.

## Attempt limits

A request that proves a secret someone could guess, signing in with a password or redeeming a reset code, is limited per account: Identity counts the account's failures in Valkey and refuses once the policy's limit is reached, before checking the secret.

- The count is an XValkey repository behind a Core port, `SignInFailureRepository`, keyed by the account's id (`identity:sign-in-failures:<user id>`): `failures(userID:)`, `recordFailure(userID:window:)`, which increments and sets the window's expiry on the first failure, and `clear(userID:)` after a success ([Valkey](persistence.md#valkey)).
- The limit and the window are policy values, `SessionPolicy.maximumSignInFailures` and `signInFailureWindow`.
- The use case's case is `tooManyAttempts`, which maps to `resourceExhausted` and the gateway's `429` ([status codes](grpc.md#status-codes)).
- Unlike a cache's read, a failed read of the count fails the request: a limit that Valkey's outage turned off would let guessing through.
- Limits per address, against many accounts at once, are the edge's ([the edge](gateway.md#the-edge)).

## Webhooks

A provider's webhook arrives with no token: its signature over the body is its proof. Loans receives Resend's delivery events for its overdue notices this way.

- Its RPC is in `XService`'s anyone group ([contracts](grpc.md#contracts-in-the-protos-package)). The gateway forwards the body unparsed with the headers the provider signs with ([controllers](gateway.md#controllers)), since the signature covers the exact bytes.
- The use case verifies before anything else, through a port its provider target implements (`NoticeEventVerifier`, `ResendNoticeEventVerifier`), with the signing secret read as a secret. A signature or timestamp the verifier refuses is the use case's `signatureRejected`, answered `unauthenticated`; checking the timestamp keeps a captured event from being replayed.
- It runs on the internal database: no caller is bound, so a tenant policy would hide every row ([database roles](persistence.md#database-roles)).
- Providers retry, so an event acts once: the transaction that acts also records the provider's event id under a unique key. A repeat that finds it changes nothing in the database, then starts the event's workflow, if it has one, as the first delivery did: the deterministic id joins a run that exists and starts one whose start was lost after the first commit.
- It answers once the event is recorded. Work that takes longer, or calls out, is a workflow the use case starts ([workflows a webhook starts](workflows.md#starting-a-workflow-from-a-use-case)).
