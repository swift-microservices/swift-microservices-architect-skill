# The gateway

The public HTTP API: a Hummingbird application that verifies the caller, chooses a route's tier by request context, and forwards each request with the caller's token to the owning service.

## Contents
- What the gateway is
- The package
- OpenAPI types
- Request contexts and tiers
- The router
- Controllers
- Conversions
- Errors
- Upstream clients
- The edge

## What the gateway is

- The only process clients reach. Every service listens privately, for gRPC over mTLS.
- It owns the HTTP contract, `openapi.yaml`, and its conversion onto the services' `XService` contracts.
- It owns no tables, no business rules and no use cases. It verifies a token only to choose a tier and to refuse early; each service verifies it again ([user tokens](security.md#user-tokens)).
- It never routes to an `XInternalService`.

## The package

```
bookshelf-gateway/Sources/
├── GatewayHTTP/
│   ├── openapi.yaml, openapi-generator-config.yaml
│   ├── BookshelfAPI.swift          the router builder and its dependencies
│   ├── Contexts/                   IdentityRequestContext.swift, AdminRequestContext.swift
│   ├── Controllers/                AccountController.swift, BookController.swift, LoanController.swift, ResendWebhookController.swift
│   ├── Middlewares/                ErrorMiddleware/: ErrorMiddleware.swift, Problem.swift, HTTPResponse.Status+RPCError.swift
│   └── Schemas/                    Requests/, Responses/, Shared/: X+RPC.swift conversions
└── Gateway/
    ├── Gateway.swift               the @main command
    ├── Configuration/              InMemoryProvider+ApplicationDefaults.swift
    └── Serve/                      Serve.swift
```

## OpenAPI types

`GatewayHTTP` generates types only, with the OpenAPI generator plugin:

```yaml
generate:
  - types
accessModifier: package
namingStrategy: idiomatic
```

- The routes are Hummingbird's, so request contexts and middleware stay native; the generated `Components.Schemas` types are the request and response bodies.
- `openapi.yaml` is the contract clients code against: it changes before the routes do, and a route answers exactly the statuses it documents.
- Not every generated file uses each of its imports; the gateway's toolchain and generator versions keep them from warning ([choosing versions](stack.md#choosing-versions)).

## Request contexts and tiers

Each group of routes runs in the context that states what it guarantees:

| Tier | Context | Guarantees |
|---|---|---|
| No caller | `BasicRequestContext` | Nothing: registration, sign-in, refresh, public reads, signed webhooks |
| A caller, if there is one | `IdentityRequestContext`, behind `BearerAuthenticationMiddleware` | A token present was valid; `identity` is optional |
| A caller, required | `IdentityRequestContext`, behind `IsAuthenticatedMiddleware` | `identity` is set |
| Administrators | `AdminRequestContext`, converted at the verb | A non-optional administrator `identity` |

```swift
package struct IdentityRequestContext: ChildRequestContext, AuthRequestContext {
    package var coreContext: CoreRequestContextStorage
    package var identity: UserIdentity?

    /// Carries the parent's storage rather than rebuilding it: path parameters are already
    /// extracted by the time a child context is made.
    package init(context: BasicRequestContext) throws {
        self.coreContext = context.coreContext
        self.identity = nil
    }
}

/// A caller checked to be an administrator: reaching a handler through this context is the proof.
package struct AdminRequestContext: ChildRequestContext {
    package var coreContext: CoreRequestContextStorage
    package let identity: UserIdentity

    package init(context: IdentityRequestContext) throws {
        guard let identity = context.identity else {
            throw HTTPError(.unauthorized, message: "Authentication is required.")
        }

        guard identity.role == .admin else {
            throw HTTPError(.forbidden, message: "Administrator access is required.")
        }

        self.coreContext = context.coreContext
        self.identity = identity
    }
}
```

- A child context's throwing initializer is the check: a handler that takes `AdminRequestContext` never re-tests the role.
- Absent and insufficient answer differently: `401` when no one identified, `403` when the caller can't do this whatever token they hold.
- The administrator check happens at the verb, not behind an `/admin` path prefix, so a resource's path is shared by its audiences. `/admin/…` is only for an administrator's view of a collection that callers also list (`/admin/loans`).
- A route whose bearer token isn't an access token, such as the refresh token a refresh request presents, stays in the first tier: `BearerAuthenticationMiddleware` refuses any bearer token it can't verify. Sign-in, with Basic credentials or a body, is in the first tier too, since there is no caller yet.

## The router

```swift
/// The whole HTTP surface, built from the clients it needs and nothing else.
package struct BookshelfAPI: Sendable {
    private let dependencies: Dependencies

    package init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    package func addRoutes(to group: RouterGroup<BasicRequestContext>) {
        let accountController = AccountController(client: dependencies.identity)
        let bookController = BookController(client: dependencies.books)
        let loanController = LoanController(client: dependencies.loans)
        let resendWebhookController = ResendWebhookController(client: dependencies.loans)

        // MARK: - No caller

        accountController.addPublicRoutes(to: group.group("account"))
        bookController.addPublicRoutes(to: group.group("books"))
        resendWebhookController.addPublicRoutes(to: group.group("webhooks/resend"))

        // MARK: - A caller, if there is one

        let bearerAuthentication = BearerAuthenticationMiddleware<IdentityRequestContext>(authenticator: dependencies.authenticator)
        let identified = group
            .group(context: IdentityRequestContext.self)
            .add(middleware: bearerAuthentication)

        // MARK: - A caller, required

        let authenticated = identified
            .group()
            .add(middleware: IsAuthenticatedMiddleware())

        accountController.addAuthenticatedRoutes(to: authenticated.group("account"))
        bookController.addAuthenticatedRoutes(to: authenticated.group("books"))
        loanController.addAuthenticatedRoutes(to: authenticated.group("loans"))
        loanController.addAdministratorRoutes(to: authenticated.group("admin/loans"))
    }
}

extension BookshelfAPI {
    /// One generated client per upstream proto service, and the authenticator for the tiers.
    package struct Dependencies: Sendable {
        package let authenticator: any Authenticator<String, UserIdentity>
        package let identity: any Bookshelf_Identity_V1_IdentityService.ClientProtocol
        package let books: any Bookshelf_Catalog_V1_BookService.ClientProtocol
        package let loans: any Bookshelf_Loans_V1_LoanService.ClientProtocol

        package init(…) {
            …
        }
    }
}
```

- `add(middleware:)` changes the group it's called on, for every route added after it. Each tier is its own group (`identified.group()`), so a tier's middleware never reaches a sibling tier's routes.
- The router builder takes its clients and the authenticator as dependencies; the executable builds them, which keeps the whole surface buildable over stub clients.

## Controllers

One controller per resource, holding the client of the proto service behind it:

```swift
/// The `/v1/loans` resource: the caller's own loans, and every member's for administrators.
package struct LoanController: Sendable {
    private let client: any Bookshelf_Loans_V1_LoanService.ClientProtocol

    package init(client: any Bookshelf_Loans_V1_LoanService.ClientProtocol) {
        self.client = client
    }

    /// Wired at `loans`.
    package func addAuthenticatedRoutes(to group: RouterGroup<IdentityRequestContext>) {
        group
            .post(use: borrowBook)
            .get(use: listLoans)
            .post(":id/return", use: returnBook)
    }

    /// Wired at `admin/loans`.
    package func addAdministratorRoutes(to group: RouterGroup<IdentityRequestContext>) {
        group
            .group(context: AdminRequestContext.self)
            .get(use: listAllLoans)
    }

    private func borrowBook(
        request: Request,
        context: IdentityRequestContext
    ) async throws -> EditedResponse<Components.Schemas.LoanResponse> {
        let body = try await request.decode(as: Components.Schemas.BorrowBookRequest.self, context: context)
        let borrowBookRequest = Bookshelf_Loans_V1_BorrowBookRequest(body)
        let loan = try await client.borrowBook(borrowBookRequest)
        let response = try Components.Schemas.LoanResponse(loan)
        return EditedResponse(status: .created, response: response)
    }

    private func returnBook(
        request: Request,
        context: IdentityRequestContext
    ) async throws -> Components.Schemas.LoanResponse {
        let loanID = try context.parameters.require("id", as: UUID.self)
        let returnBookRequest = Bookshelf_Loans_V1_ReturnBookRequest.with {
            $0.loanID = loanID.uuidString.lowercased()
        }
        let loan = try await client.returnBook(returnBookRequest)
        return try Components.Schemas.LoanResponse(loan)
    }

    …
}
```

- A controller registers its routes in `addPublicRoutes(to:)`, `addAuthenticatedRoutes(to:)` and `addAdministratorRoutes(to:)`, each taking the group of its tier; the router decides the paths.
- A handler is a `private func` with the signature `(Request, Context) async throws -> Response`: decode the body or parameters, call the client, convert the answer. Nothing else.
- The caller's own routes send no user id upstream: the forwarded token names the caller.
- Status codes follow the method: `201` with `EditedResponse` for a create, `202` for work accepted to run later, `204` (`HTTPResponse.Status.noContent`) for a change with nothing to return, `200` otherwise.
- Hummingbird keys a path capture by one name per segment, so every route on one path shares its capture name (`:id`).

A provider's webhooks get a controller of their own, in the first tier at `webhooks/<provider>`, that forwards each event unparsed:

```swift
/// Resend's delivery events, forwarded to Loans as Resend signed them.
package struct ResendWebhookController: Sendable {
    /// Resend's events are small, so a larger body is refused before it's read.
    private static let maximumEventSize = 1_048_576
    private let client: any Bookshelf_Loans_V1_LoanService.ClientProtocol

    …

    private func receiveNoticeEvent(
        request: Request,
        context: BasicRequestContext
    ) async throws -> HTTPResponse.Status {
        let body = try await request.body.collect(upTo: Self.maximumEventSize)
        let eventRequest = try Bookshelf_Loans_V1_ReceiveNoticeEventRequest(body: body, headers: request.headers)
        _ = try await client.receiveNoticeEvent(eventRequest)
        return .noContent
    }
}
```

- The conversion copies the bytes and the provider's signature headers unchanged, refusing a request missing one as `400`; the service verifies them ([webhooks](security.md#webhooks)).
- A body over the limit answers `413` through `ErrorMiddleware`.

## Conversions

`Schemas/Requests/` and `Schemas/Responses/` hold one file per type, `XRequest+RPC.swift` and `XResponse+RPC.swift`:

```swift
extension Components.Schemas.LoanResponse: ResponseCodable {
    init(_ loan: Bookshelf_Loans_V1_Loan) throws {
        guard let id = UUID(uuidString: loan.id), let bookID = UUID(uuidString: loan.bookID) else {
            throw HTTPError(.internalServerError, message: "The loan record is malformed.")
        }

        let status = try Components.Schemas.LoanStatus(loan.status)
        self.init(id: id, bookID: bookID, status: status, dueDate: loan.dueDate.date)
    }
}

extension Bookshelf_Loans_V1_BorrowBookRequest {
    init(_ body: Components.Schemas.BorrowBookRequest) {
        self.init()
        self.bookID = body.bookID.uuidString.lowercased()
        self.idempotencyKey = body.idempotencyKey
    }
}
```

- A response conversion throws on a malformed upstream value, such as a non-UUID id or an unspecified enum, answering `500` rather than dropping or inventing a field.
- A body field the client omits reaches the service as the proto default; the service's conversion decides what an empty value means.
- A paged route reads `pageSize` and `pageToken` or `page` from the query, answers the items with `pageInfo` or `nextPageToken`, and passes each through unchanged; the service applies [the paging rules](grpc.md#lists-and-pages).

## Errors

`ErrorMiddleware`, on the router after CORS, turns every failure into RFC 9457 problem details (`application/problem+json`), one `catch` per kind of error:

```swift
/// Turns every failure on the router into a `Problem`, which the router renders.
package struct ErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    package init() {}

    package func handle(
        _ request: Request,
        context: Context,
        next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as HTTPError {
            throw Problem(status: error.status, detail: error.body)
        } catch let error as any HTTPResponseError {
            throw Problem(status: error.status)
        } catch let error as RPCError where HTTPResponse.Status(error.code).kind == .clientError {
            let status = HTTPResponse.Status(error.code)
            throw Problem(status: status, detail: error.message)
        } catch let error as RPCError {
            context.logger.error("Upstream call failed", metadata: ["error": "\(String(reflecting: error))"])
            let status = HTTPResponse.Status(error.code)
            throw Problem(status: status)
        } catch {
            context.logger.error("Request failed: unknown error", metadata: ["error": "\(String(reflecting: error))"])
            throw Problem(status: .internalServerError)
        }
    }
}

/// RFC 9457 problem details. Without a `type`, a problem means what its status means.
package struct Problem: HTTPResponseError {
    package let status: HTTPResponse.Status
    package let detail: String?

    package init(status: HTTPResponse.Status, detail: String? = nil) {
        …
    }

    package func response(from request: Request, context: some RequestContext) throws -> Response {
        let body = Body(title: status.reasonPhrase, status: status.code, detail: detail, instance: request.uri.path)
        var response = try context.responseEncoder.encode(body, from: request, context: context)
        response.status = status
        response.headers[.contentType] = "application/problem+json"
        return response
    }

    private struct Body: Encodable {
        …  // title, status, detail, instance
    }
}
```

- Each `catch` throws its `Problem`, and nothing follows the `do`: the router renders a thrown `HTTPResponseError` with its `response(from:context:)`, and CORS adds its headers on the way out.
- A refusal answers in its own words: an `HTTPError`'s message, which the gateway or Hummingbird wrote, and a `4xx` upstream's message, which the service wrote for clients ([status codes](grpc.md#status-codes)).
- An upstream's server error answers its status alone, since a transport's message can name internal hosts. It's logged with its cause, as is anything that isn't an HTTP or RPC error, which answers `500`.
- Hummingbird's other `HTTPResponseError`s keep their status, such as `413` for a body over the upload limit. Router middleware also wraps the not-found responder, so an unmatched path's `404` is a problem too.
- `RPCError` gets no retroactive `HTTPResponseError` conformance: the middleware is the one place it becomes a status.
- `openapi.yaml` declares the `Problem` schema once and references it from every error response a route documents.

`HTTPResponse.Status.init(_ code: RPCError.Code)`, a `switch` with a `default`, maps the codes:

| `RPCError.Code` | HTTP |
|---|---|
| `invalidArgument`, `failedPrecondition`, `outOfRange` | `400` |
| `unauthenticated` | `401` |
| `permissionDenied` | `403` |
| `notFound` | `404` |
| `alreadyExists`, `aborted` | `409` |
| `resourceExhausted` | `429` |
| `cancelled` | `499` |
| `unimplemented` | `501` |
| `unavailable` | `503` |
| `deadlineExceeded` | `504` |
| `unknown`, `internalError`, `dataLoss`, anything else | `500` |

## Upstream clients

The executable builds one `GRPCClient` per upstream service over mTLS, its transport built like any client's ([transports](grpc.md#transports)), with `BearerPropagationInterceptor` applied to the descriptors the gateway calls ([the gateway's root](composition.md#the-gateways-root)).

- Propagation presents the caller's original token, as `BearerAuthenticationMiddleware` bound it, when a route identified a caller; a public route's call goes upstream anonymously.
- A service with several proto services behind one process gets one client, with every descriptor the gateway calls in its propagation list.
- `BookshelfAPI.Dependencies` holds each as the generated client protocol: `Bookshelf_Loans_V1_LoanService.Client(wrapping: loans)`.

## The edge

- Clients reach the gateway over TLS, terminated by the edge in front of it (a CDN or reverse proxy, which may itself re-encrypt to the proxy beside the gateway). The gateway listens for plain HTTP on its private interface; it never configures TLS for clients.
- CORS is the gateway's, in `CORSMiddleware` first on the router, for the origins, headers and methods browsers use ([the gateway's root](composition.md#the-gateways-root)).
