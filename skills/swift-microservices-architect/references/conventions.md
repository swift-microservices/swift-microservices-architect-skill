# Conventions

## Contents
- Naming
- Folders
- Files

## Naming

`X` is a service's name in UpperCamelCase (`Loans`), `x` its lowercase form (`loans`); in a type's name, `X` is what the type is named for, the operation, resource or process the table gives (`BorrowBookUseCase`, `LoanRepository`); `<Project>` and `<project>` are the project's (`Bookshelf`, `bookshelf`), and `<owner>` is the GitHub account that owns its repositories. Names follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/): they read as English at the point of use, name things by role, and keep an initialism in one case (`userID`, `ActiveLoansByUserIDStatement`, `baseURL`, `XGRPC`).

| Kind | Name | Example |
|---|---|---|
| Service | A noun for the capability, clashing with no module in the package graph ([naming a service](system.md#naming-a-service)) | `Identity`, `Catalog`, `Loans`; not `Authentication` |
| Service package and repository | `<project>-<x>`; the gateway's `<project>-gateway` | `bookshelf-loans`, `bookshelf-gateway` |
| Shared packages | `<project>-core`, `<project>-protos` | `bookshelf-core` |
| Package kind | Public library, system library or service; CI workflow files and jobs as [delivery](delivery.md#ci-workflows) names them | `bookshelf-core` is a system library |
| Service image | `ghcr.io/<owner>/<project>-<x>` | `ghcr.io/bookshelf/bookshelf-loans` |
| Service targets | `XCore`, `XPostgres`, `XGRPC`, `XValkey`, `X<Provider>`; the executable `X`; tests the target's name + `Tests` | `LoansGRPC`, `LoansResend`, `LoansCoreTests` |
| Executable product and command | `x`; subcommands `serve`, `worker run` | `loans serve --migrate-database` |
| `<project>-core` products | `<Project>Authentication`, `<Project>Persistence`, `<Project>Transport`, `<Project>Testing`; tests the product's name + `Tests` | `BookshelfTransport`, `BookshelfAuthenticationTests` |
| Contract target, proto package and file | `XProtos`; `<project>.<x>.v1`; `<project>/<x>/v1/<x>.proto` | `LoansProtos`, `bookshelf.loans.v1` |
| Proto services | `<Resource>Service` and `<Resource>InternalService`; the service's name when its RPCs aren't about one resource | `LoanService`, `BookInternalService`, `IdentityService` |
| RPCs | Standard verbs, or a domain verb and noun; an administrators' list of everyone's is `ListAll…` | `GetBook`, `ListLoans`, `ListAllLoans`, `BorrowBook` |
| Paging | Requests carry `page_size` and `page`, or `page_token`; responses `page_info` (`page`, `page_size`, `total_count`, `total_pages`) or `next_page_token`. Core has `Page<Item>` and `KeyedPage<Item>` (`nextCursor`) and reads `page:pageSize:` or `startingAfter:pageSize:`. Over HTTP the same names in camelCase | `loans(userID:page:pageSize:)`, `loans(startingAfter:pageSize:)`, `LoansByUserIDStatement`, `CountLoansByUserIDStatement` |
| Webhooks | An anyone RPC `Receive<Event>`; the route `webhooks/<provider>`; `<Provider>WebhookController`; the port `<Event>Verifier` | `ReceiveNoticeEvent`, `ResendWebhookController`, `NoticeEventVerifier` |
| Domain model | A plain noun in the service's language; never `DTO`, `Row`, `Entity`, `Response` or `Detail` | `Loan`, `LoanStatus` |
| Another service's data, as this service knows it | A noun in this service's words, in `Ports/` | `Book`, `Member` |
| Tunable rules | `XPolicy` | `LoanPolicy` |
| Use case | Its RPC's verb and noun + `UseCase`; with `…UseCaseProtocol`, `…UseCaseInput`, `…UseCaseError`, `…UseCaseScope` | `BorrowBookUseCase`, `BorrowBookUseCaseError` |
| System use case | Its step's verb and noun + `UseCase`; the same effect for administrators `…ByAdministratorUseCase` | `MarkLoanOverdueUseCase`, `MarkLoanOverdueByAdministratorUseCase` |
| A property holding a use case | The use case's type in lowerCamelCase | `borrowBookUseCase` |
| Repository | `XRepository`; its implementation the store's name + the protocol's | `LoanRepository`, `PostgresLoanRepository`, `ValkeyResetCodeRepository` |
| Repository reads and writes | Noun phrases for what reads return; verbs for writes | `loan(id:)`, `activeLoans(userID:)`; `create(_:)`, `markReturned(id:)` |
| Write command | The write's verb and noun + `Command` | `CreateLoanCommand` |
| Errors | `XRepositoryError`, `<Service>ClientError`, `XUseCaseError`; cases name outcomes | `CatalogClientError.unavailable`, `.bookNotFound` |
| Port to another service | `<Service>Client`; implementation `GRPC<Service>Client` | `CatalogClient`, `GRPCCatalogClient` |
| Port to a provider | A role noun; implementation the provider's name + the role | `NoticeSender`, `ResendNoticeSender`; `PasswordHasher`, `BcryptPasswordHasher` |
| Workflow, activity container | `<Process>Workflow`, `<Process>Activities`; a container an activity several workflows share is named for its step, `<Step>Activities`; activities are verbs, inputs `<Activity>Input` | `LoanWorkflow`, `LoanActivities.markOverdue(input:)`, `MarkOverdueInput` |
| A use case's Temporal properties | `temporalClient`, `taskQueue` | `private let temporalClient: TemporalClient` |
| Signals, queries, updates | Verbs for signals and updates, noun phrases for queries | `currentState(input:)` |
| Workflow id, task queue | `<x>-<workflow>-<id>`; `x` | `loans-loan-0193…`; `loans` |
| Named activity options | The kind of step, never where it's used | `ActivityOptions.database`, `.notification` |
| Postgres scopes | `Postgres<X>Scope`, `Postgres<X>InternalScope`, `Postgres<X>WorkerScope` | `PostgresLoansScope` |
| Mock | `Mock` + the protocol's name, without `Protocol` | `MockCatalogClient`, `MockBorrowBookUseCase`, `MockDatabase` |
| Statement | What it does + `Statement` | `CreateLoanStatement`, `ActiveLoansByUserIDStatement` |
| Migration | What it changes | `CreateLoansTable`, `CreateLoansRLSPolicy`, `CreateServiceRole` |
| Database, roles, policies | `<project>_<x>`; `<x>_owner`, `<x>_service`, `<x>_internal`, `<x>_worker`; `tenant_isolation`, `<role>_all` | `bookshelf_loans`, `loans_service`, `internal_all` |
| Process identity, a certificate's common name | `<x>` for serve, `<x>-worker`, `<x>-migrator` | `loans-migrator` |
| Columns | The snake_case of the Swift property; a stored date is a noun, never `…At` | `creation_date` for `creationDate`, `due_date`; not `created_at` |
| Indexes unique while active | `<table>_active_<columns>_key` | `loans_active_user_id_book_id_key` |
| Tenant setting | `app.caller_user_id` | |
| gRPC service types | The proto service's name | `LoanService`, `BookInternalService` |
| Gateway | Targets `GatewayHTTP`, `Gateway`; router builder `<Project>API`; `XController` per resource; `IdentityRequestContext`, `AdministratorRequestContext` | `BookshelfAPI`, `LoanController` |
| Configuration keys | Dotted scopes with lowerCamelCase leaves; a duration names its unit | `grpc.server.port`, `postgres.service.user`, `tls.refreshIntervalSeconds` |
| Logger label | `<project>-<x>`, `<project>-<x>-worker` | `bookshelf-loans-worker` |
| Log metadata keys | lowerCamelCase | `loanID`, `userID`, `error` |
| Valkey keys | `<x>:<purpose>:<id>` | `identity:reset-code:…` |
| Idempotency keys for providers | `<x>-<what>-<subject id>` | `loans-overdue-notice-<loan id>` |
| Conversion files | `Type+Protobuf.swift`, `Type+PostgresRow.swift`, `Type+PostgresCodable.swift`, `Type+ConfigReader.swift`; in the gateway `Type+RPC.swift` | `Loan+Protobuf.swift`, `LoanResponse+RPC.swift` |

## Folders

| Target | Folders |
|---|---|
| XCore | A folder per area (`Loans/`) with its models and policy, `Repository/` (and `Repository/Commands/`), `UseCases/<Name>/`; `Workflows/<WorkflowName>/` with the workflow, its activity container and `ActivityOptions+X.swift`, and a shared container, or a payload type two workflows share, directly in `Workflows/`; `Ports/` for what the service needs from other systems, with the models they return; `Paging/` for the page types |
| XPostgres | `Scopes/`, `Repositories/<Area>/`, `Statements/<Area>/` with `Type+PostgresRow.swift`, `Extensions/`, `Migrations/<Area>/`, `Migrations/Role/` |
| XGRPC | A folder per area with its proto services and `Protobuf/`; `Clients/` with `Clients/Protobuf/` |
| XValkey, X<Provider> | Flat, one file per type |
| X (executable) | `X.swift` (`@main`), `Configuration/`, `Database/Migrations.swift`, `Serve/Serve.swift`, `Worker/Worker.swift`, `Worker/Run.swift` |
| Test target | `Mocks/`, then a file per tested type: `BorrowBookUseCaseTests.swift` |
| GatewayHTTP | `openapi.yaml`, `openapi-generator-config.yaml`, `<Project>API.swift`, `Contexts/`, `Controllers/`, `Middlewares/`, `Schemas/Requests/`, `Schemas/Responses/`, `Schemas/Shared/` |

## Files

- One type per file, named for the type. A type's small nested types stay in its file: a workflow's `Input`, an activity container's inputs.
- An extension that adds a concern to a type is `Type+Concern.swift`.
- A use case's five files sit together in `UseCases/<Name>/`.
