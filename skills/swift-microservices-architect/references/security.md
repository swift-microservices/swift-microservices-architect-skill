# Security

Who proves what on each hop, mutual TLS with certificate reloading, user tokens and their signing keys, authorization in layers, and secrets.

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
| A process to Temporal | mTLS with a certificate pair of its own | Both sides by certificate; the authorizer admits the process to its service's namespace only ([the worker](workflows.md#the-worker)) |
| A process to Postgres | TLS, required (`.require(…)`), against the environment's authority, with the process's certificate, as one of the service's roles | Both sides by certificate; the server's map admits the process to its roles only ([Postgres](#postgres)) |
| A process to Valkey | TLS, required, against the environment's authority, as its service's ACL user (`authentication.*`) | The server by certificate; the process by its password, admitted to its service's keys only |
| A worker to Kafka | TLS, required, against the environment's authority, as its service's Kafka user, by SCRAM-SHA-512 (`kafka.authentication.*`) | The server by certificate; the process by its password, admitted to write its service's topics and read the ones the plan lists for it |
| Inside the database | Row-level security | The tenant, by the setting bound to the transaction |

- Each service has its own Valkey ACL user, named for it, whose key pattern is the service's prefix (`~identity:*`), so a service whose password leaks exposes no other service's keys. The deployment creates the users; the service names them in its defaults.
- Each service with [events](events.md) has its own Kafka user, named for it, whose ACLs write only its own topics and read only the topics, in its own group, that the plan lists for it. A password proves it rather than the process's certificate: swift-kafka-client loads a certificate once, so a renewed one would reach it only on a restart.
- The edge proxy and certificate issuance belong to the deployment; this skill fixes what each process presents and checks.

## Mutual TLS

Every gRPC connection and every connection to Temporal or Postgres is mutual TLS against a private certificate authority per environment. Valkey and Kafka connections are TLS against that authority, with a password proving the process. Each process has a certificate and key, mounted read-only at configured paths, whose DNS names cover the hosts its clients dial and whose common name is its identity (`loans`, `loans-worker`).

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
        …  // the PEM sources and the interval; `onCertificateLoadFailed` logs a warning
    }
}
```

- The server requires a client certificate signed by the trust roots and doesn't match it against a hostname; the client verifies the server's chain and hostname in full. The client's reader, on `HTTP2ClientTransport.Posix.TransportSecurity`, differs in one line: `$0.serverCertificateVerification = .fullVerification`.
- `TimedCertificateReloader` from swift-nio-extras is the `CertificateReloader` that `.mTLS(certificateReloader:)` takes. `makeReloaderValidatingSources(configuration:)` loads the pair before any transport is built, so missing, malformed or mismatched files fail startup.
- The reloader runs in the `ServiceGroup`, re-reading the files every interval. New handshakes use the new pair, and servers bound connection age so every connection handshakes again ([transports](grpc.md#transports)); a failed reload keeps the last good pair and logs a warning.
- One reloader per certificate pair: the process's pair under `tls` for gRPC and Postgres, a separate pair under `temporal.tls` for Temporal, whose trust is independent of the services', and the migrator's under `postgres.owner.tls`.
- Issuing and renewing certificates is the deployment's job; the process only reads files. A new trust root joins every trust bundle beside the old one, with a restart of each process, before any pair it signs is mounted, and the old root leaves once no mounted pair chains to it.
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
- The migrator is an identity of its own, whose pair only the `migrate` and `build-indexes` commands mount, never serve or the worker, so no process that serves requests or runs activities can connect as the owner.
- `PostgresClient.Configuration(config:role:certificateReloader:)` presents the reloader's pair over required TLS. Serve and the worker pass their `tls` reloader, so each new connection presents a renewed pair; `migrate` and `build-indexes` pass a reloader of the migrator's pair, which their short-lived client uses and which is never run.
- Where a managed Postgres takes no client certificates, each role proves itself with a SCRAM-SHA-256 password from the secret store instead: `PostgresClient.Configuration(config:role:)` reads it as a secret, and migrations set it ([migrations](persistence.md#migrations)).

## User tokens

One issuer signs every access token. Identity alone holds the private keys, which it generates, rotates and signs with ([signing keys](#signing-keys)); every process, Identity included, verifies with `JWTAuthenticator<UserIdentity>` against the public keys Identity publishes.

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
- Identity's use cases issue access tokens through `any CredentialIssuer<UserIdentity, String>`, swift-authentication's protocol, which IdentityCore links as a library [Core may link](packages.md#what-core-may-link); the executable passes `JWTCredentialIssuer` ([signing keys](#signing-keys)).
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

Identity signs access tokens with Ed25519 keys it generates and rotates itself, and every process that verifies tokens keeps the public keys Identity publishes in memory. Two rules make a rotation safe: a key is in every verifier's set before it signs, and stays there until every token it signed has expired.

Each key moves through three statuses, in order, as a row of Identity's untenanted `signing_keys` table:

| Status | Published | Signs |
|---|---|---|
| `next` | Yes | No |
| `current` | Yes | Yes, the only key that does |
| `retired` | Until its last token has expired, then the row is deleted | No |

- A row holds the `kid`, the RFC 7638 thumbprint of the public key; the Ed25519 public key; the private key, sealed with `AES.GCM` from `Crypto` under the key-encryption key and authenticating the `kid`, so a sealed key copied to another row fails to open; the status; and the dates it was created, promoted and retired. A partial unique index on `status` keeps one key `next` and one `current`.
- The key-encryption key is a secret, `jwt.keyEncryptionKey`, 32 random bytes in base64, which Identity's serve and worker read. A platform with a KMS or HSM keeps private keys there instead; this stack has none, so Identity seals them in its own database.
- Only `identity_worker`, which runs the rotation, writes the table; `identity_service` reads it.

The rotation is `RotateSigningKeysUseCase`, the system use case that the one activity of `RotateSigningKeysWorkflow` runs, which Identity's schedule starts daily ([recurring work](workflows.md#recurring-work)). It generates and seals keys with `Crypto` ([what Core may link](packages.md#what-core-may-link)), holding the key-encryption key as a `SymmetricKey` from the worker's root. In one transaction, under `lockSigningKeys()`, an advisory lock, since the first run finds no row to lock ([transactions](use-cases.md#transactions)), it:

1. Creates a `current` key when there is none, as in a new environment: no other key can sign, and verifiers take it at their next refresh.
2. Promotes `next` to `current`, and `current` to `retired`, once the current key has signed for `SigningKeyPolicy.rotationInterval` (30 days) and the next has been published for longer than `SigningKeyPolicy.refreshInterval`.
3. Creates a `next` key when there is none, so the next rotation's key is published a whole interval before it signs.
4. Deletes each `retired` key once `SessionPolicy.accessTokenLifetime` plus `SigningKeyPolicy.refreshInterval` has passed since its retirement, since an Identity replica signs with the old key until its own next refresh.

Each write is conditional on what the transaction read under the lock, so a repeated run changes nothing. `SigningKeyPolicy.refreshInterval` (5 minutes) is every refresher's `jwt.refreshIntervalSeconds`, and no process sets a longer one.

`ListSigningKeys` publishes the set: every key's `kid` and public key, unpaged, since there are at most three. It's one use case that `IdentityService` holds in its anyone group, since public keys aren't secret, and `IdentityInternalService` holds as well, as Catalog's `GetBook` is ([a use case](use-cases.md#a-use-case)); it runs on Identity's tenant database, which sees the untenanted table whole. Every service's serve process calls the internal one, so Identity's `grpc.server.internalCallers` lists each serve process (`loans`, `catalog`) beside its other callers (`loans-worker`); the gateway calls the public one and serves the set at `/.well-known/jwks.json` ([controllers](gateway.md#controllers)).

Every process keeps the `JWTKeyCollection` its `JWTAuthenticator` shares in step with the set through `<Project>Transport`'s refresher:

```swift
public import Configuration
public import JWTKit
public import Logging
public import ServiceLifecycle

