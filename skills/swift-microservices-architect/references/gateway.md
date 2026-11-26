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
- Versions
- Upstream clients
- The edge

## What the gateway is

- The only process clients reach. Every service listens privately, for gRPC over mTLS.
- It owns the HTTP contract, `openapi.yaml`, and its conversion onto the services' `XService` contracts.
- It owns no tables, no business rules and no use cases.

## The package

```
bookshelf-gateway/Sources/
├── GatewayHTTP/
│   ├── openapi.yaml, openapi-generator-config.yaml
│   ├── BookshelfAPI.swift          the router builder
│   ├── Contexts/                   IdentityRequestContext.swift, AdministratorRequestContext.swift
│   ├── Controllers/                AccountController.swift, BookController.swift, LoanController.swift, ResendWebhookController.swift
│   ├── Middlewares/                ErrorMiddleware/: ErrorMiddleware.swift, Problem.swift, HTTPResponse.Status+RPCError.swift
│   └── Schemas/                    Requests/, Responses/, Shared/: Type+RPC.swift conversions
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
- `openapi.yaml` is the contract clients code against: it changes before the routes do, and a handler answers only the statuses its operation documents. Every operation documents `500`, `503` and `504` besides its own, through shared `Problem` responses; the statuses any route can answer before its handler runs or from the edge (`413`, `429`, `499`, `501`) are documented once, in the document's description:

```yaml
paths:
  /loans:
    post:
      operationId: borrowBook
      security:
        - bearerAuth: []
      …
      responses:
        "201":
          …
        "404":
          $ref: "#/components/responses/NotFound"
        "503":
          $ref: "#/components/responses/ServiceUnavailable"
        …

