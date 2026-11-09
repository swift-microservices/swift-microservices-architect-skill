# Workflows

Durable processes on Temporal with swift-temporal-sdk: when work is a workflow, how a use case starts one, how workflows and activities read, and the worker that runs them. A workflow, its activity container and its named options are Core's, in `XCore/Workflows/<WorkflowName>/` ([the folder layout](packages.md#folder-layout)), and use the SDK directly, with no wrapper ([what Core may link](packages.md#what-core-may-link)).

## Contents
- When work is a workflow
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

Temporal's history is the workflow's state. No column mirrors a run's progress, no scanner restarts workflows from rows, and no reconciler compares the two; a loan's `status` is the loan's, written by the use cases its activities run.

## Starting a workflow from a use case

A use case that starts a workflow holds the concrete `TemporalClient` and the task queue as a `String`, both from [the composition root](composition.md#the-composition-root), and calls `startWorkflow(type:options:input:)` itself; [`BorrowBook`](use-cases.md#the-body-of-a-use-case) shows it. A start for a loan whose run is in flight joins it, and one whose run failed starts it again; one whose run completed is refused, since its work is done.

- A workflow's id derives from the business id it's about, named as [naming](conventions.md#naming) gives it, declared once on the workflow (`LoanWorkflow.id(loanID:)`). A retried request then reaches the same run instead of starting a second.
- `idConflictPolicy: .useExisting` joins a run in flight. `idReusePolicy` decides a start once the id's run has closed:
  - `.allowDuplicateFailedOnly` starts a failed run's work again on a new trigger, such as a retried request. `WorkflowAlreadyStartedError` then means the run completed, and the use case answers as if the start had succeeded.
  - `.rejectDuplicate` keeps a failed run from running again without a person. The error then propagates, since catching it would report unfinished work as done.
- `catch is WorkflowAlreadyStartedError` joins the use case's one `do` when its answer needs nothing the `do` built, such as a webhook's. One that returns what the path built, as `BorrowBook` returns its loan, wraps the start in an inner `do` that ends the path.
- The use case starts the workflow after its transaction commits; [transactions](use-cases.md#transactions) say how a lost start is recovered.
- A start doesn't wait for the result. A use case that needs a workflow's state queries it, and a signal or an update goes the same way, through `TemporalClient`: `temporalClient.workflowHandle(type: LoanWorkflow.self, id: workflowID)`, then `handle.signal(signalType:input:)`, `handle.query(queryType:input:)` or `handle.executeUpdate(updateType:input:)`. A signal reaches only a run in flight and fails once the run has closed, so a fact that outlives the run, such as a return, stays in the database, where the activity that acts on it reads it (`markOverdue`).

A workflow a provider's [webhook](security.md#webhooks) starts takes ids, not the event's body, since events arrive more than once and out of order, and its id names the event. Started with the same two policies, a redelivery joins the run in flight, or runs again after a failure.

## A workflow

```swift
package import Temporal

#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

/// A loan from borrowing to its due date: a book still out then makes the loan overdue,
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

    package func run(context: WorkflowContext<Self>, input: Input) async throws {
        // A run started again after the due date has nothing left to wait for.
        let timeUntilDue = input.dueDate.timeIntervalSince(context.now)
        let timeToWait = max(timeUntilDue, 0)
        try await context.sleep(for: .seconds(timeToWait))

        let markOverdueInput = LoanActivities.MarkOverdueInput(loanID: input.loanID)
        let isMarkedOverdue = try await context.executeActivity(
            LoanActivities.Activities.MarkOverdue.self,
            options: .database,
            input: markOverdueInput
        )
        guard isMarkedOverdue else {
            return
        }

        let noticeInput = LoanActivities.SendOverdueNoticeInput(loanID: input.loanID, userID: input.userID, bookID: input.bookID)
        try await context.executeActivity(
            LoanActivities.Activities.SendOverdueNotice.self,
            options: .notification,
            input: noticeInput
        )
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
- A workflow takes a nested `Input` and returns a nested `Output` (or nothing), with explicit initializers, so fields can be added later.
- Every payload is `Codable, Sendable`, and so is every type it holds: a workflow's input and output, a signal's, query's or update's, and an activity's. The SDK requires only `Sendable` and checks `Codable` when it converts the value, so a missing conformance compiles, then fails on every attempt. A domain enum a payload needs is mirrored as a nested enum.
- State that handlers change is the workflow's private stored properties. A signal is a `@WorkflowSignal mutating func`; a query a `@WorkflowQuery func` taking `input:` and returning a value, which can't mutate; an update, which changes state and answers, a `@WorkflowUpdate`. The macros generate the types callers name, the method's name capitalized.
- Waiting: `context.sleep(for:)` for time; `context.condition { … }` for state a handler sets; both together with the condition inside `context.timeout(for:)`, catching `CanceledError` as the timeout.
- A step that is itself a process is a child workflow, `context.executeChildWorkflow(_:options:input:)`, with a deterministic id.
- An outcome the process continues from is an activity's return value, not an error: `markOverdue` returns whether it marked the loan, and the workflow branches on it. Errors are failures, and a failure ends the run; undoing an earlier step's effect is another activity, run before the run ends.
- Comments give the business reason for a step or an order, never what the next line does.

## Determinism

A workflow takes the same path on every replay:

| Instead of | A workflow uses |
|---|---|
| `Date.now` | `context.now` |
| `Task.sleep`, `Clock.sleep` | `context.sleep(for:)` |
| `UUID()`, `.random(in:)` | `context.randomNumberGenerator`, or a value an activity returns |
| A `Logger` from the composition root | `Logger.current`, which the worker keeps quiet during replay |
| I/O of any kind: databases, network, files, the environment | An activity |
| `Task {}`, `Task.detached`, actors | `async let`, task groups, child workflows |
| Global or static mutable state | The workflow's own stored properties |

Workflows and their inputs are value types; nothing in a workflow holds a reference to a service, a client or a repository.

## Activities

An activity container is an inbound adapter that lives in Core, the worker's counterpart to a gRPC service: it holds use cases and ports, and maps their errors. There is one container per workflow, named after it. An activity several workflows share gets its own small container, named for its step, in `Workflows/`.

A container is injected only with use case protocols (`any MarkLoanOverdueUseCaseProtocol`) and port protocols (`any CatalogClient`), plus a `Logger` if needed. It never receives a repository, a database or scope, a concrete adapter type, `TemporalClient` or configuration. The worker's root passes in the implementations, so no adapter target meets another.

```swift
package import Temporal

#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

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
            let markLoanOverdueInput = MarkLoanOverdueUseCaseInput(loanID: input.loanID)
            let loan = try await markLoanOverdueUseCase(input: markLoanOverdueInput)
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

        let notice = OverdueNotice(memberName: member.name, email: member.email, bookTitle: book.title)
        let idempotencyKey = "loans-overdue-notice-\(input.loanID.uuidString.lowercased())"
        try await noticeSender.send(notice, idempotencyKey: idempotencyKey)
    }
}
```

- An activity runs a [system use case](use-cases.md#system-use-cases) when the step reads or writes this service's data, on the worker's database, and calls a port when the step is one effect another system owns; a use case that would only forward to the port adds nothing. It makes no business decision: the use case decides, and the activity reports what it decided.
- Its input is a small struct nested in the container, named for the activity (`MarkOverdueInput`), holding ids and values, never commands; the activity builds what the use case or port takes.
- It returns a primitive (`Bool`) or a small nested output holding only what the workflow reads, never a domain model, which isn't `Codable` and would put the whole record in the history.
- It maps a permanent failure, a case no retry can change, to `ApplicationError(message:type:isNonRetryable: true)`, catching that case explicitly. Every other error propagates, and Temporal retries it.
- It's safe to run twice: writes are conditional or keyed, and external effects carry an idempotency key derived from the workflow's subject (`loans-overdue-notice-<loan id>`).
- An activity that runs long calls `ActivityExecutionContext.current?.heartbeat()` regularly, and its options set `heartbeatTimeout`: without one, neither cancellation nor a lost worker reaches it before `startToCloseTimeout`.
- Activities are registered by name, the method's name capitalized (`MarkOverdue`).

## Activity options

Named once per target, in `ActivityOptions+X.swift` in the folder of the first workflow that needs them, and used by name in every workflow of the target:

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

## Histories and versions

- A workflow's inputs, outputs and activity results are stored in its history. They hold ids and small values, never personal data, secrets or tokens; an activity reads those when it runs.
- A recorded history must still decode: add `Codable` fields as optionals, and never rename or remove a field, or an enum case, that a running workflow's history holds.
- Changing the commands a workflow issues, by adding, removing or reordering activities, timers or child workflows, breaks replay of runs started under the old code. Branch on `context.patch("<change>")` until those runs finish, then `context.deprecatePatch`; or give the new process a new workflow type.

## The worker

`x worker run` builds the worker in [its own root](composition.md#the-workers-root):
- It connects to Postgres as the worker role, so only use cases whose scopes the worker scope adopts can run in it.
- Each service has one task queue, named for it (`loans`), under the SDK's key `temporal.worker.taskqueue`, which the serve process also reads for its starts.
- The SDK's readers take the namespace under `temporal.client.namespace` for starts and `temporal.worker.namespace` for polling, which the defaults set together (`bookshelf`). They also require `temporal.client.instrumentation.serverhostname` and `temporal.worker.client.instrumentation.serverhostname` (the Temporal host), `temporal.worker.buildid` (the image's commit) and `temporal.worker.client.identity`, which the deployment sets.
