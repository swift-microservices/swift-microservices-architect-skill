# gRPC

Contracts, the proto services a service implements, their handlers and conversions, interceptors, the clients that implement Core's ports, and transports.

## Contents
- Contracts in the protos package
- A service's gRPC services
- A handler
- An internal service
- Conversions
- Lists and pages
- Status codes
- Interceptors
- Clients for Core's ports
- Transports

## Contracts in the protos package

`<project>-protos/Sources/LoansProtos/bookshelf/loans/v1/loans.proto`:

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

message ListLoansRequest {
  int32 page_size = 1;
  int32 page = 2;
}

message ListLoansResponse {
  repeated Loan loans = 1;
  PageInfo page_info = 2;
}

message PageInfo {
  int32 page = 1;
  int32 page_size = 2;
  int32 total_count = 3;
  int32 total_pages = 4;
}

message ListAllLoansRequest {
  int32 page_size = 1;
  string page_token = 2;
}

message ListAllLoansResponse {
  repeated Loan loans = 1;
  string next_page_token = 2;
}

message ReceiveNoticeEventRequest {
  bytes payload = 1;
  map<string, string> signature_headers = 2;
}

// Loans for people, through the gateway.
service LoanService {
  // Anyone: Resend's delivery events for overdue notices, proved by their signature.
  rpc ReceiveNoticeEvent(ReceiveNoticeEventRequest) returns (google.protobuf.Empty);

  // The caller's own: the token names the member, so no request names one.
  rpc BorrowBook(BorrowBookRequest) returns (Loan);
  rpc ReturnBook(ReturnBookRequest) returns (Loan);
  rpc ListLoans(ListLoansRequest) returns (ListLoansResponse);

  // Administrators: every member's loans.
  rpc ListAllLoans(ListAllLoansRequest) returns (ListAllLoansResponse);
}
```

- The file and package are named as [naming](conventions.md#naming) gives them. Generated types take the package as a prefix: `Bookshelf_Loans_V1_Loan`, `Bookshelf_Loans_V1_LoanService`.
- Comments in the contract say who calls each group of RPCs and what a request may name.
- Fields are snake_case. An enum's values carry its name as a prefix, and value 0 is `…_UNSPECIFIED`, which a receiver refuses.
- Ids are lowercase UUID strings, instants `google.protobuf.Timestamp`, nothing `google.protobuf.Empty`.
- A list that can grow large pages from its first version, by key or by page number ([lists and pages](#lists-and-pages)).
- A provider's webhook is an anyone RPC taking the body unparsed as `bytes payload` and the headers the provider signs with as `signature_headers`, keyed by lowercased name ([webhooks](security.md#webhooks)).
- A field number is never reused or renumbered; a removed field's number and name are `reserved`. An incompatible change is a new `v2` package beside `v1` until no caller uses `v1`. Before a contract's first deploy it changes in place, with no `v2`, as a major release of `<project>-protos`.
- Contracts release before the services that implement or call them ([the project's core package](packages.md#the-projects-core-package)). A service that serves a new RPC or field deploys before any caller or gateway route that uses it, and never removes an RPC a deployed caller still uses.

## A service's gRPC services

Each proto service is one struct in XGRPC, conforming to the generated `SimpleServiceProtocol` and holding a use case per RPC:

```swift
import Authentication
import BookshelfAuthentication
package import GRPCCore
package import LoansCore
package import LoansProtos
import OperationContext
package import SwiftProtobuf

