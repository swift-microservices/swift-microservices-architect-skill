# Workflows

Durable processes on Temporal with swift-temporal-sdk: when work is a workflow, how a use case starts one, how workflows and activities read, and the worker that runs them.

## Contents
- When work is a workflow
- The Temporal target
- Starting a workflow from a use case
- A workflow
- Determinism
- Activities
- Activity options
- Histories and versions
- The worker

## When work is a workflow

Work is a workflow when it must happen even if every process restarts, and it:
- waits for time or for something to happen (a due date, a confirmation),
- retries a call that can fail for a while (a provider, another service),
- or spans several services, each step's effect owned by a different one.

A request that only needs an answer stays a synchronous RPC. Work after a response is never a `Task {}`: an unstructured task dies with the process and nobody retries it.

## The Temporal target

```
LoansTemporal/
├── Loan/                       one folder per process
│   ├── LoanWorkflow.swift
│   ├── LoanActivities.swift
│   └── TemporalLoanWorkflowClient.swift
└── ActivityOptions+Loans.swift
```

XTemporal depends on XCore and Temporal only. Its activities reach other services and providers through Core's ports, which the worker's composition root fills with XGRPC and provider types.

## Starting a workflow from a use case

Core declares the port; XTemporal implements it:

```swift
/// How use cases hand a loan to its durable process.
///
/// Each method returns once Temporal has accepted it, never when the process finishes.
package protocol LoanWorkflowClient: Sendable {
    func startLoan(_ loan: Loan) async throws
    func markReturned(loanID: UUID) async throws
}
```

```swift
package struct TemporalLoanWorkflowClient: LoanWorkflowClient {
    private let client: TemporalClient
    private let taskQueue: String

    package init(client: TemporalClient, taskQueue: String) {
        self.client = client
        self.taskQueue = taskQueue
    }

    /// A start for a loan whose run is still in flight joins it; one whose run has completed is
    /// refused, and its work is done.
    package func startLoan(_ loan: Loan) async throws {
        do {
            _ = try await client.startWorkflow(
                type: LoanWorkflow.self,
                options: WorkflowOptions(
                    id: LoanWorkflow.id(loanID: loan.id),
                    taskQueue: taskQueue,
                    idReusePolicy: .rejectDuplicate,
                    idConflictPolicy: .useExisting
                ),
                input: LoanWorkflow.Input(loanID: loan.id, userID: loan.userID, bookID: loan.bookID, dueDate: loan.dueDate)
            )
        } catch is WorkflowAlreadyStartedError {
            return
        }
    }

    package func markReturned(loanID: UUID) async throws {
        try await client
            .workflowHandle(type: LoanWorkflow.self, id: LoanWorkflow.id(loanID: loanID))
            .signal(signalType: LoanWorkflow.MarkReturned.self)
    }
}
```

