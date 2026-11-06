# gRPC

Contracts, the proto services a service implements, their handlers and conversions, interceptors, the clients that implement Core's ports, and transports.

## Contents
- Contracts in the protos package
- A service's gRPC services
- A handler
- Conversions
- Status codes
- Interceptors
- Clients for Core's ports
- Transports

## Contracts in the protos package

`<org>-protos/Sources/LoansProtos/bookshelf/loans/v1/loans.proto`:

```proto
syntax = "proto3";

package bookshelf.loans.v1;

import "google/protobuf/empty.proto";
import "google/protobuf/timestamp.proto";

message Loan {
  string id = 1;
  string user_id = 2;
  string book_id = 3;
  LoanStatus status = 4;
  google.protobuf.Timestamp due_date = 5;
  google.protobuf.Timestamp creation_date = 6;
}

enum LoanStatus {
  LOAN_STATUS_UNSPECIFIED = 0;
  LOAN_STATUS_ACTIVE = 1;
  LOAN_STATUS_OVERDUE = 2;
  LOAN_STATUS_RETURNED = 3;
}

message BorrowBookRequest {
  string book_id = 1;
  string idempotency_key = 2;
}

message ReturnBookRequest {
  string loan_id = 1;
}

message ListLoansResponse {
  repeated Loan loans = 1;
}

// Loans for people, through the gateway.
service LoanService {
  // The caller's own: the token names the member, so no request names one.
  rpc BorrowBook(BorrowBookRequest) returns (Loan);
  rpc ReturnBook(ReturnBookRequest) returns (Loan);
  rpc ListLoans(google.protobuf.Empty) returns (ListLoansResponse);

  // Administrators: every member's loans.
  rpc ListAllLoans(google.protobuf.Empty) returns (ListLoansResponse);
}
```

- The file is `<org>/<service>/v1/<service>.proto` in package `<org>.<service>.v1`. Generated types take the package as a prefix: `Bookshelf_Loans_V1_Loan`, `Bookshelf_Loans_V1_LoanService`.
- Comments in the contract say who calls each group of RPCs and what a request may name.
- Fields are snake_case. An enum's values carry its name as a prefix, and value 0 is `…_UNSPECIFIED`, which a receiver refuses.
- Ids are lowercase UUID strings, instants `google.protobuf.Timestamp`, nothing `google.protobuf.Empty`. A list comes back in its own `List…Response`, so fields can join it later.
- A field number is never reused or renumbered; a removed field's number and name are `reserved`. An incompatible change is a new `v2` package beside `v1` until no caller uses `v1`.
- Contracts are released before the services that implement or call them, and services pin the release.

## A service's gRPC services

Each proto service is one struct in XGRPC, conforming to the generated `SimpleServiceProtocol` and holding a use case per RPC:

```swift
package import GRPCCore
package import LoansCore
package import LoansProtos
import Authentication
import BookshelfAuthentication
import OperationContext
import SwiftProtobuf

/// Loans for people, through the gateway, grouped as the contract groups them.
///
/// The bearer interceptor identifies the caller when a token is present, and the settings
/// interceptor binds the tenant; each handler requires what its group needs.
package struct LoanService: Bookshelf_Loans_V1_LoanService.SimpleServiceProtocol {
    private let borrowBookUseCase: any BorrowBookUseCaseProtocol
    private let returnBookUseCase: any ReturnBookUseCaseProtocol
    private let listLoansUseCase: any ListLoansUseCaseProtocol
    private let listAllLoansUseCase: any ListAllLoansUseCaseProtocol

    package init(…) {
        …
    }

    // MARK: - The caller's own

    package func borrowBook(…) async throws -> Bookshelf_Loans_V1_Loan { … }
    package func returnBook(…) async throws -> Bookshelf_Loans_V1_Loan { … }
    package func listLoans(…) async throws -> Bookshelf_Loans_V1_ListLoansResponse { … }

    // MARK: - Administrators

    package func listAllLoans(…) async throws -> Bookshelf_Loans_V1_ListLoansResponse { … }

    // MARK: - Caller

    /// The interceptor identifies a user without requiring one; the caller's own RPCs require one.
    private func requireUser() throws -> UserIdentity {
        guard let user = OperationContext.current.user else {
            throw RPCError(code: .unauthenticated, message: "Authentication is required.")
        }

        return user.identity
    }

    /// An early gate for administrators' RPCs; each use case checks the role again.
    private func requireAdministrator() throws -> UserIdentity {
        let subject = try requireUser()
        guard subject.role == .admin else {
            throw RPCError(code: .permissionDenied, message: "Administrator access is required.")
        }

        return subject
    }
}
```