/// Loans for people, through the gateway, grouped as the contract groups them.
///
/// The bearer interceptor identifies the caller when a token is present, and the settings
/// interceptor binds the tenant; each handler requires what its group needs.
package struct LoanService: Bookshelf_Loans_V1_LoanService.SimpleServiceProtocol {
    private let receiveNoticeEventUseCase: any ReceiveNoticeEventUseCaseProtocol
    private let borrowBookUseCase: any BorrowBookUseCaseProtocol
    private let returnBookUseCase: any ReturnBookUseCaseProtocol
    private let listLoansUseCase: any ListLoansUseCaseProtocol
    private let listAllLoansUseCase: any ListAllLoansUseCaseProtocol

    package init(…) {
        …
    }

    // MARK: - Anyone

    package func receiveNoticeEvent(…) async throws -> Google_Protobuf_Empty { … }

    // MARK: - The caller's own

    package func borrowBook(…) async throws -> Bookshelf_Loans_V1_Loan { … }
    package func returnBook(…) async throws -> Bookshelf_Loans_V1_Loan { … }
    package func listLoans(…) async throws -> Bookshelf_Loans_V1_ListLoansResponse { … }

    // MARK: - Administrators

    package func listAllLoans(…) async throws -> Bookshelf_Loans_V1_ListAllLoansResponse { … }

    // MARK: - Caller

    /// The interceptor identifies a user without requiring one; the caller's own and
    /// administrators' RPCs require one.
    private func requireUser() throws -> UserIdentity { … }
}
```

- `SimpleServiceProtocol` gives each handler its messages; `ServiceProtocol` is only for a handler that reads request metadata or sets response metadata. A response-streaming handler runs after the interceptors have returned, so nothing they bound is visible in it: an RPC that needs the caller or the tenant answers with one message.
- `XService` and `XInternalService` are separate structs ([an internal service](#an-internal-service)).
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

1. Require a caller for the caller's own and administrators' RPCs (`requireUser()`); anyone's require nothing.
2. Convert the request before the `do`: a malformed request is refused as `invalidArgument` by the conversion.
3. The `do` holds the use case call and the response's conversion; one `catch` per case of the use case's error, in the order the enum declares them.
4. No catch-all, and no logging: the use case logged what happened. Because the handler `throws`, the compiler doesn't flag a case left out; a case added to an error is added to every handler that maps it, and one that slips through reaches the client as `unknown`.

## An internal service

`XInternalService` holds the use cases other processes call. Catalog's, which Loans' `GRPCCatalogClient` reaches:

```swift
/// Books for other services and workers, admitted by their certificates.
package struct BookInternalService: Bookshelf_Catalog_V1_BookInternalService.SimpleServiceProtocol {
    private let getBookUseCase: any GetBookUseCaseProtocol

    package init(getBookUseCase: any GetBookUseCaseProtocol) {
        self.getBookUseCase = getBookUseCase
    }

    package func getBook(
        request: Bookshelf_Catalog_V1_GetBookRequest,
        context: ServerContext
    ) async throws -> Bookshelf_Catalog_V1_Book {
        let input = try GetBookUseCaseInput(request)

        do {
            let book = try await getBookUseCase(input: input)
            return Bookshelf_Catalog_V1_Book(book)
        } catch GetBookUseCaseError.bookNotFound {
            throw RPCError(code: .notFound, message: "The book was not found.")
        } catch GetBookUseCaseError.unknown {
            throw RPCError(code: .internalError, message: "The book could not be read.")
        }
    }
}
```

- A handler requires no caller, and no interceptor runs on its descriptor ([interceptors](#interceptors)).
- Its use cases take no `subject:`. One that acts for a user takes the user's id in its input, as Identity's `GetMember` takes `user_id` ([authorization](use-cases.md#authorization)).
- The server registers it beside `XService`: `services: [bookService, bookInternalService]`.

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

## Lists and pages

A list that can grow large pages; one a rule keeps small, such as a member's active loans, comes back whole. Paging is part of a list's first version, since paging added later silently cuts old clients' lists short. A paged list reads newest first by id, which `uuidv7()` orders by creation, in one of two ways:

| Paging | For | Request | Response metadata | Repository read |
|---|---|---|---|---|
| By page number | Simple lists a client steps through by number: a member's own loans (`ListLoans`) | `page_size`, `page` | `page_info`: page, page size, total count, total pages | `loans(userID:page:pageSize:)` → `Page<Loan>` |
| By key | Large or fast-growing lists: every member's loans (`ListAllLoans`) | `page_size`, `page_token` | `next_page_token`, empty after the last page | `loans(startingAfter:pageSize:)` → `KeyedPage<Loan>` |

- By page number, a client can jump to any page, but rows added between requests shift the pages, and a deep page scans every row before it. Pages count from 1.
- By key, the token is the page's last id, opaque to clients, and rows added between pages neither repeat nor go missing. A page carries a token only when another page follows.
- `page_size` 0 asks for the service's default and more than its maximum gets the maximum, both constants in `Protobuf/PageSize.swift`; `page` 0, a field the client left out, asks for the first page. A negative size or page, or a token the service didn't issue, is `invalidArgument`.
- The input carries what the repository's read takes, the use case returns the repository's page, and the response conversion copies its metadata ([paged statements](persistence.md#paged-statements)):

```swift
extension Bookshelf_Loans_V1_ListLoansResponse {
    init(_ page: Page<Loan>) {
        self.init()
        self.loans = page.items.map(Bookshelf_Loans_V1_Loan.init)
        self.pageInfo = Bookshelf_Loans_V1_PageInfo(page)
    }
}