components:
  responses:
    ServiceUnavailable:
      description: A service the request needs is unavailable.
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    …
```

- It declares one `UUID` schema (`type: string`, `format: uuid`) that every id references, which the generator makes a `String` ([conversions](#conversions)).
- `servers` ends in `/v1`, and paths are written without it; a `/v2` route has its own ([versions](#versions)).
- A create a client may retry declares the `Idempotency-Key` header as a required parameter, once under `components/parameters` ([controllers](#controllers)).
- A page's schema is `<Resource>PageResponse`, its items under the resource's plural beside `pageInfo` or `nextPageToken`.
- Every operation has an `operationId` and a `security` entry for its tier: `[]` for no caller, `[{bearerAuth: []}]` for a caller or an administrator ([request contexts](#request-contexts-and-tiers)).

## Request contexts and tiers

Each group of routes runs in the context that states what it guarantees:

| Tier | Context | Guarantees |
|---|---|---|
| No caller | `BasicRequestContext` | Nothing: registration, sign-in, refresh, sign-out, public reads, signed webhooks |
| A caller | `IdentityRequestContext`, behind `BearerAuthenticationMiddleware` and `IsAuthenticatedMiddleware` | `identity` is set |
| Administrators | `AdministratorRequestContext`, converted at the verb | A non-optional administrator `identity` |

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
package struct AdministratorRequestContext: ChildRequestContext {
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

- A child context's throwing initializer is the check: a handler that takes `AdministratorRequestContext` never re-tests the role.
- The administrator check happens at the verb, in the context, never by a path prefix.
- Only administrators have a context of their own. A route for another role, such as a librarian's, is in the caller tier, and the use case behind it refuses the wrong role as `403` ([authorization](use-cases.md#authorization)): a context per role would copy the domain's rules into the gateway.
- A route whose bearer token isn't an access token, such as the refresh token a refresh, sign-out or change of organization presents, stays in the no-caller tier: `BearerAuthenticationMiddleware` refuses any bearer token it can't verify. Sign-in, with Basic credentials or a body, is in the no-caller tier too, since there is no caller yet.

## The router

```swift
/// The whole HTTP surface, built from the clients it needs and nothing else.
package struct BookshelfAPI: Sendable {
    private let authenticator: any Authenticator<String, UserIdentity>
    private let identityClient: any Bookshelf_Identity_V1_IdentityService.ClientProtocol
    private let bookClient: any Bookshelf_Catalog_V1_BookService.ClientProtocol
    private let loanClient: any Bookshelf_Loans_V1_LoanService.ClientProtocol

    package init(…) {
        …
    }

    package func addRoutes(to group: RouterGroup<BasicRequestContext>) {
        let accountController = AccountController(client: identityClient)
        let bookController = BookController(client: bookClient)
        let loanController = LoanController(client: loanClient)
        let resendWebhookController = ResendWebhookController(client: loanClient)

        // MARK: - No caller

        accountController.addPublicRoutes(to: group.group("account"))
        bookController.addPublicRoutes(to: group.group("books"))
        resendWebhookController.addPublicRoutes(to: group.group("webhooks/resend"))

        // MARK: - A caller

        let bearerAuthentication = BearerAuthenticationMiddleware<IdentityRequestContext>(authenticator: authenticator)
        let authenticated = group
            .group(context: IdentityRequestContext.self)
            .add(middleware: bearerAuthentication)
            .add(middleware: IsAuthenticatedMiddleware())

        accountController.addAuthenticatedRoutes(to: authenticated.group("account"))
        bookController.addAuthenticatedRoutes(to: authenticated.group("books"))
        loanController.addAuthenticatedRoutes(to: authenticated.group("loans"))
        loanController.addAdministratorRoutes(to: authenticated.group("admin/loans"))
    }
}
```

The router builder takes its clients and the authenticator in its initializer; the executable builds them, which keeps the whole surface buildable over stub clients.

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
            .group(context: AdministratorRequestContext.self)
            .get(use: listAllLoans)
    }

    private func borrowBook(
        request: Request,
        context: IdentityRequestContext
    ) async throws -> EditedResponse<Components.Schemas.LoanResponse> {
        let idempotencyKey = try request.headers.requireIdempotencyKey()
        let body = try await request.decode(as: Components.Schemas.BorrowBookRequest.self, context: context)
        let borrowBookRequest = try Bookshelf_Loans_V1_BorrowBookRequest(body, idempotencyKey: idempotencyKey)
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
- A handler makes one upstream call. An answer that needs another service's data is the owning service's to assemble, through its port and a batch read for a list ([clients for Core's ports](grpc.md#clients-for-cores-ports)), so the gateway never joins two services' answers.
- A route belongs to the controller of the resource it answers with, whatever its path: `books/:id/loans` is `LoanController`'s, registered by the router under `books`.
- A create reads its key from the IETF `Idempotency-Key` header, never a body field, with `requireIdempotencyKey()`, an extension on `HTTPFields` in `Schemas/Shared/` that answers `400` for a request without it.
- A read of a resource that people edit answers its `etag` as the `ETag` header too, and an update reads it from `If-Match` with `requireIfMatch()`, beside `requireIdempotencyKey()`, which answers `400` without it ([transactions](use-cases.md#transactions)).
- A query value that is present and malformed answers `400`, like a malformed body; only an absent one takes the service's default.
- The caller's own routes send no user id upstream: the forwarded token names the caller.
- A route's path and method come from the feature's research ([reading like the requirement](style.md#building-the-established-way)).
- Status codes follow the method: `201` with `EditedResponse` for a create, `202` for a route that only asks for work to happen later and has nothing yet to return, `204` (`HTTPResponse.Status.noContent`) for a change with nothing to return, a `DELETE` included, `200` otherwise.

A provider's webhooks get a controller of their own (`ResendWebhookController`), in the no-caller tier, that collects the body up to a limit the provider's events fit and forwards each event unparsed:

- The conversion copies the bytes and the provider's signature headers unchanged, refusing a request missing one as `400`; the service verifies them ([webhooks](security.md#webhooks)).
- A body over the limit answers `413` through `ErrorMiddleware`.

## Conversions

`Schemas/Requests/` and `Schemas/Responses/` hold one file per type, `XRequest+RPC.swift` and `XResponse+RPC.swift`:

```swift
extension Components.Schemas.LoanResponse: ResponseCodable {
    init(_ loan: Bookshelf_Loans_V1_Loan) throws {
        let status = try Components.Schemas.LoanStatus(loan.status)
        self.init(id: loan.id, bookID: loan.bookID, status: status, dueDate: loan.dueDate.date)
    }
}

extension Bookshelf_Loans_V1_BorrowBookRequest {
    init(_ body: Components.Schemas.BorrowBookRequest, idempotencyKey: String) throws {
        guard let bookID = UUID(uuidString: body.bookID) else {
            throw HTTPError(.badRequest, message: "bookID must be a UUID.")
        }

        self.init()
        self.bookID = bookID.uuidString.lowercased()
        self.idempotencyKey = idempotencyKey
    }
}
```

- An id passes through as the string it is: a response takes the service's lowercase id unchanged, and a request parses a body's id with `UUID(uuidString:)`, answering `400` for one that isn't a UUID, and sends it lowercased. A path's id is read with `context.parameters.require("id", as: UUID.self)`.
- A request conversion takes the body unlabeled, then what the path or headers gave, labeled for what it is (`idempotencyKey:`, `loanID:`).
- A response conversion throws `UpstreamValueError`, in `Schemas/Shared/`, on a malformed upstream value, such as an unspecified enum or an unset field the schema requires. It isn't an HTTP error, so `ErrorMiddleware`'s final `catch` logs it and answers `500` with no detail, rather than dropping or inventing a field.
- An upstream's unset `optional` field becomes an absent property, read with its `has…` property, never by testing for an empty string.
- A shape several contracts declare, such as `PageInfo`, is one file in `Schemas/Shared/` with an initializer per contract.
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
            throw Problem(status: error.status, detail: error.body, headers: error.headers)
        } catch let error as any HTTPResponseError {
            throw Problem(status: error.status)
        } catch let error as RPCError {
            let status = HTTPResponse.Status(error.code)
            guard status.kind == .clientError else {
                context.logger.error("Upstream call failed", metadata: ["error": "\(error)"])
                throw Problem(status: status)
            }

            throw Problem(status: status, detail: error.message)
        } catch {
            context.logger.error("Request failed: unknown error", metadata: ["error": "\(error)"])
            throw Problem(status: .internalServerError)
        }
    }
}

/// RFC 9457 problem details. Without a `type`, a problem means what its status means.
package struct Problem: HTTPResponseError {
    package let status: HTTPResponse.Status
    package let detail: String?
    package let headers: HTTPFields

    package init(status: HTTPResponse.Status, detail: String? = nil, headers: HTTPFields = [:]) {
        …
    }

    package func response(from request: Request, context: some RequestContext) throws -> Response { … }

    private struct Body: Encodable {
        …  // title, status, detail, instance
    }
}
```

