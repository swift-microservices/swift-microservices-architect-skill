# Testing

Tests follow the module map. [Style](style.md) governs `Sources/`; the test code in `Tests/`, with Swift Testing's `@Test`, `#expect`, traits and parameterized cases, follows the Swift Testing skill (`swift-testing-pro`) instead.

## Test targets

Each module has a test target, except `<Project>Testing`, `<project>-protos`' targets and an executable with no readers worth testing. It depends on the module, the modules whose types its tests name (`XCore` for an adapter's), and the mocks it needs, never another adapter or the executable:

```swift
.testTarget(
    name: "LoansCoreTests",
    dependencies: [
        "LoansCore",
        .product(name: "BookshelfAuthentication", package: "bookshelf-core"),
        .product(name: "BookshelfTesting", package: "bookshelf-core"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "Temporal", package: "swift-temporal-sdk"),
        .product(name: "TemporalTestKit", package: "swift-temporal-sdk"),
    ],
    swiftSettings: swiftSettings
),
```

| Test target | Tests | Over |
|---|---|---|
| `XCoreTests` | Each use case: its result and every case of its error | `MockDatabase` with a scope of mock repositories, and mocks of its ports; `TemporalTestKit`'s test server for one that starts a workflow, since `TemporalClient` is a concrete type |
| `XCoreTests`, for workflows | Each workflow's path | `TemporalTestKit`'s time-skipping test server, running the activity container over mocks |
| `XCoreTests`, for workflow changes | Each workflow replays the histories recorded from its runs | `WorkflowReplayer` over the JSON histories in `Histories/<WorkflowName>/`, each exported with `temporal workflow show --output json` from a run of the workflow's previous release |
| `XCoreTests`, for activity containers | Each activity's mapping, calling its method directly | Mocks of the container's use case and port protocols |
| `XGRPCTests` | Each handler: the caller it requires, its conversions, every error case's status; each client for a port: its request, its conversion, the statuses it translates | Mock use cases, and a principal bound in `OperationContext`; a stub of the other service's contract over `GRPCInProcessTransport` |
| `XPostgresTests` | Statements, repositories, row-level security as each role, migrations | A real Postgres, which no mock can stand in for |
| `XValkeyTests` | Each repository's commands, expiries and atomic reads | A real Valkey, since `ValkeyClientProtocol` can't be mocked by hand |
| `XKafkaTests` | Each event handler, calling `receive(_:)` directly: the kinds it ignores, its conversion's rejections, every case's outcome; each publisher's conversion | Mock use cases, and events the test builds; no broker, since the producer is concrete and a handler never sees it |
| `GatewayHTTPTests` | Routes in their tiers, conversions, problem details | Mock upstream clients and `MockAuthenticator` |

- A test runs only its module's code, over mocks of the rest: a handler's test doesn't build a use case, and a use case's test never reaches Postgres.
- A workflow's suite takes the trait `.temporalTimeSkippingTestServer`, and a starting use case's `.temporalTestServer`; how a test connects a client or runs a worker on it is `TemporalTestKit`'s documentation.
- A run downloads the test server on first use, so the machine running `XCoreTests` needs network access.
- `XPostgresTests` share one harness, in `Support/TestDatabase.swift`: it connects as the owner from `POSTGRES_*`, resets the schema, applies `XMigrations.all(…)`, the list the executable applies, and gives each test a `PostgresDatabase` per role, each transaction taking its role with the constant setting `role` and its caller through `PostgresSettings.user(_:)`. A test of row-level security then runs the statements the service runs, as the role that runs them.
- A statement Postgres refuses inside the harness's `withTransaction` arrives as the `PSQLError` itself, since `PostgresDatabase` rethrows the closure's error ([transactions](use-cases.md#transactions)).
- `X<Provider>Tests` test the provider target's mapping the same way, and the executable's readers and defaults, when tested, are in `XTests`.
- `XPostgresTests` and `XValkeyTests` fail, rather than skip, when `POSTGRES_HOST` or `VALKEY_HOST` is unset. No check is turned off to make CI pass.

`<project>-core`'s products are what every service trusts, so their tests prove:

| Test target | Proves |
|---|---|
| `<Project>AuthenticationTests` | The token's exact claims; the issue-and-verify round trip through `JWTIssuer(privateKey:)` and `JWTAuthenticator(publicKeys:)`, with the key's `kid` in the header; refusal of an expired token, of a `sub` that isn't a UUID and of a key the authenticator doesn't hold; the `.user` metadata provider |
| `<Project>PersistenceTests` | Both branches of `UserSettingsInterceptor`: a bound user's setting, and nothing when none is bound |
| `<Project>TransportTests` | `InternalCallerInterceptor` admits a listed RPC's caller by a DNS name in any case, refuses another caller, a certificate that names the caller only as its common name, and a call with no certificate, and passes an RPC it doesn't list |
| `<Project>EventsTests` | `EventConsumer` stores an offset only once its handler returns or rejects, retries any other error, and skips a value that doesn't decode; the readers' settings. Over librdkafka's in-process mock cluster, which `@_spi(Internal) import Kafka` reaches in tests |

`<Project>Testing` has no test target: the tests that use it prove the mocks, and every service's startup proves `<Project>Transport`'s readers.

```
Tests/
├── LoansCoreTests/         Mocks/, BorrowBookUseCaseTests.swift, …
└── LoansGRPCTests/         Mocks/, LoanServiceTests.swift, …
```

## Mocks

- A mock conforms to the protocol it stands in for ([naming](conventions.md#naming)).
- It's hand-written: it returns, or throws, what its initializer was given. One that records its calls is a `final class` keeping them in a `Mutex`, so it stays `Sendable` without `@unchecked`. There's no mocking framework.
- A mock every service would write alike comes from a shared package's testing product instead. `<Project>Testing` holds `MockDatabase<Scope>`, which runs a transaction's closure on the scope a test gives it, and `MockAuthenticator`, which maps tokens to identities. A library whose protocols services depend on may ship such a product too.