extension Bookshelf_Loans_V1_ListAllLoansResponse {
    init(_ page: KeyedPage<Loan>) {
        self.init()
        self.loans = page.items.map(Bookshelf_Loans_V1_Loan.init)
        self.nextPageToken = page.nextCursor?.uuidString.lowercased() ?? ""
    }
}
```

## Status codes

| The use case's case | Status |
|---|---|
| Malformed or invalid input (`invalidIdempotencyKey`) | `invalidArgument` |
| The request's own proof fails (`signatureRejected`, `credentialsRejected`) | `unauthenticated` |
| What the request names doesn't exist (`…NotFound`) | `notFound` |
| What the request creates exists (`duplicate…`) | `alreadyExists` |
| The current state refuses it (`loanLimitReached`, `alreadyReturned`, `idempotencyConflict`) | `failedPrecondition` |
| The caller may not (`forbidden`) | `permissionDenied` |
| A dependency is down (`…Unavailable`) | `unavailable` |
| `unknown` | `internalError` |

A missing caller is `unauthenticated`, from `requireUser()`. A message is one sentence for the client, ending in a period, naming nothing internal.

## Interceptors

The server's interceptors apply to the person-facing descriptors only, as [the composition root](composition.md#the-composition-root) wires them:

- `BearerAuthenticationInterceptor` proves a bearer token if there is one and binds the principal; an invalid token ends the call as `unauthenticated` before the handler runs, and a missing one continues unbound.
- `UserSettingsInterceptor` follows it in a service with tenant tables ([binding the tenant](persistence.md#binding-the-tenant)).
- `XInternalService` descriptors carry neither: the listener's mTLS trust admits their callers.
- Clients a service uses to reach other services' internal RPCs carry no interceptor. Forwarding the caller's token with `BearerPropagationInterceptor` is the gateway's ([upstream clients](gateway.md#upstream-clients)).

## Clients for Core's ports

A port to another service is a struct in XGRPC's `Clients/`, generic over the transport, wrapping the generated client of the other service's internal contract:

```swift
/// `CatalogClient` over Catalog's internal contract, as this process, proved by its certificate.
package struct GRPCCatalogClient<Transport: ClientTransport>: CatalogClient {
    private let client: Bookshelf_Catalog_V1_BookInternalService.Client<Transport>

    package init(client: GRPCClient<Transport>) {
        self.client = Bookshelf_Catalog_V1_BookInternalService.Client(wrapping: client)
    }

    package func book(id: UUID) async throws -> Book? {
        do {
            let request = Bookshelf_Catalog_V1_GetBookRequest.with {
                $0.id = id.uuidString.lowercased()
            }
            let response = try await client.getBook(request)
            return try Book(response)
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

The executable builds the server's and each client's transport from `<Project>Transport`'s readers ([mutual TLS](security.md#mutual-tls)), as [the composition root](composition.md#the-composition-root) shows:

- One `clientSecurity` serves every client of the process, and each upstream gets its own scoped configuration (`grpc.catalog`) with its host, port, transport config and service config.
- The server's config bounds a connection's age (`maxConnectionAgeSeconds`, `connectionGraceTimeSeconds`), so clients reconnect with renewed certificates and drain in-flight calls, and accepts idle keepalive pings.
- A client's host is the name in the peer certificate's DNS names. Its config sends keepalive pings on idle connections; its `ServiceConfig` waits for a ready connection, bounded by a deadline, so a transient reconnect doesn't fail a call and a down upstream still does.
- A client neither retries nor hedges: its `ServiceConfig` sets only the deadline and wait-for-ready. Each call chain has one owner of retries: Temporal for activities, and the app calling the public API, with an idempotency key, for public creates. A port call inside an activity never retries on its own.
- One long-lived `GRPCClient` per upstream process, shared by every port and handler that calls it, run in the `ServiceGroup`. `GRPCServiceLifecycle` makes `GRPCServer` and `GRPCClient` services.