- `SimpleServiceProtocol` gives each RPC a plain request and response; `ServiceProtocol` is for streaming or for reading request metadata in a handler.
- `XService` and `XInternalService` are separate structs. An internal handler requires no user: mTLS admitted its caller, and its request names the user it acts on.
- The service holds use cases only: no repositories, ports, databases or rules.

## A handler

```swift
package func borrowBook(
    request: Bookshelf_Loans_V1_BorrowBookRequest,
    context: ServerContext
) async throws -> Bookshelf_Loans_V1_Loan {
    let subject = try requireUser()
    let input = try BorrowBookUseCaseInput(request)

    do {
        let loan = try await borrowBookUseCase(subject: subject, input: input)
        return Bookshelf_Loans_V1_Loan(loan)
    } catch BorrowBookUseCaseError.invalidIdempotencyKey {
        throw RPCError(code: .invalidArgument, message: "A valid idempotency key is required.")
    } catch BorrowBookUseCaseError.bookNotFound {
        throw RPCError(code: .notFound, message: "The book was not found.")
    } catch BorrowBookUseCaseError.loanLimitReached {
        throw RPCError(code: .failedPrecondition, message: "The loan limit has been reached.")
    } catch BorrowBookUseCaseError.idempotencyConflict {
        throw RPCError(code: .failedPrecondition, message: "The idempotency key was used to borrow another book.")
    } catch BorrowBookUseCaseError.catalogUnavailable {
        throw RPCError(code: .unavailable, message: "The catalog is unavailable.")
    } catch BorrowBookUseCaseError.unknown {
        throw RPCError(code: .internalError, message: "The book could not be borrowed.")
    }
}
```

1. Require the caller the RPC's group needs (`requireUser()`, `requireAdministrator()`, or nothing).
2. Convert the request before the `do`: a malformed request is refused as `invalidArgument` by the conversion.
3. The `do` holds the use case call and the response's conversion; one `catch` per case of the use case's error, in the order the enum declares them.
4. No catch-all, and no logging: the use case logged what happened. Because the handler `throws`, the compiler doesn't flag a case left out; a case added to an error is added to every handler that maps it, and one that slips through reaches the client as `unknown`.

## Conversions

Conversions live in `Protobuf/`, one file per type, `Type+Protobuf.swift`, as unlabeled initializers on the type being made:

```swift
extension BorrowBookUseCaseInput {
    init(_ request: Bookshelf_Loans_V1_BorrowBookRequest) throws {
        guard let bookID = UUID(uuidString: request.bookID) else {
            throw RPCError(code: .invalidArgument, message: "book_id must be a UUID.")
        }

        self.init(bookID: bookID, idempotencyKey: request.idempotencyKey)
    }
}

extension Bookshelf_Loans_V1_Loan {
    init(_ loan: Loan) {
        self.init()
        self.id = loan.id.uuidString.lowercased()
        self.userID = loan.userID.uuidString.lowercased()
        self.bookID = loan.bookID.uuidString.lowercased()
        self.status = Bookshelf_Loans_V1_LoanStatus(loan.status)
        self.dueDate = Google_Protobuf_Timestamp(date: loan.dueDate)
        self.creationDate = Google_Protobuf_Timestamp(date: loan.creationDate)
    }
}
```

- Into Core, a conversion refuses what the wire allows and the domain doesn't: an id that isn't a UUID, an `…_UNSPECIFIED` or unrecognized enum value.
- Out of Core, a conversion is total: every case of a Core enum maps to a proto value in an exhaustive `switch`.
- Conversions are the only code that sees both a generated type and a Core type.

## Status codes

| The use case's case | Status |
|---|---|
| Malformed or invalid input (`invalid…`) | `invalidArgument` |
| What the request names doesn't exist (`…NotFound`) | `notFound` |
| What the request creates exists (`duplicate…`) | `alreadyExists` |
| The current state refuses it (`loanLimitReached`, `alreadyReturned`, `idempotencyConflict`) | `failedPrecondition` |
| The caller may not (`forbidden`) | `permissionDenied` |
| A dependency is down (`…Unavailable`) | `unavailable` |
| `unknown` | `internalError` |

A missing caller is `unauthenticated`, from `requireUser()`. A message is one sentence for the client, ending in a period, naming nothing internal. A `notFound` and a `permissionDenied` that would reveal whether another user's resource exists answer the same as each other.

