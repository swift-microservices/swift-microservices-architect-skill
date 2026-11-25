# Security

Who proves what on each hop, mutual TLS with certificate reloading, user tokens and their key files, authorization in layers, and secrets.

## Contents
- The trust model
- Mutual TLS
- Postgres
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
| A process to Temporal | As the plan's answer sets ([the worker](workflows.md#the-worker)) | The process, admitted to its service's namespace only |
| A process to Postgres | As the plan's answers set ([Postgres](#postgres)) | The process, as one of its service's roles |
| A process to Valkey | TLS, required, against the environment's authority, as its service's ACL user (`authentication.*`) | The server by certificate; the process by its password, admitted to its service's keys only |
| A worker to Kafka | TLS, required, against the environment's authority, as its service's Kafka user, by SCRAM-SHA-512 (`kafka.authentication.*`) | The server by certificate; the process by its password, admitted to write its service's topics and read the ones the plan lists for it |
| Inside the database | Row-level security | The tenant, by the setting bound to the transaction |

- Each service has its own Valkey ACL user, named for it, whose key pattern is the service's prefix (`~identity:*`), so a service whose password leaks exposes no other service's keys. The deployment creates the users; the service names them in its defaults.
- Each service with [events](events.md) has its own Kafka user, named for it, whose ACLs write only its own topics and read only the topics, in its own group, that the plan lists for it. A password proves it rather than the process's certificate: swift-kafka-client loads a certificate once, so a renewed one would reach it only on a restart.
- The edge proxy and certificate issuance belong to the deployment; this skill fixes what each process presents and checks.

## Mutual TLS

Every gRPC connection is mutual TLS against a private certificate authority per environment. Valkey and Kafka connections are TLS against that authority, with a password proving the process. Temporal and Postgres connect as the plan's answers set ([the worker](workflows.md#the-worker), [Postgres](#postgres)). Each process has a certificate and key, mounted read-only at configured paths, whose DNS names cover the hosts its clients dial and include its identity (`loans`, `loans-worker`).

`<Project>Transport` holds the readers every executable uses:

```swift
public import Configuration
public import GRPCNIOTransportHTTP2
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
    public init(config: ConfigReader) throws {
        …  // the PEM sources and the interval
    }
}
```