- Each `catch` throws its `Problem`, and nothing follows the `do`: the router renders a thrown `HTTPResponseError` with its `response(from:context:)`, and CORS adds its headers on the way out.
- A refusal answers in its own words: an `HTTPError`'s message, which the gateway or Hummingbird wrote, and a `4xx` upstream's message, which the service wrote for clients ([status codes](grpc.md#status-codes)).
- An `HTTPError`'s headers, such as `WWW-Authenticate`, `Allow` or `Retry-After`, go out on its problem: `response(from:context:)` writes them beside the content type.
- An upstream's server error answers its status alone, since a transport's message can name internal hosts. It's logged with its cause, as is anything that isn't an HTTP or RPC error, which answers `500`.
- Hummingbird's other `HTTPResponseError`s keep their status, such as `413` for a body over its limit. Router middleware also wraps the not-found responder, so an unmatched path's `404` is a problem too.
- `RPCError` gets no retroactive `HTTPResponseError` conformance: the middleware is the one place it becomes a status.
- A problem's `instance` is the request's id, `urn:bookshelf:request:<context.id>`. It's the `hb.request.id` on every log line the request writes, beside its trace id ([observability](composition.md#observability)), so a client that reports a problem names the trace to read.
- `openapi.yaml` declares the `Problem` schema once and references it from every error response a route documents.

`HTTPResponse.Status.init(_ code: RPCError.Code)`, a `switch` with a `default`, maps the codes:

| `RPCError.Code` | HTTP |
|---|---|
| `invalidArgument`, `failedPrecondition`, `outOfRange` | `400` |
| `unauthenticated` | `401` |
| `permissionDenied` | `403` |
| `notFound` | `404` |
| `alreadyExists` | `409` |
| `aborted` | `412` |
| `resourceExhausted` | `429` |
| `cancelled` | `499` |
| `unimplemented` | `501` |
| `unavailable` | `503` |
| `deadlineExceeded` | `504` |
| `unknown`, `internalError`, `dataLoss`, anything else | `500` |

## Versions

`/v1` changes only in ways a client built against it ignores: a new route, an optional request field or query parameter, a new response field. Any other change breaks clients, such as a field or route removed or renamed, a type changed, an input newly required or a status given a new meaning, and never lands in place:

- A breaking change to a route is that route again under `/v2`, beside `/v1`'s; the routes it leaves alone stay at `/v1` only. `openapi.yaml` documents it with a path-level `servers` entry ending in `/v2`, and names a schema whose shape changed with a `V2` suffix (`LoanResponseV2`), so both versions' types generate side by side.
- `BookshelfAPI`'s `addV2Routes(to:)` registers it on the router's `v2` group, in its tier. Its handler sits beside `/v1`'s in the resource's controller, and both call the same RPC unless the contract changed too ([contracts](grpc.md#contracts-in-the-protos-package)).
- From the deploy that ships `/v2`, `/v1`'s route is `deprecated: true` in `openapi.yaml`, and it's removed once the user's sunset date passes.
- CI fails a pull request whose `openapi.yaml` breaks a client of its base's ([the gate](delivery.md#the-gate)).

## Upstream clients

The executable builds one `GRPCClient` per upstream service over mTLS, its transport built like any client's ([transports](grpc.md#transports)), with `ClientOTelTracingInterceptor` first ([observability](composition.md#observability)) and `BearerPropagationInterceptor` applied to the descriptors the gateway calls ([the gateway's root](composition.md#the-gateways-root)).

- Propagation presents the caller's original token, as `BearerAuthenticationMiddleware` bound it, when a route identified a caller; a public route's call goes upstream anonymously.

## The edge

- Clients reach the gateway over TLS, terminated by the edge in front of it (a CDN or reverse proxy). The gateway listens for plain HTTP on its private interface; it never configures TLS for clients.
- Limits per client address are the edge proxy's, before a request reaches the gateway; limits per account are the owning service's.
- CORS is the gateway's, in `CORSMiddleware` first on the router, allowing the headers clients send, `Idempotency-Key` and `If-Match` among them, and exposing the ones they read, such as `ETag`. The API authenticates by bearer token alone, never a cookie, so it allows no credentials.