## Interceptors

The server's pipeline applies to the person-facing descriptors only:

```swift
interceptorPipeline: [
    .apply(
        BearerAuthenticationInterceptor(authenticator: authenticator),
        to: .services([Bookshelf_Loans_V1_LoanService.descriptor])
    ),
    .apply(
        UserSettingsInterceptor(),
        to: .services([Bookshelf_Loans_V1_LoanService.descriptor])
    ),
]
```

- `BearerAuthenticationInterceptor` proves a bearer token if there is one and binds the principal; an invalid token ends the call as `unauthenticated` before the handler runs, and a missing one continues unbound.
- `UserSettingsInterceptor` comes after it, on the same descriptors, in a service with tenant tables.
- `XInternalService` descriptors carry neither: the listener's mTLS trust admits their callers.
- Clients a service uses to reach other services' internal RPCs carry no interceptor. Forwarding the caller's token with `BearerPropagationInterceptor` is the gateway's ([upstream clients](gateway.md#upstream-clients)).

## Clients for Core's ports

A port to another service is a struct in XGRPC's `Clients/`, generic over the transport, wrapping the generated client of the other service's internal contract:

```swift
package import GRPCCore
package import LoansCore
import CatalogProtos

/// `CatalogClient` over Catalog's internal contract, as this process, proved by its certificate.
package struct GRPCCatalogClient<Transport: ClientTransport>: CatalogClient {
    private let client: Bookshelf_Catalog_V1_BookInternalService.Client<Transport>

    package init(client: GRPCClient<Transport>) {
        self.client = Bookshelf_Catalog_V1_BookInternalService.Client(wrapping: client)
    }

    package func book(id: UUID) async throws -> Book? {
        let request = Bookshelf_Catalog_V1_GetBookRequest.with {
            $0.id = id.uuidString.lowercased()
        }

        do {
            return try Book(try await client.getBook(request))
        } catch let error as RPCError where error.code == .notFound {
            return nil
        } catch let error as RPCError where error.code == .unavailable || error.code == .deadlineExceeded {
            throw CatalogClientError.unavailable
        }
    }
}
```

- It translates only the statuses a use case acts on; any other error propagates unchanged, so the use case that logs it logs its cause.
- `notFound` on a lookup becomes `nil`, matching the port's optional.
- The response conversion (`Book+Protobuf.swift` in `Clients/Protobuf/`) throws on a malformed message rather than inventing a value.
- Every call has a deadline: the client's `ServiceConfig` sets one for all methods, and a port that needs a tighter bound passes `CallOptions` with its own `timeout`.

## Transports

Built in the executable from `<Org>Transport`'s readers ([mutual TLS](security.md#mutual-tls)):

```swift
let server = GRPCServer(
    transport: .http2NIOPosix(
        address: .ipv4(host: try serverConfig.requiredString(forKey: "host"), port: try serverConfig.requiredInt(forKey: "port")),
        transportSecurity: try .mTLS(config: tlsConfig, certificateReloader: certificateReloader),
        config: HTTP2ServerTransport.Posix.Config(config: serverConfig)
    ),
    services: [loanService],
    interceptorPipeline: […]
)

let catalog = GRPCClient(
    transport: try .http2NIOPosix(
        target: .dns(host: try catalogConfig.requiredString(forKey: "host"), port: try catalogConfig.requiredInt(forKey: "port")),
        transportSecurity: try .mTLS(config: tlsConfig, certificateReloader: certificateReloader),
        config: HTTP2ClientTransport.Posix.Config(config: catalogConfig),
        serviceConfig: ServiceConfig(config: catalogConfig)
    )
)
```

- The server's config bounds a connection's age (`maxConnectionAgeSeconds`, `connectionGraceTimeSeconds`), so clients reconnect with renewed certificates and drain in-flight calls, and accepts idle keepalive pings.
- A client's host is the name in the peer certificate's DNS names. Its config sends keepalive pings on idle connections; its `ServiceConfig` waits for a ready connection, bounded by a deadline, so a transient reconnect doesn't fail a call and a down upstream still does.
- One long-lived `GRPCClient` per upstream process, shared by every port and handler that calls it, run in the `ServiceGroup`. `GRPCServiceLifecycle` makes `GRPCServer` and `GRPCClient` services.
- `GRPCHealthService` from grpc-swift-extras answers health checks when the platform probes gRPC health.