- A workflow's id derives from the business id it's about, `<service>-<workflow>-<id>`, declared once on the workflow (`LoanWorkflow.id(loanID:)`). A retried request then reaches the same run instead of starting a second.
- `idConflictPolicy: .useExisting` joins a run in flight. `idReusePolicy` decides a completed run's id: `.rejectDuplicate` when the work happens once per id; `.allowDuplicateFailedOnly` when a failed run may be retried by a new trigger.
- The use case starts the workflow after its transaction commits. A start lost after the commit is recovered by the next attempt, which finds the row and starts the same id ([transactions](use-cases.md#transactions)).
- A start doesn't wait for the result. A use case that needs a workflow's state reads it with a query (`handle.query(queryType:)`), and one that delivers an event sends a signal.
- The serve process holds one `TemporalClient`, in its `ServiceGroup`; the worker holds the `TemporalWorker`.

## A workflow

```swift
/// A loan from borrowing to return. A book still out on its due date makes the loan overdue,
/// and the member is sent a notice.
@Workflow
package struct LoanWorkflow {
    package struct Input: Codable, Sendable {
        package let loanID: UUID
        package let userID: UUID
        package let bookID: UUID
        package let dueDate: Date

        package init(loanID: UUID, userID: UUID, bookID: UUID, dueDate: Date) {
            …
        }
    }

    private var isReturned = false

    package mutating func run(context: WorkflowContext<Self>, input: Input) async throws {
        try await context.sleep(for: .seconds(input.dueDate.timeIntervalSince(context.now)))
        guard !isReturned else {
            return
        }

        let isMarkedOverdue = try await context.executeActivity(
            LoanActivities.Activities.MarkOverdue.self,
            options: .database,
            input: LoanActivities.MarkOverdueInput(loanID: input.loanID)
        )
        guard isMarkedOverdue else {
            return
        }

        try await context.executeActivity(
            LoanActivities.Activities.SendOverdueNotice.self,
            options: .notification,
            input: LoanActivities.SendOverdueNoticeInput(loanID: input.loanID, userID: input.userID, bookID: input.bookID)
        )
    }

    @WorkflowSignal
    package mutating func markReturned(input: Void) {
        isReturned = true
    }
}

extension LoanWorkflow {
    /// One run per loan.
    package static func id(loanID: UUID) -> String {
        "loans-loan-\(loanID.uuidString.lowercased())"
    }
}
```

- `run(context:input:)` reads as the process: wait, check, act, one activity per step. It's `mutating` when it or a handler changes the workflow's state.
- A workflow takes a nested `Input` and returns a nested `Output` (or nothing), both `Codable, Sendable` with explicit initializers, so fields can be added later.
- State that handlers change is the workflow's private stored properties. A signal is a `@WorkflowSignal mutating func`; a query a `@WorkflowQuery func … throws` that can't mutate; an update, which changes state and answers, a `@WorkflowUpdate`. The macros generate the types callers name: `LoanWorkflow.MarkReturned`.
- Waiting: `context.sleep(for:)` for time; `context.condition { $0.isReturned }` for state a handler sets; both together with the condition inside `context.timeout(for:)`, catching `CanceledError` as the timeout.
- A step that is itself a process is a child workflow, `context.executeChildWorkflow(_:options:input:)`, with a deterministic id.
- An outcome the process continues from is an activity's return value, not an error: `markOverdue` returns whether it marked the loan, and the workflow branches on it. Errors are failures, and a failure ends the run; undoing an earlier step's effect is another activity, run before the run ends.
- Comments give the business reason for a step or an order, never what the next line does.

## Determinism

Temporal replays a workflow's code against its history, so the code takes the same path every time:

| Instead of | A workflow uses |
|---|---|
| `Date.now` | `context.now` |
| `Task.sleep`, `Clock.sleep` | `context.sleep(for:)` |
| `UUID()`, `.random(in:)` | `context.randomNumberGenerator`, or a value an activity returns |
| A `Logger` from the composition root | `context.logger`, which stays quiet during replay |
| I/O of any kind: databases, network, files, the environment | An activity |
| `Task {}`, `Task.detached`, actors | `async let`, task groups, child workflows |
| Global or static mutable state | The workflow's own stored properties |

Workflows and their inputs are value types; nothing in a workflow holds a reference to a service, a client or a repository.

## Activities

An activity container is the worker's adapter, the way a gRPC service is the server's: it holds use cases and ports, and maps their errors.

```swift
/// The loan workflow's side effects, each over a use case or a port.
@ActivityContainer
package struct LoanActivities {
    private let markLoanOverdueUseCase: any MarkLoanOverdueUseCaseProtocol
    private let identityClient: any IdentityClient
    private let catalogClient: any CatalogClient
    private let noticeSender: any NoticeSender

    package init(…) {
        …
    }

    // MARK: - Mark the loan overdue

    package struct MarkOverdueInput: Codable, Sendable {
        package let loanID: UUID
        …
    }

    /// Reports whether the loan is overdue now: one returned in the meantime stays returned.
    @Activity
    package func markOverdue(input: MarkOverdueInput) async throws -> Bool {
        do {
            let loan = try await markLoanOverdueUseCase(input: MarkLoanOverdueUseCaseInput(loanID: input.loanID))
            return loan.status == .overdue
        } catch MarkLoanOverdueUseCaseError.loanNotFound {
            throw ApplicationError(message: "The loan does not exist.", type: "LoanNotFound", isNonRetryable: true)
        }
    }

    // MARK: - Send the notice

    package struct SendOverdueNoticeInput: Codable, Sendable {
        package let loanID: UUID
        package let userID: UUID
        package let bookID: UUID
        …
    }

    /// Reads the member and the book on every attempt, so the workflow's history holds neither.
    @Activity
    package func sendOverdueNotice(input: SendOverdueNoticeInput) async throws {
        guard let member = try await identityClient.member(id: input.userID) else {
            throw ApplicationError(message: "Identity has no such member.", type: "MemberNotFound", isNonRetryable: true)
        }

        guard let book = try await catalogClient.book(id: input.bookID) else {
            throw ApplicationError(message: "Catalog has no such book.", type: "BookNotFound", isNonRetryable: true)
        }

        try await noticeSender.send(
            OverdueNotice(memberName: member.name, email: member.email, bookTitle: book.title),
            idempotencyKey: "loans-overdue-notice-\(input.loanID.uuidString.lowercased())"
        )
    }
}
```

- An activity runs a use case when the step reads or writes this service's data, on the worker's database, and calls a port when the step is one effect another system owns; a use case that would only forward to the port adds nothing.
- Its input is a small `Codable` struct nested in the container, named for the activity (`MarkOverdueInput`), holding ids and values, never Core commands; the activity builds what the use case or port takes.
- It maps a permanent failure, a case no retry can change, to `ApplicationError(message:type:isNonRetryable: true)`, catching that case explicitly. Every other error propagates, and Temporal retries it.
- It's safe to run twice: writes are conditional or keyed, and external effects carry an idempotency key derived from the workflow's subject (`loans-overdue-notice-<loan id>`).
- An activity that runs long calls `ActivityExecutionContext.current?.heartbeat()` regularly, so cancellation reaches it and a lost worker is noticed.
- Activities are registered by name, the method's name capitalized (`MarkOverdue`). Two containers with a method of the same name register the same activity: name one with `@Activity(name:)`.

## Activity options

Named once per target, in `ActivityOptions+X.swift`, and used by name in workflows:

```swift
extension ActivityOptions {
    /// A write to this service's database: retried with backoff until it lands.
    static let database = ActivityOptions(
        startToCloseTimeout: .seconds(30),
        retryPolicy: RetryPolicy(initialInterval: .seconds(1), backoffCoefficient: 2, maximumInterval: .seconds(60))
    )

    /// A message to a member: a few attempts, then the run fails and the loan stays as recorded.
    static let notification = ActivityOptions(
        startToCloseTimeout: .seconds(30),
        retryPolicy: RetryPolicy(initialInterval: .seconds(1), backoffCoefficient: 2, maximumInterval: .seconds(30), maximumAttempts: 5)
    )
}
```

- Every activity has a `startToCloseTimeout` bounding one attempt; `scheduleToCloseTimeout` bounds all attempts when the process can't wait indefinitely.
- `maximumAttempts: 0`, the default, retries until the schedule-to-close timeout, or for as long as the run lives without one; a bounded count is for effects that may be abandoned.
- A name says what kind of step the options suit (`database`, `notification`, `paymentProvider`), never where they're used.

## Histories and versions

- A workflow's inputs, outputs and activity results are stored in its history. They hold ids and small values, never personal data, secrets or tokens; an activity reads those when it runs.
- A recorded history must still decode: add `Codable` fields as optionals, and never rename or remove a field a running workflow's history holds.
- Changing the commands a workflow issues, by adding, removing or reordering activities, timers or child workflows, breaks replay of runs started under the old code. Branch on `context.patch("<change>")` until those runs finish, then `context.deprecatePatch`; or give the new process a new workflow type.

## The worker

- `<service> worker run` is its own process, from the same executable and image, with its own composition root ([the worker's root](composition.md#the-workers-root)).
- It connects to Postgres as the worker role, so only use cases whose scopes the worker scope adopts can run in it.
- It reaches Temporal over mTLS with a certificate pair of its own (`temporal.tls`), independent of the services' trust.
- `TemporalWorker(configuration: .init(configReader:), target:, transportSecurity:, activityContainers:, workflows:, logger:)` reads the namespace, task queue and identity from configuration, and runs in the `ServiceGroup`.
- Each service has one task queue, named for it (`loans`), used by the serve process's starts (`temporal.taskQueue`) and the worker's polling (`temporal.worker.taskqueue`), set to the same default.