/// Keeps a key collection in step with the signing keys Identity publishes.
///
/// ## Configuration keys
/// - `refreshIntervalSeconds` (int, default 300): how often the set is fetched.
public struct SigningKeyRefresher: Service {
    public init(
        config: ConfigReader,
        keys: JWTKeyCollection,
        logger: Logger,
        fetch: @escaping @Sendable () async throws -> JWKS,
        onFirstRefresh: @escaping @Sendable () -> Void
    ) {
        …
    }

    /// Fetches the set at once, then every interval, until graceful shutdown.
    public func run() async throws {
        …
    }
}
```

- `<project>-core` doesn't depend on `<project>-protos`, so the executable passes the fetch: a service's fetch calls `IdentityInternalService` through its Identity client, the gateway's calls `IdentityService`, and Identity's calls its own `ListSigningKeysUseCase` ([the composition root](composition.md#the-composition-root)). Each converts the answer with `JWKS(_:)` ([folders](conventions.md#folders)), one RFC 7517 key per row: `kty` `OKP`, `crv` `Ed25519`, `alg` `EdDSA`, `use` `sig`, the `kid`, and the public key in base64url as `x`.
- A refresh adds the fetched keys, then removes the rest with `removeAll(except:)`, so no key a live token names is missing mid-refresh. That call also clears the collection's default key, which would otherwise go on verifying a deleted key's tokens; a token that names no `kid`, or a deleted one, fails as `unauthenticated`.
- The first fetch runs as the group starts. A failed first fetch ends the process, as a missing certificate fails startup; until then the process isn't serving ([health](composition.md#health)).
- After that, a failed fetch keeps the last good set and logs a warning, as a failed certificate reload does: Identity's outage stops no process verifying, and only delays which keys it learns.

swift-authentication-jwt's `JWTIssuer` signs with its collection's default key and writes no `kid`, so Identity signs with `JWTCredentialIssuer`, its own `CredentialIssuer<UserIdentity, String>` in the provider target `IdentityJWT`:

- Identity's fetch hands the keys to the issuer before converting them, so one refresh serves both: the issuer opens the current key with the key-encryption key and keeps it with its `kid`.
- `issue(for:)` signs with `JWTKeyCollection.sign(_:kid:)`, which writes that `kid` in the token's header, where every verifier looks the key up.
- The RPC's conversion takes each key's `kid` and public key only, so no sealed key leaves Identity.

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

- Configuration reads passwords, API keys, webhook secrets and the key-encryption key with `isSecret: true`, so access reporting redacts them; certificates and their keys are files at configured paths, never in an image or a repository.
- A secret value reaches the process as a file in `/run/secrets` named for its key, which `DirectoryFilesProvider` reads ([configuration](composition.md#configuration)), never as an environment variable: `docker inspect` and `/proc/<pid>/environ` show those to anyone who can read the container's configuration.
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
- The use case verifies before anything else, through a port its provider target implements (`NoticeEventVerifier`, `ResendNoticeEventVerifier`), with the signing secret read as a secret. A signature or timestamp the verifier refuses is the use case's `signatureRejected` ([status codes](grpc.md#status-codes)); checking the timestamp keeps a captured event from being replayed.
- It runs on the internal database: no caller is bound, so a tenant policy would hide every row ([database roles](persistence.md#database-roles)).
- Providers retry, so an event acts once: the transaction that acts also records the provider's event id under a unique key. A repeat that finds it changes nothing in the database, then starts the event's workflow, if it has one, as the first delivery did: the deterministic id joins a run that exists and starts one whose start was lost after the first commit.
- It answers once the event is recorded. Work that takes longer, or calls out, is a workflow the use case starts ([workflows a webhook starts](workflows.md#starting-a-workflow-from-a-use-case)).
