# Conventions

## Contents
- Naming
- Folders
- Files

## Naming

`X` is a service's name in UpperCamelCase (`Loans`), `x` its lowercase form (`loans`); `<Org>` and `<org>` are the organization's (`Bookshelf`, `bookshelf`). Names follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/): they read as English at the point of use, name things by role, and keep an initialism in one case (`userID`, `GetLoanByIDUseCase`, `baseURL`, `XGRPC`).

| Kind | Name | Example |
|---|---|---|
| Service | A noun for the capability, clashing with no module in the package graph ([naming a service](system.md#naming-a-service)) | `Identity`, `Catalog`, `Loans`; not `Authentication` |
| Service package and repository | `<org>-<service>` | `bookshelf-loans` |
| Shared packages | `<org>-core`, `<org>-protos`, `<org>-gateway` | `bookshelf-core` |
| Service targets | `XCore`, `XPostgres`, `XGRPC`, `XTemporal`, `XValkey`, `X<Provider>`, `XHTTP`; the executable `X`; tests `XCoreTests`, `XGRPCTests`, `XTemporalTests` | `LoansTemporal`, `LoansResend` |
| Executable product and command | `x`; subcommands `serve`, `worker run` | `loans serve --migrate-database` |
| Org core products | `<Org>Authentication`, `<Org>Persistence`, `<Org>Transport`, `<Org>Testing` | `BookshelfTransport` |
| Contract target, proto package and file | `XProtos`; `<org>.<x>.v1`; `<org>/<x>/v1/<x>.proto` | `LoansProtos`, `bookshelf.loans.v1` |
| Proto services | `<Resource>Service` and `<Resource>InternalService`; the service's name when its RPCs aren't about one resource | `LoanService`, `BookInternalService`, `IdentityService` |
| RPCs | Standard verbs, or a domain verb and noun; an administrators' list of everyone's is `ListAll…` | `GetBook`, `ListLoans`, `ListAllLoans`, `BorrowBook` |
| Domain model | A plain noun in the service's language; never `DTO`, `Row`, `Entity`, `Response` or `Detail` | `Loan`, `LoanStatus` |
| Another service's data, as this service knows it | A noun in this service's words, in `Ports/` | `Book`, `Member` |
| Tunable rules | `XPolicy` | `LoanPolicy` |
| Use case | Its RPC's verb and noun + `UseCase`; with `…UseCaseProtocol`, `…UseCaseInput`, `…UseCaseError`, `…UseCaseScope` | `BorrowBookUseCase`, `BorrowBookUseCaseError` |
| A property holding a use case | The use case's type in lowerCamelCase | `borrowBookUseCase` |
| Repository | `XRepository`; its implementation the store's name + the protocol's | `LoanRepository`, `PostgresLoanRepository`, `ValkeyResetCodeRepository` |
| Repository reads and writes | Noun phrases for what reads return; verbs for writes | `loan(id:)`, `activeLoans(userID:)`; `create(_:)`, `markReturned(id:)` |
| Write command | The write's verb and noun + `Command` | `CreateLoanCommand` |
| Errors | `XRepositoryError`, `<Service>ClientError`, `XUseCaseError`; cases name outcomes | `LoanRepositoryError.idempotencyConflict`, `.bookNotFound` |
| Port to another service | `<Service>Client`; implementation `GRPC<Service>Client` | `CatalogClient`, `GRPCCatalogClient` |
| Port to a capability | A role noun; implementation the provider's name + the role | `NoticeSender`, `ResendNoticeSender`; `PasswordHasher`, `BcryptPasswordHasher` |
| Workflow port and implementation | `<Process>WorkflowClient`, `Temporal<Process>WorkflowClient` | `LoanWorkflowClient`, `TemporalLoanWorkflowClient` |
| Workflow, activity container | `<Process>Workflow`, `<Process>Activities`; activities are verbs, inputs `<Activity>Input` | `LoanWorkflow`, `LoanActivities.markOverdue(input:)`, `MarkOverdueInput` |
| Signals, queries, updates | Verbs for signals and updates, noun phrases for queries | `markReturned(input:)`, `currentState(input:)` |
| Workflow id, task queue | `<x>-<workflow>-<id>`; `x` | `loans-loan-0193…`; `loans` |
| Named activity options | The kind of step | `ActivityOptions.database`, `.notification` |
| Postgres scopes | `Postgres<X>Scope`, `Postgres<X>InternalScope`, `Postgres<X>WorkerScope` | `PostgresLoansScope` |
| Statement | What it does + `Statement` | `CreateLoanStatement`, `ActiveLoansByUserIDStatement` |
| Migration | What it changes | `CreateLoansTable`, `CreateLoansRLSPolicy`, `CreateServiceRole` |
| Database, roles, policies | `<org>_<x>`; `<x>_service`, `<x>_internal`, `<x>_worker`; `tenant_isolation`, `<role>_all` | `bookshelf_loans`, `loans_service`, `internal_all` |
| Tenant setting | `app.caller_user_id` | |
| gRPC service types | The proto service's name | `LoanService`, `BookInternalService` |
| Gateway | Targets `GatewayHTTP`, `Gateway`; router builder `<Org>API`; `XController` per resource; `IdentityRequestContext`, `AdminRequestContext` | `BookshelfAPI`, `LoanController` |
| Configuration keys | Dotted scopes with lowerCamelCase leaves; a duration names its unit | `grpc.server.port`, `postgres.service.password`, `tls.refreshIntervalSeconds` |
| Logger label | `<org>-<x>`, `<org>-<x>-worker` | `bookshelf-loans-worker` |
| Log metadata keys | lowerCamelCase | `loanID`, `userID`, `error` |
| Valkey keys | `<x>:<purpose>:<id>` | `identity:reset-code:…` |
| Idempotency keys for providers | `<x>-<what>-<subject id>` | `loans-overdue-notice-<loan id>` |
| Conversion files | `Type+Protobuf.swift`, `Type+PostgresRow.swift`, `Type+PostgresCodable.swift`, `Type+ConfigReader.swift`; in the gateway `Type+RPC.swift` | `Loan+Protobuf.swift`, `LoanResponse+RPC.swift` |

## Folders

| Target | Folders |
|---|---|
| XCore | A folder per area (`Loans/`) with its models and policy, `Repository/` (and `Repository/Commands/`), `UseCases/<Name>/`, `Workflow/`; `Ports/` for what the service needs from other systems, with the models they return |
| XPostgres | `Scopes/`, `Repositories/<Area>/`, `Statements/<Area>/` with `Type+PostgresRow.swift`, `Extensions/`, `Migrations/<Area>/`, `Migrations/Role/` |
| XGRPC | A folder per area with its proto services and `Protobuf/`; `Clients/` with `Clients/Protobuf/` |
| XTemporal | A folder per process with its workflow, activities and Temporal client; `ActivityOptions+X.swift` |
| XValkey, X<Provider>, XHTTP | Flat, one file per type |
| X (executable) | `X.swift` (`@main`), `Configuration/`, `Database/Migrations.swift`, `Serve/Serve.swift`, `Worker/Worker.swift`, `Worker/Run.swift` |
| GatewayHTTP | `openapi.yaml`, `openapi-generator-config.yaml`, `<Org>API.swift`, `Contexts/`, `Controllers/`, `Middlewares/`, `Schemas/Requests/`, `Schemas/Responses/`, `Schemas/Shared/` |

## Files

- One type per file, named for the type. A type's small nested types stay in its file: a workflow's `Input`, an activity container's inputs, a router builder's `Dependencies`.
- An extension that adds a concern to a type is `Type+Concern.swift`.
- A use case's five files sit together in `UseCases/<Name>/`.