- The server requires a client certificate signed by the trust roots and doesn't match it against a hostname; the client verifies the server's chain and hostname in full. The client's reader, on `HTTP2ClientTransport.Posix.TransportSecurity`, differs in one line: `$0.serverCertificateVerification = .fullVerification`.
- `TimedCertificateReloader` from swift-nio-extras is the `CertificateReloader` that `.mTLS(certificateReloader:)` takes. The root sets the configuration's `logger` and its `onCertificateLoadFailed`, which logs a warning ([configuration](composition.md#configuration)). `makeReloaderValidatingSources(configuration:)` loads the pair before any transport is built, so missing, malformed or mismatched files fail startup.
- The reloader runs in the `ServiceGroup` as it is ([lifecycle](composition.md#lifecycle)), re-reading the files every interval. New handshakes use the new pair, and servers bound connection age so every connection handshakes again ([transports](grpc.md#transports)); a failed reload keeps the last good pair and logs a warning.
- One reloader per certificate pair: the process's pair under `tls` for gRPC, and any pair the plan's answers give Temporal or Postgres under that connection's scope (`temporal.tls`).
- Issuing and renewing certificates is the deployment's job; the process only reads files. A new trust root joins every trust bundle beside the old one, with a restart of each process, before any pair it signs is mounted, and the old root leaves once no mounted pair chains to it.
- A local run uses the same mTLS, with a development authority and pairs whose DNS names hold the production identities (`loans`, `loans-worker`). No process has a plaintext or no-verification mode, so nothing that only works locally ships.
- Internal RPCs take business input and enforce the resource's rules, never trusting the caller to have checked.

An internal RPC admits only the processes the plan lists as its callers. `<Project>Transport`'s `InternalCallerInterceptor` holds each listed RPC's callers and is the first interceptor on every service of every server ([interceptors](grpc.md#interceptors)):

```swift
public import GRPCCore
import GRPCNIOTransportHTTP2
public import Logging
import X509

/// Admits to each listed RPC only the processes whose certificates name one of its callers.
public struct InternalCallerInterceptor: ServerInterceptor {
    private let callers: [MethodDescriptor: Set<String>]
    private let logger: Logger

    public init(callers: [MethodDescriptor: Set<String>], logger: Logger) {
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
        …  // the DNS names of `HTTP2ServerTransport.Posix.Context`'s `peerCertificate`, or `permissionDenied`
    }
}
```

- A listed RPC admits a peer whose certificate's DNS subject alternative names include one of its callers, compared case-insensitively, and refuses any other, or a call with no certificate, with `permissionDenied`. The common name is never read. An RPC the map doesn't list passes.
- The executable's reader in `Configuration/` builds the map from the internal contract's descriptors, a string array per RPC under `grpc.server.internalCallers`, named for the RPC (`grpc.server.internalCallers.getBook`), whose defaults are the plan's callers: Catalog's `GetBook` lists `loans` and `loans-worker` ([the plan](system.md#the-plan)).
- The gateway is never a caller: it faces the internet, and an internal RPC takes the user it acts for in its input, past tokens and row-level security.

## Postgres

How each role logs in, the TLS mode, and the rest of a service's Postgres setup are questions the plan puts to the user, with no default and no recommendation ([the plan](system.md#the-plan)). The skill assumes none of them:

- `<Project>Persistence`'s reader, `PostgresClient.Configuration(config:role:)`, takes what the answer needs, such as a certificate reloader or a password's file, and every role's client is built through it ([connections and timeouts](persistence.md#connections-and-timeouts)).
- Only `migrate` and `build-indexes` log in as the owner, so no process that serves requests or runs activities holds the owner's credentials.
- The deployment provides the server's side of the answer; the service names the database and its roles ([naming](conventions.md#naming)).
- On an instance several services share ([data placement](system.md#data-placement)), a role migration revokes `CONNECT` on the service's database from `PUBLIC` and grants it to the service's own roles: Postgres lets every role connect to a new database, so another service's leaked login would otherwise reach it.

## User tokens

One issuer signs every access token: Identity, with the Ed25519 private key in the file at `jwt.privateKeyPath`. Every process, Identity included, verifies with `JWTAuthenticator<UserIdentity>` against the public keys in the file at `jwt.publicKeyPath` ([signing keys](#signing-keys)).

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
        …
    }

    public func verify(using algorithm: some JWTAlgorithm) throws {
        try ExpirationClaim(value: expirationDate).verifyNotExpired()
    }
}

/// A role as the token names it, open so a role added later decodes everywhere.
public struct UserRole: RawRepresentable, Hashable, Codable, ExpressibleByStringLiteral, Sendable {
    public static let user: UserRole = "user"
    public static let librarian: UserRole = "librarian"
    public static let admin: UserRole = "admin"

    public let rawValue: String

    public init(rawValue: String) { … }

    public init(stringLiteral value: String) { … }
}
```

- The token carries identity only: `sub`, `role`, `iss`, `iat`, `exp`, `aud` where an audience is used, and `org` where callers act for an organization ([organization tenants](persistence.md#organization-tenants)). It carries no permissions, entitlements, business state or personal data; a use case reads those from the service that owns them.
- The subject is the user's id and nothing else: a token whose `sub` isn't a UUID fails to decode, so no handler sees an identity without a user. `verify(using:)` checks every claim the system relies on: the expiry, and the issuer and audience where more than one exists.
- Identity's use cases issue access tokens through `any CredentialIssuer<UserIdentity, String>`, swift-authentication's protocol, which IdentityCore links as a library [Core may link](packages.md#what-core-may-link); the executable passes the `JWTIssuer` it builds from the private key ([signing keys](#signing-keys)).
- An access token lives 15 minutes, `SessionPolicy.accessTokenLifetime`, a policy value Identity reads from configuration: a revoked session or a changed role reaches every service within that time, since no service asks Identity about a token it can verify.
- A refresh token is an opaque random secret Identity stores only as a digest and accepts only on its refresh and sign-out RPCs, which the gateway routes in the no-caller tier ([request contexts](gateway.md#request-contexts-and-tiers)). Sign-out ends the one session that refresh token belongs to.
- Each refresh replaces the refresh token: in one transaction, the use case moves the presented token from active to used with a conditional write, and stores its successor in the same session. A used token presented again was copied, by whoever holds either copy, so the use case ends the whole session and refuses; the holder of the real one signs in again.
- Each service's `BearerAuthenticationInterceptor` verifies again the token the gateway verified to pick a tier and forwards ([upstream clients](gateway.md#upstream-clients)). A token never travels on an internal RPC, into a workflow's input, or into a log.

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

### Signing keys

The keys are static files, a key pair per environment, which the deployment mounts like a certificate: only Identity's serve process mounts the private key, and every process that verifies tokens mounts the public key file. `<Project>Authentication` builds both sides from them, in `JWT+EdDSA.swift`:

```swift
public import AuthenticationJWT
public import JWTKit

extension JWTIssuer {
    /// Signs with an Ed25519 private key, naming its `kid` in each token's header.
    public init(privateKey: EdDSA.PrivateKey) async {
        …
    }
}

extension JWTAuthenticator {
    /// Verifies against Ed25519 public keys, each found by the `kid` a token names.
    public init(publicKeys: [EdDSA.PublicKey]) async {
        …
    }
}
```

- A key's `kid` is its RFC 7638 thumbprint, so the issuer and every verifier derive it from the key itself. A token that names no `kid`, or one no verifier's file holds, fails as `unauthenticated`.
- The file at `jwt.publicKeyPath` holds one PEM public key, or two during a rotation; `<Project>Transport`'s reader, `JWTAuthenticator(config:)`, loads every key in it. Identity's executable reads `jwt.privateKeyPath` in its own `Configuration/` ([secrets](#secrets)).
- A process reads its key files once, at startup: a changed key reaches it with its next deploy.

A key changes by this runbook, in this order, so no verifier meets a token it can't check:

1. Add the new public key to every verifier's file beside the old one, and deploy every process that verifies tokens.
2. Point Identity's `jwt.privateKeyPath` at the new private key, and deploy Identity: its tokens now name the new `kid`.
3. Once one access-token lifetime (`SessionPolicy.accessTokenLifetime`) has passed, remove the old public key from every file, and deploy again.

`/.well-known/jwks.json` is served only when something outside the system verifies tokens, by the gateway from its own public key file, with no RPC ([controllers](gateway.md#controllers)).

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

- A secret, such as a password, an API key, a webhook's signing secret or a private key, reaches the process as a file the deployment mounts, never in an image or a repository.
- An environment variable holds a secret only on a platform that can deliver it no other way, recorded under the plan's Decisions with the exposure it accepts: `docker inspect` and `/proc/<pid>/environ` show it to anyone who can read the container's configuration.
- Its configuration key is the file's path, named for the secret with `Path` (`jwt.privateKeyPath`, `resend.webhookSecretPath`, `valkey.authentication.passwordPath`), and the reader that needs the secret loads the file ([configuration](composition.md#configuration)). A secret from an environment variable takes the key without `Path` (`jwt.privateKey`), read as a secret. The value never reaches a log line.
- Secrets the service issues, such as refresh tokens and reset codes, are random. Postgres and Valkey store their SHA-256 digest (`Crypto`), never the secret, Valkey with its expiry.
- Passwords are hashed with bcrypt in a provider target (`IdentityBcrypt`'s `BcryptPasswordHasher`), off the cooperative pool ([concurrency](style.md#concurrency)). The cost is a policy value, `PasswordPolicy.bcryptCost` (12), raised as hardware gets faster.
- A password longer than 72 bytes of UTF-8 is refused as `invalidPassword` (`PasswordPolicy.maximumByteCount`): bcrypt ignores every byte after the 72nd, so two passwords that share their first 72 bytes would both sign in. The limit counts bytes, not characters.

## Attempt limits

A request that proves a secret someone could guess, signing in with a password or redeeming a reset code, is limited per account: Identity counts the account's failures in Valkey and refuses once the policy's limit is reached, before checking the secret.

- The count is an XValkey repository behind a Core port, keyed by the account's id: `SignInFailureRepository` (`identity:sign-in-failures:<user id>`) and `ResetCodeFailureRepository` (`identity:reset-code-failures:<user id>`), each with `failures(userID:)`, `recordFailure(userID:window:)`, which increments and sets the window's expiry on the first failure, and `clear(userID:)` after a success ([Valkey](persistence.md#valkey)).
- So the account is known before the secret is checked: a sign-in names its address, and a reset code's redemption names the address it was sent to. An unknown address counts nothing and answers as a wrong secret does ([authorization](#authorization)).
- The limits and windows are policy values: `SessionPolicy.maximumSignInFailures` and `signInFailureWindow`, and the reset code's alike.
- The use case's case is `tooManyAttempts` ([status codes](grpc.md#status-codes)).
- Unlike a cache's read, a failed read of the count fails the request: a limit that Valkey's outage turned off would let guessing through.
- Limits per address, against many accounts at once, are the edge's ([the edge](gateway.md#the-edge)).

## Webhooks

A provider's webhook arrives with no token: its signature over the body is its proof. Loans receives Resend's delivery events for its overdue notices this way.

- Its RPC is in `XService`'s anyone group ([contracts](grpc.md#contracts-in-the-protos-package)). The gateway forwards the body unparsed with the headers the provider signs with ([controllers](gateway.md#controllers)), since the signature covers the exact bytes.
- The use case verifies before anything else, through a port its provider target implements (`NoticeEventVerifier`, `ResendNoticeEventVerifier`), with the signing secret loaded from its file ([secrets](#secrets)). A signature or timestamp the verifier refuses is the use case's `signatureRejected` ([status codes](grpc.md#status-codes)); checking the timestamp keeps a captured event from being replayed.
- It runs on the internal database: no caller is bound, so a tenant policy would hide every row ([database roles](persistence.md#database-roles)).
- Providers retry, so an event acts once: the transaction that acts also records the provider's event id under a unique key. A repeat that finds it changes nothing in the database, then starts the event's workflow, if it has one, as the first delivery did: the deterministic id joins a run that exists and starts one whose start was lost after the first commit.
- It answers once the event is recorded. Work that takes longer, or calls out, is a workflow the use case starts ([workflows a webhook starts](workflows.md#starting-a-workflow-from-a-use-case)).
