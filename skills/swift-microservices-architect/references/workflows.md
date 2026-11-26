# Workflows

Durable processes on Temporal with swift-temporal-sdk: when work is a workflow, how a use case starts and reaches one, how workflows and activities read, and the worker that runs them. How one is written against the SDK follows `temporal-developer` and the SDK's documentation, never a form carried over from another language's SDK. A workflow, its activity container and its named options are Core's, in `XCore/Workflows/<WorkflowName>/` ([the folder layout](packages.md#folder-layout)), and use the SDK directly, with no wrapper ([what Core may link](packages.md#what-core-may-link)).

## Contents
- When work is a workflow
- Starting a workflow from a use case
- Reaching a run from a use case
- A workflow
- Determinism
- Activities
- Activity options
- Changing a workflow
- Recurring work
- The worker

## When work is a workflow

Work is a workflow when it must happen even if every process restarts, and it:
- waits for time or for something to happen (a due date, a confirmation),
- retries a call that can fail for a while (a provider, another service),
- or spans several services, each step's effect owned by a different one.

A request that only needs an answer stays a synchronous RPC, and a fact other services react to on their own is an [event](events.md#choosing-a-mechanism).

Temporal's history is the workflow's state. No column mirrors a run's progress, no scanner restarts workflows from rows, and no reconciler compares the two; a loan's `status` is the loan's, written by the use cases its activities run. A record people read or page through, such as who decided what and when, is a domain table all the same, written by those use cases: only a column that tracks where a run has got to is ruled out.

## Starting a workflow from a use case

A use case that starts a workflow holds the concrete `TemporalClient` and the task queue as a `String`, both from [the composition root](composition.md#the-composition-root), and calls `startWorkflow(type:options:input:)` itself; [`BorrowBook`](use-cases.md#the-body-of-a-use-case) shows it.

- A workflow's id derives from the business id it's about, named as [naming](conventions.md#naming) gives it, declared once on the workflow (`LoanWorkflow.id(loanID:)`). A retried request then reaches the same run instead of starting a second.
- `idConflictPolicy: .useExisting` joins a run in flight. `idReusePolicy` decides a start once the id's run has closed:
  - `.allowDuplicateFailedOnly` starts a failed run's work again on a new trigger, such as a retried request. `WorkflowAlreadyStartedError` then means the run completed, and the use case answers as if the start had succeeded.
  - `.rejectDuplicate` keeps a failed run from running again without a person. The error then propagates, since catching it would report unfinished work as done.
- `catch is WorkflowAlreadyStartedError` joins the use case's one `do` when its answer needs nothing the `do` built, such as a webhook's. One that returns what the path built, as `BorrowBook` returns its loan, wraps the start in an inner `do` that ends the path.
- The use case starts the workflow after its transaction commits; [transactions](use-cases.md#transactions) say how a lost start is recovered.
- A start doesn't wait for the result.

A workflow a provider's [webhook](security.md#webhooks) starts takes ids, not the event's body, since events arrive more than once and out of order, and its id names the event. Started with the same two policies, a redelivery joins the run in flight, or runs again after a failure.

## Reaching a run from a use case

A person's action on what a run waits for is a use case like any other, on its audience's database. It reaches the run by the id the workflow declares: a signal with `signalWithStartWorkflow(type:input:options:signalType:)`, an update through `temporalClient.workflowHandle(type:id:)`. `ExtendLoan` moves a loan's due date, which its run is waiting for:

```swift
let loan = try await database.withTransaction { scope in
    …  // the conditional write, with ExtendLoanCommand, or the use case's case when the loan can't be extended
}

let workflowOptions = …  // as BorrowBook builds them
let workflowInput = …
_ = try await temporalClient.signalWithStartWorkflow(
    type: LoanWorkflow.self,
    input: workflowInput,
    options: workflowOptions,
    signalType: LoanWorkflow.ExtendDueDate.self
)
logger.info("Loan extended", metadata: ["loanID": "\(loan.id)"])
return loan
```

The signal carries nothing: its handler ends the run's wait, and the run reads the new date through `markOverdue` ([a workflow](#a-workflow)).

- The use case makes the change itself, as its conditional write in its own transaction, then signals the run after the commit. The row is the record and the signal only wakes the run, whose next activity reads the row. The caller's write stays under row-level security, and the request's values stay out of the workflow's history, which keeps every payload for as long as the namespace retains it.
- The run's correctness never rests on the signal. A run that wakes at the old due date, its signal lost or racing the extension, finds the loan not due, since the transition names the due date ([state transitions](persistence.md#repositories-and-statements)), and waits again for the date the activity reports.
- A fact that outlives the run, such as a return, needs no signal: it stays in the database, where the activity that acts on it reads it (`markOverdue`).
- The signal follows every call that finds the row in the state it reports, a repeat included, so a retried request delivers a signal lost after the first commit. Its handler sets a property, so a second delivery changes nothing.
- A run may never have started, its start lost after the commit, so a signal is sent with signal-with-start under the start's id and policies, and the use case holds what a start needs: Temporal signals the run that's there, or starts it and delivers the signal, in one call.
- An update is for the one case a signal can't serve: the answer must come from the run, which alone knows whether the step may happen now. The use case authorizes the caller before sending it, and its input names the user it acts for, since the worker binds no caller. Its handler refuses by the workflow's state first, runs the write as an activity over a system use case, and answers what the run decided, which the use case maps to its cases.
- A handler whose activity fails leaves the workflow's state as it found it, and that activity's attempts are bounded ([activity options](#activity-options)).
- Where a record's status and a run's stage are the same steps, the row holds them. The workflow keeps only what it waits on, and moves on from what an activity reports its use case found, never from its own count of the steps.
- A query reads a run's state for a person. A screen people page through reads a table instead ([when work is a workflow](#when-work-is-a-workflow)).

## A workflow

```swift
package import Temporal

/// A loan from borrowing to its due date: a book still out then makes the loan overdue,
/// and the member is sent a notice.
@Workflow
package struct LoanWorkflow {
    package struct Input: Codable, Sendable {
        package let loanID: UUID
        package let userID: UUID
        package let bookID: UUID
        package let dueDate: Date

        package init(loanID: UUID, userID: UUID, bookID: UUID, dueDate: Date) { … }
    }

    private var isDueDateExtended = false

    package mutating func run(context: WorkflowContext<Self>, input: Input) async throws {
        let markOverdueInput = LoanActivities.MarkOverdueInput(loanID: input.loanID)
        var markOverdueOutput = LoanActivities.MarkOverdueOutput.notDue(until: input.dueDate)
        while case .notDue(let dueDate) = markOverdueOutput {
            // Waits for the due date, or for an extension to move it; a run started again after it doesn't wait.
            isDueDateExtended = false
            let timeUntilDue = dueDate.timeIntervalSince(context.now)
            let timeToWait = max(timeUntilDue, 0)
            do {
                try await context.timeout(for: .seconds(timeToWait)) {
                    try await context.condition { $0.isDueDateExtended }
                }
            } catch is CanceledError {
                // The due date came first.
            }

            markOverdueOutput = try await context.executeActivity(
                LoanActivities.Activities.MarkOverdue.self,
                options: .database,
                input: markOverdueInput
            )
        }
        guard markOverdueOutput == .overdue else {
            return
        }

        let noticeInput = LoanActivities.SendOverdueNoticeInput(
            loanID: input.loanID,
            userID: input.userID,
            bookID: input.bookID
        )
        try await context.executeActivity(
            LoanActivities.Activities.SendOverdueNotice.self,
            options: .notification,
            input: noticeInput
        )
    }

    /// Ends the wait, so the run reads the due date an extension moved.
    @WorkflowSignal
    package mutating func extendDueDate(input: Void) {
        isDueDateExtended = true
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
- A workflow takes a nested `Input` and returns a nested `Output` (or nothing), with explicit initializers.
- Every payload is `Codable, Sendable`, and so is every type it holds: a workflow's input and output, a signal's, query's or update's, and an activity's. The SDK requires only `Sendable` and checks `Codable` when it converts the value, so a missing conformance compiles, then fails on every attempt. A domain enum a payload needs is mirrored as a nested enum, or, when two workflows share it, as a type directly in `Workflows/`.
- State that handlers change is the workflow's private stored properties. A signal is a `@WorkflowSignal mutating func`; a query a `@WorkflowQuery func` taking `input:` and returning a value, which can't mutate; an update, which changes state and answers, a `@WorkflowUpdate`. The macros generate the types callers name, the method's name capitalized.

## Determinism

A workflow takes the same path on every replay, as `temporal-developer` gives it. In Swift:

| Instead of | A workflow uses |
|---|---|
| `Date.now` | `context.now` |
| `Task.sleep`, `Clock.sleep` | `context.sleep(for:)` |
| `UUID()`, `.random(in:)` | `context.randomNumberGenerator`, or a value an activity returns |
| A `Logger` from the composition root | `Logger.current`, which the worker keeps quiet during replay |
| `Task {}`, `Task.detached`, actors | `async let`, task groups, child workflows |

Workflows and their inputs are value types; nothing in a workflow holds a reference to a service, a client or a repository.

## Activities

An activity container is an inbound adapter that lives in Core, the worker's counterpart to a gRPC service: it holds use cases and ports, and maps their errors. There is one container per workflow, named after it. An activity several workflows share gets its own small container, named for its step, in `Workflows/`.

A container is injected only with use case protocols (`any MarkLoanOverdueUseCaseProtocol`) and port protocols (`any CatalogClient`), plus a `Logger` if needed. It never receives a repository, a database or scope, a concrete adapter type, `TemporalClient` or configuration.

```swift
package import Temporal

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

    package enum MarkOverdueOutput: Codable, Equatable, Sendable {
        case notDue(until: Date)
        case overdue
        case returned
    }

    /// Reports the loan as the use case left it: one extended in the meantime isn't due yet,
    /// and one returned stays returned.
    @Activity
    package func markOverdue(input: MarkOverdueInput) async throws -> MarkOverdueOutput {
        do {
            let markLoanOverdueInput = MarkLoanOverdueUseCaseInput(loanID: input.loanID)
            let loan = try await markLoanOverdueUseCase(input: markLoanOverdueInput)
            switch loan.status {
            case .active:
                return .notDue(until: loan.dueDate)
            case .overdue:
                return .overdue
            case .returned:
                return .returned
            }
        } catch {
            switch error {
            case .loanNotFound:
                throw ApplicationError(message: "The loan does not exist.", type: "LoanNotFound", isNonRetryable: true)
            case .unknown:
                throw error
            }
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
        let member = …  // from identityClient, on every attempt; none is non-retryable
        let book = …  // from catalogClient, the same way

        let idempotencyKey = "loans-overdue-notice-\(input.loanID.uuidString.lowercased())"
        try await noticeSender.sendOverdueNotice(member: member, book: book, idempotencyKey: idempotencyKey)
    }
}
```

- An activity runs a [system use case](use-cases.md#system-use-cases) when the step reads or writes this service's data, on the worker's database, and calls a port when the step is one effect another system owns; a use case that would only forward to the port adds nothing. It makes no business decision: the use case decides, and the activity reports what it decided, never discarding what the use case returned, since the workflow's next step depends on that answer.
- Its input is a small struct nested in the container, named for the activity (`MarkOverdueInput`), holding ids and values, never commands; the activity builds what the use case or port takes.
- It returns a primitive or a small nested output holding only what the workflow reads (`MarkOverdueOutput`), never a domain model, which isn't `Codable`.
- It maps its use case's error as a handler does ([errors](style.md#errors)): a permanent failure, a case no retry can change, becomes `ApplicationError(message:type:isNonRetryable: true)`, and every other case is rethrown, so Temporal retries it.
- It's safe to run twice: writes are conditional or keyed, and external effects carry an idempotency key derived from the workflow's subject (`loans-overdue-notice-<loan id>`). When one subject gets the effect more than once, such as a member's successive reset codes, the key adds the effect's own stored id: never a value made at send time, which a retry wouldn't repeat, and never a secret or part of one.
- Activities are registered by name, the method's name capitalized (`MarkOverdue`).

## Activity options

Named once per target, in `ActivityOptions+X.swift` in the folder of the first workflow that needs them, and used by name in every workflow of the target. A write to the service's own data retries until it lands. An effect that loses its worth when late, such as a notice, and a step a caller waits on inside an update, take options with `maximumAttempts`:

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
        retryPolicy: RetryPolicy(
            initialInterval: .seconds(1),
            backoffCoefficient: 2,
            maximumInterval: .seconds(30),
            maximumAttempts: 5
        )
    )
}
```

## Changing a workflow

A deploy replaces the code under every run in flight, and `LoanWorkflow`'s runs last a loan's whole period, so every change to a workflow replays the histories those runs have already written. How a change is patched follows `temporal-developer`; these rules hold around it:

- A change to the commands a workflow issues, such as an activity added, removed or reordered, or a wait changed, takes the new path behind `context.patch("<change>")` and keeps the old one. Once no run that started before the change remains, `context.deprecatePatch("<change>")` replaces the branch in one deploy, and a later deploy removes it.
- A change too large to patch is a new workflow type, which new runs start; the worker registers it beside the old one until the old one's runs have ended.
- A change to an activity's body alone, or to a payload's optional field, replays without a patch.
- `temporal.worker.buildid` labels which code a worker ran. The worker doesn't version by build id, so every worker polls every run, which is why a change must replay.
- `XCoreTests` replays each workflow's recorded histories, so a change that breaks a run in flight fails its build before it deploys ([test targets](testing.md#test-targets)).

## Recurring work

Work on a calendar is a workflow a Temporal Schedule starts: never a timer loop in serve, a cron container, or a workflow that sleeps forever.

- A service declares its schedules once, in `XCore/Workflows/XSchedules.swift`: each one's id, calendar, workflow and input, with `overlap: .skip`, so a run that outlasts its interval isn't joined by a second.
- `worker run` applies them before its `ServiceGroup` starts, creating or updating each by its id, so every replica converges on the declared schedules ([the worker's root](composition.md#the-workers-root)).

## The worker

`x worker run` builds the worker in [its own root](composition.md#the-workers-root):
- It connects to Postgres as the worker role ([database roles](persistence.md#database-roles)).
- Each service has one task queue, named for it (`loans`), under the SDK's key `temporal.worker.taskqueue`, which the serve process also reads for its starts.
- Each service has its own namespace, named like its package (`bookshelf-loans`), so its runs, schedules and retention are its own. No service reaches another's runs: what another service must do, it asks through that service's contract.
- How each process connects to Temporal, such as Temporal Cloud with an API key over TLS, or a self-hosted server with mTLS, is a question the plan puts to the user, with no default; the roots build the connection the answer names. Whatever the answer, each process reaches its service's namespace only, and a setup that would let it reach another's goes to the user as a question too.
- swift-temporal-sdk's readers, `TemporalClient.Configuration(configReader:)` and `TemporalWorker.Configuration(configReader:)`, require their keys before a root runs, so the defaults or the deployment set every one ([configuration](composition.md#configuration)):

  | Key | Value | Set by |
  |---|---|---|
  | `temporal.client.namespace`, `temporal.worker.namespace` | The service's namespace, the same in both | The defaults |
  | `temporal.worker.taskqueue` | The service's task queue | The defaults |
  | `temporal.client.instrumentation.serverhostname`, `temporal.worker.client.instrumentation.serverhostname` | The Temporal host | The deployment |
  | `temporal.worker.buildid` | The image's commit | The deployment |
  | `temporal.worker.client.identity` | The process's identity | The deployment |

- A release of the SDK may require another key: read the two readers' source for the release the package resolves before wiring a root, and add what they require.
