# Events

Facts a service publishes to Kafka for other services to react to, with swift-kafka-client: when a fact is an event rather than a call or a workflow, its contract, publishing it through the outbox, consuming it, and the worker that runs both. A backend has no events until a need in [choosing a mechanism](#choosing-a-mechanism) calls for one.

## Contents
- Choosing a mechanism
- An event's contract
- The outbox
- Consumers
- The worker

## Choosing a mechanism

Each need between processes has one mechanism. Ask in this order, and take the first yes:

| Question | Mechanism |
|---|---|
| Does the caller need the owner's answer to go on? | Unary gRPC to the owner ([how services talk](system.md#how-services-talk)) |
| Must this service see the work through: wait for a time or a signal, retry until it lands, compensate, or take steps in other services? | A workflow it starts ([workflows](workflows.md)) |
| Has something happened to this service's data that other services react to, each on its own? | An event |

The last two split on who owns what follows:
- A workflow is work with an owner. Its service names every step and every service it calls, knows when the work is done, and acts when it fails. Loans must send the overdue notice after the due date and know whether it went out, so the notice is `LoanWorkflow`'s.
- An event is a fact with no owner of what follows. The publisher records what happened and is done: it never waits for a consumer, names one, or learns whether one succeeded. Each consumer's reaction, and its failure, is the consumer's own, and a new consumer subscribes without a change to the publisher.

In Bookshelf:

| Need | Mechanism | Not the other, because |
|---|---|---|
| Mark a loan overdue at its due date and send a notice | `LoanWorkflow` | An event has no timer, and Loans must know when the notice fails |
| Erase a member's data from every service | `AccountErasureWorkflow` ([erasing a person's data](system.md#erasing-a-persons-data)) | Identity must know each service erased it; after an event, nobody notices the consumer that never did |
| Order Catalog's books by how often they're borrowed | Loans' `LoanEvent`, which Catalog counts | Catalog calling Loans would close a cycle with Loans' calls to Catalog, and a workflow in Loans would have to name Catalog, then every later consumer |
| Feed loans to a warehouse or a search index | The same `LoanEvent` | Consumers arrive and leave without a change to Loans, and a new one reads the topic from its oldest event |
| Whether a book exists when a member borrows it | `GetBook` on Catalog's internal service | A consumer's copy lags its owner, so a decision that must see the owner's current state asks the owner |

- Kafka is never a work queue. A message that one consumer must see through with retries, backoff or waits is a workflow: a consumer retries only in place, holding its partition behind the one message, and has no timers.
- Temporal is never an event bus. A workflow never starts or signals runs in another service's namespace ([the worker](workflows.md#the-worker)), and a stream of facts would grow a run's history without bound.
- They meet at a service's boundary: an event crosses between services, and a consumer whose reaction waits, retries a remote call or spans services starts a workflow of its own from the event ([consumers](#consumers)).
- A step inside one service is never an event: it's a use case's transaction, or a workflow's activity.

## An event's contract

`<project>-protos/Sources/LoansProtos/bookshelf/loans/v1/events.proto`:

```proto
syntax = "proto3";

package bookshelf.loans.v1;

import "google/protobuf/timestamp.proto";

// A change to a loan, on bookshelf.loans.v1.loan-events, keyed by loan_id.
message LoanEvent {
  string id = 1;
  string loan_id = 2;
  string book_id = 3;
  LoanEventKind kind = 4;
  google.protobuf.Timestamp occurrence_date = 5;
}

enum LoanEventKind {
  LOAN_EVENT_KIND_UNSPECIFIED = 0;
  LOAN_EVENT_KIND_BORROWED = 1;
  LOAN_EVENT_KIND_RETURNED = 2;
  LOAN_EVENT_KIND_MARKED_OVERDUE = 3;
}
```

- A service's events are messages in its own proto package, in `events.proto`, one `<Resource>Event` per resource, under the contract's [message and change rules](grpc.md#contracts-in-the-protos-package). An incompatible change is a `v2` message on a `v2` topic, published beside `v1` until its last consumer has moved.
- One topic per resource, named as [naming](conventions.md#naming) gives it and keyed by the resource's id, so a resource's events share a partition. The deployment creates each topic with the partitions and retention the plan records; nothing relies on the broker creating one.
- A kind is a fact in the past tense (`BORROWED`), never a request (`SEND_NOTICE`) or an instruction to a consumer.
- An event carries its own `id`, the resource's id, and only the fields its consumers need. It carries ids, never personal data: a topic keeps its messages for its retention, beyond the reach of [erasure](system.md#erasing-a-persons-data). A consumer that needs a member's name asks Identity.

## The outbox

The use case that makes the change records the event in the same transaction, into the service's outbox, a table per resource (`loan_event_outbox`). The worker's relay publishes the rows to Kafka and deletes each once Kafka has acknowledged it. A publish after the commit would be lost whenever the process stops between the two, and unlike a workflow's start no client retries it, since no client waits on an event; a publish inside the transaction would announce a change that may still roll back.

`ReturnBook`'s transaction:

```swift
let loan = try await database.withTransaction { scope in
    guard let returnedLoan = try await scope.loanRepository.markReturned(id: input.loanID) else {
        …  // the use case's case: no such loan, or returned already
    }

    let eventCommand = RecordLoanEventCommand(loanID: returnedLoan.id, bookID: returnedLoan.bookID, kind: .returned)
    try await scope.loanEventRepository.record(eventCommand)
    return returnedLoan
}
```

- Every use case that makes the change records its event, a person's (`BorrowBook`, `ReturnBook`) and the system's (`MarkLoanOverdue`) alike. A repeat that finds the change already made records nothing, so each change is published once.
- `LoanEvent` and `LoanEventKind` are Core models in the resource's area. `LoanEventRepository` records into the outbox, and claims and deletes for the relay; the scope of every role whose use cases record events holds it ([database roles](persistence.md#database-roles)). Ids and dates default in the database, the id a `uuidv7()` the relay orders by ([repositories and statements](persistence.md#repositories-and-statements)).

The relay is a system use case on the worker's database, `PublishLoanEventsUseCase`, over a port, `LoanEventPublisher`, which XKafka implements:

```swift
package func callAsFunction() async throws(PublishLoanEventsUseCaseError) -> Int {
    do {
        // A lease rather than a lock held through the publish: the transaction holds only database work.
        let events = try await database.withTransaction { scope in
            try await scope.loanEventRepository.claim(limit: 100)
        }
        guard !events.isEmpty else {
            return 0
        }

        try await loanEventPublisher.publish(events)

        let eventIDs = events.map(\.id)
        try await database.withTransaction { scope in
            try await scope.loanEventRepository.delete(ids: eventIDs)
        }
        return events.count
    } catch LoanEventPublisherError.unavailable {
        logger.warning("Publishing loan events failed: Kafka is unavailable")
        throw .publisherUnavailable
    } catch is CancellationError {
        throw .unknown
    } catch {
        logger.error("Publishing loan events failed: unknown error", metadata: ["error": "\(error)"])
        throw .unknown
    }
}
```

- `claim(limit:)` takes the oldest rows whose lease is unset or has expired, in id order, and leases them for longer than a batch takes to publish. Rows a stopped relay leased are claimed again once their lease expires.
- `KafkaLoanEventPublisher` sends a batch in order with `sendAndAwait`, each event keyed by its loan's id, and throws `unavailable` at the first that fails; the batch's rows stay until their lease expires.
- So a consumer may receive an event more than once, and the relays of several worker replicas may publish a resource's events out of order: every consumer deduplicates and never relies on order ([consumers](#consumers)).
- `OutboxRelay`, from `<Project>Events`, calls the use case again at once while it publishes, and a second after a call that published nothing or failed.

## Consumers

A service reacts to another service's topic with a handler in its XKafka, over a system use case, as an activity container is over its use cases. Catalog counts borrows:

```swift
package import BookshelfEvents
package import CatalogCore
package import LoansProtos

/// Counts each book's borrows from Loans' loan events, for the catalog's most-borrowed order.
package struct LoanEventHandler: EventHandler {
    private let recordBookBorrowUseCase: any RecordBookBorrowUseCaseProtocol

    package init(recordBookBorrowUseCase: any RecordBookBorrowUseCaseProtocol) {
        self.recordBookBorrowUseCase = recordBookBorrowUseCase
    }

    package func receive(_ event: Bookshelf_Loans_V1_LoanEvent) async throws {
        guard event.kind == .borrowed else {
            return
        }

        let input = try RecordBookBorrowUseCaseInput(event)

        do throws(RecordBookBorrowUseCaseError) {
            try await recordBookBorrowUseCase(input: input)
        } catch {
            switch error {
            case .bookNotFound:
                return  // A book the catalog no longer holds keeps no count.
            case .unknown:
                throw error
            }
        }
    }
}
```

- `receive(_:)` acts on the kinds it handles and returns on every other, those added after it was written included.
- Its conversion follows [conversions](grpc.md#conversions), in XKafka's `Protobuf/`, and refuses a malformed event with `EventRejection`, as a request's conversion refuses with `invalidArgument`.
- It maps its use case's error as an activity does ([activities](workflows.md#activities)): a case no retry changes returns, or throws `EventRejection` when the event itself is wrong, and every other case is rethrown, so the event is retried. No logging: the use case logged what happened.
- The use case is a system use case on the worker's database, safe to run twice: its write is keyed by the fact it records, or by the event's `id` when the fact has no key of its own. `RecordBookBorrow` inserts the loan into `book_borrows`, keyed by its loan id, and raises the book's `borrow_count` only when the insert lands, in one transaction, so a redelivery and an out-of-order arrival count once.
- A reaction that waits, retries a remote call or spans services is a workflow the use case starts, by an id that names the event, with the policies a webhook's start takes ([starting a workflow](workflows.md#starting-a-workflow-from-a-use-case)).

`EventConsumer`, from `<Project>Events`, runs a handler over one topic. It decodes each message into the handler's event, and stores the message's offset once `receive(_:)` returns or throws `EventRejection`, logging a rejection, and a value that doesn't decode, with its topic, partition and offset. Any other error it logs and retries after a pause, before the next message, so an offset never passes an event the handler hasn't finished. Kafka commits the stored offsets, so a restart redelivers at most what was handled since the last commit.

## The worker

A service's events run in its worker process ([commands](composition.md#commands)): the relay when it publishes, and an `EventConsumer` per topic it consumes. Catalog has no workflows, so its worker builds no Temporal worker. Loans' worker root adds:

```swift
// MARK: - Events
let kafkaConfig = config.scoped(to: "kafka")
let loanEventsTopic = try kafkaConfig.requiredString(forKey: "topics.loanEvents")
let producerConfig = try KafkaProducerConfig(config: kafkaConfig)
let (loanEventProducer, _) = try KafkaProducer.makeProducer(config: producerConfig)
let loanEventPublisher = KafkaLoanEventPublisher(producer: loanEventProducer, topic: loanEventsTopic)
let publishLoanEventsUseCase = PublishLoanEventsUseCase(
    database: workerDatabase,
    loanEventPublisher: loanEventPublisher,
    logger: logger
)
let loanEventRelay = OutboxRelay(logger: logger) {
    try await publishLoanEventsUseCase()
}

// MARK: - Lifecycle
// observability, certificateReloader, temporalCertificateReloader, workerPostgresClient,
// identityGRPCClient, catalogGRPCClient, loanEventProducer, loanEventRelay, worker
```

Catalog's builds a consumer for the same topic:

```swift
let consumerConfig = try KafkaConsumerConfig(config: kafkaConfig, topic: loanEventsTopic)
let (loanEventConsumer, loanEventMessages, _) = try KafkaConsumer.makeConsumer(config: consumerConfig)
let loanEventHandler = LoanEventHandler(recordBookBorrowUseCase: recordBookBorrowUseCase)
let loanEvents = EventConsumer(
    consumer: loanEventConsumer,
    messages: loanEventMessages,
    handler: loanEventHandler,
    logger: logger
)
```

- A producer comes before its relay, and a `KafkaConsumer` before its `EventConsumer`, both after the database clients they use, so the relay stops before its producer flushes, and the handler before its consumer leaves the group ([lifecycle](composition.md#lifecycle)).
- Only `sendAndAwait` reports deliveries, so the producer's events sequence is discarded, as is the consumer's.
- `<Project>Events`' readers give every client what the project fixes: the brokers, TLS and its service's Kafka user ([the trust model](security.md#the-trust-model)); a producer idempotence and acknowledgment by every in-sync replica; a consumer its group, `<x>`, offsets stored only by `EventConsumer`, and the oldest offset for a group that has none, so a new consumer reads the topic from its start. A topic's name is a configuration key the publisher's and each consumer's defaults set alike.
- The worker serves nothing: swift-kafka-client's `consumer.lag` metric shows whether a consumer keeps up, and joins the plan's alerts ([the plan](system.md#the-plan)).
