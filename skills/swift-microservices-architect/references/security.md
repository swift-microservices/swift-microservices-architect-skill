# Security

Who proves what on each hop, mutual TLS with certificate reloading, user tokens, authorization in layers, and secrets.

## Contents
- The trust model
- Mutual TLS
- User tokens
- Authorization
- Secrets
- Webhooks

## The trust model

| Hop | Transport | Proves |
|---|---|---|
| Client to the edge | TLS | The edge to the client |
| Edge to the gateway | TLS between proxies, as the deployment chooses; plain HTTP on the gateway's private interface | Nothing more: the gateway trusts its private network for this hop only |
| Gateway to a service's `XService` | gRPC over mTLS, with the caller's token | Both processes by certificate; the user by the token, verified again by the service |
| A service or worker to another's `XInternalService` | gRPC over mTLS | Both processes by certificate; the request names the user it acts for |
| A process to Temporal | mTLS with a certificate pair of its own | Both sides by certificate |
| A process to Postgres | TLS, required (`.require(…)`), against the environment's authority, as one of the service's roles | The server by certificate; the role by its password |
| Inside the database | Row-level security | The tenant, by the setting bound to the transaction |

The edge proxy and certificate issuance belong to the deployment; this skill fixes what each process presents and checks.

## Mutual TLS

Every connection between processes is mutual TLS against a private certificate authority per environment. Each process has a certificate and key, mounted read-only at configured paths, whose DNS names cover the hosts its clients dial.

`<Org>Transport` holds the readers every executable uses:

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

extension HTTP2ClientTransport.Posix.TransportSecurity {
    /// Verifies the server's certificate and that it names the dialed host.
    ///
    /// ## Configuration keys
    /// - `trustRootsPath` (string, required): the PEM bundle of the authority that signs peers.
    public static func mTLS(config: ConfigReader, certificateReloader: any CertificateReloader) throws -> Self {
        let trustRootsPath = try config.requiredString(forKey: "trustRootsPath")
        return try .mTLS(certificateReloader: certificateReloader) {
            $0.trustRoots = .certificates([.file(path: trustRootsPath, format: .pem)])
            $0.serverCertificateVerification = .fullVerification
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
        let certificateSource = TimedCertificateReloader.CertificateSource(location: .file(path: certificatePath), format: .pem)
        let privateKeySource = TimedCertificateReloader.PrivateKeySource(location: .file(path: privateKeyPath), format: .pem)

        self.init(refreshInterval: refreshInterval, certificateSource: certificateSource, privateKeySource: privateKeySource)
        self.logger = logger
        self.onCertificateLoadFailed = { failure in
            logger.warning("TLS certificate reload failed", metadata: ["error": "\(String(reflecting: failure.error))"])
        }
    }
}
```

- The server requires a client certificate signed by the trust roots and doesn't match it against a hostname; the client verifies the server's chain and hostname in full.
- `TimedCertificateReloader` from swift-nio-extras is the `CertificateReloader` that `.mTLS(certificateReloader:)` takes. `makeReloaderValidatingSources(configuration:)` loads the pair before any transport is built, so missing, malformed or mismatched files fail startup.
- The reloader runs in the `ServiceGroup`, re-reading the files every interval. New handshakes use the new pair, and servers bound connection age so every connection handshakes again ([transports](grpc.md#transports)); a failed reload keeps the last good pair and logs a warning.
- One reloader per certificate pair: the service pair under `tls` for gRPC, a separate pair under `temporal.tls` for Temporal, whose trust is independent of the services'.
- Issuing and renewing certificates is the deployment's job; the process only reads files. A new trust root needs a restart.
- An internal RPC is admitted by the listener's trust alone, so every peer the authority signs may call it; internal RPCs take business input and enforce the resource's rules, never trusting the caller to have checked.

## User tokens

One issuer signs every access token. Identity alone holds the EdDSA private key and issues tokens with `JWTIssuer<UserIdentity>`; every other process holds the public key and verifies with `JWTAuthenticator<UserIdentity>`.

The token's payload is the org core's `UserIdentity`:

```swift
public struct UserIdentity: JWTPayload, Equatable, Sendable {
    public let userID: UUID
    public let role: UserRole
    public let issuer: String
    public let issueDate: Date
    public let expirationDate: Date

    private enum CodingKeys: String, CodingKey {
        case userID = "sub"
        case role
        case issuer = "iss"
        case issueDate = "iat"
        case expirationDate = "exp"
    }

    public func verify(using algorithm: some JWTAlgorithm) throws {
        try ExpirationClaim(value: expirationDate).verifyNotExpired()
    }
}

/// A role as the token names it, open so a role added later decodes everywhere.
public struct UserRole: RawRepresentable, Hashable, Codable, ExpressibleByStringLiteral, Sendable {
    public static let user: UserRole = "user"
    public static let admin: UserRole = "admin"
    …
}
```

- The token carries identity only: `sub`, `role`, `iss`, `iat`, `exp`, and `aud` where an audience is used. It carries no permissions, entitlements, business state or personal data; a use case reads those from the service that owns them.
- The subject is the user's id and nothing else: a token whose `sub` isn't a UUID fails to decode, so no handler sees an identity without a user. `verify(using:)` checks every claim the system relies on: the expiry, and the issuer and audience where more than one exists.
- `<Org>Transport` reads the keys by path. `JWTAuthenticator<UserIdentity>(config:)` loads every PEM file in the directory `jwt.publicKeysPath`; Identity's `JWTIssuer<UserIdentity>(config:)` loads the current key from `jwt.privateKeyPath`. Each key's id is its thumbprint (RFC 7638), which the issuer writes in every token's `kid` header, so a verifier picks the key a token names.
- Rotating the signing key keeps the old public key verifying until the tokens it signed expire: every verifier gets the new public key first, Identity then signs with the new private key, and the old public key goes once the last token it signed has expired.
- Identity's use cases issue access tokens through `any CredentialIssuer<UserIdentity, String>`, swift-authentication's protocol, which IdentityCore links as a library [Core may link](packages.md#what-core-may-link); the executable passes the `JWTIssuer`.
- Access tokens are short-lived. A refresh token is an opaque random secret Identity stores only as a digest and accepts only on its refresh RPC, which the gateway routes in the tier with no caller ([request contexts](gateway.md#request-contexts-and-tiers)).
- The gateway verifies the token to pick a tier and forwards the original with `BearerPropagationInterceptor`; each service's `BearerAuthenticationInterceptor` verifies it again. A token never travels on an internal RPC, into a workflow's input, or into a log.

`<Org>Authentication` spells the lookup of the bound principal once, for handlers, interceptors and logging:

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
| The gateway's tier | A valid token where the route needs a caller; the role where it needs an administrator |
| The handler | `requireUser()` where the RPC acts for a caller, before converting the request |
| The use case | The rule: the role, the resource's ownership and state ([authorization](use-cases.md#authorization)) |
| Row-level security | The tenant: a caller's transaction sees only the caller's rows ([row-level security](persistence.md#row-level-security)) |

- Every layer but the use case is defense in depth. A rule that exists only in the gateway or only in a policy is missing from the domain.
- An anonymous RPC that could confirm whether an account exists answers the same either way: a password reset for an unknown address succeeds and sends nothing.
- A caller asking for another user's resource gets the answer a missing resource gets.

## Secrets

- Configuration reads passwords, API keys and webhook secrets with `isSecret: true`, so access reporting redacts them; keys and certificates are files at configured paths, never in an image or a repository.
- Secrets the service issues, such as refresh tokens and reset codes, are random. Postgres stores their SHA-256 digest (`Crypto`), never the secret; Valkey stores a short-lived one with its expiry.
- Passwords are hashed with bcrypt in a provider target (`IdentityBcrypt`'s `BcryptPasswordHasher`), on `NIOThreadPool.singleton.runIfActive { … }`, so the hash never blocks the cooperative pool.

## Webhooks

A provider's webhook arrives with no token: its signature over the body is its proof. Loans receives Resend's delivery events for its overdue notices this way.

- Its RPC is in `XService`'s anyone group ([contracts](grpc.md#contracts-in-the-protos-package)). The gateway forwards the body unparsed with the headers the provider signs with ([controllers](gateway.md#controllers)), since the signature covers the exact bytes.
- The use case verifies before anything else, through a port its provider target implements (`NoticeEventVerifier`, `ResendNoticeEventVerifier`), with the signing secret read as a secret. A signature or timestamp the verifier refuses is the use case's `signatureRejected`, answered `unauthenticated`; checking the timestamp keeps a captured event from being replayed.
- It runs on the internal database: no caller is bound, so a tenant policy would hide every row ([database roles](persistence.md#database-roles)).
- Providers retry, so an event acts once: the transaction that acts also records the provider's event id under a unique key. A repeat that finds it changes nothing in the database, then starts the event's workflow, if it has one, as the first delivery did: the deterministic id joins a run that exists and starts one whose start was lost after the first commit.
- It answers once the event is recorded. Work that takes longer, or calls out, is a workflow the use case starts ([workflows a webhook starts](workflows.md#starting-a-workflow-from-a-use-case)).
