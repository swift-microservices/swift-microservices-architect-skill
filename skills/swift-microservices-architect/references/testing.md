# Testing

Tests follow the module map: each target is tested on its own, over mocks of the protocols it depends on. [Style](style.md) governs `Sources/`; the test code in `Tests/`, with Swift Testing's `@Test`, `#expect`, traits and parameterized cases, follows the Swift Testing skill (`swift-testing-expert`) instead.

## Test targets

Each module has a test target. It depends on the module, the modules whose types its tests name (`XCore` for an adapter's), and the mocks it needs, never another adapter or the executable:

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
| `XCoreTests`, for activity containers | Each activity's mapping, calling its method directly | Mocks of the container's use case and port protocols |
| `XGRPCTests` | Each handler: the caller it requires, its conversions, every error case's status | Mock use cases, and a principal bound in `OperationContext` |
| `XPostgresTests` | Statements, repositories, row-level security as each role, migrations | A real Postgres, the one dependency a mock can't stand in for |
| `GatewayHTTPTests` | Routes in their tiers, conversions, problem details | Mock upstream clients and `MockAuthenticator` |

- A test runs only its module's code, over mocks of the rest: a handler's test doesn't build a use case, and a use case's test never reaches Postgres.
- A workflow's suite takes the trait `.temporalTimeSkippingTestServer` and reads `TemporalTestServer.timeSkippingTestServer`; a starting use case's takes `.temporalTestServer` and reads `.testServer`. `withConnectedClient(logger:_:)` gives it a `TemporalClient`, and `withConnectedWorker(configuration:activities:workflows:_:)` runs a worker, with `activities: loanActivities.allActivities`. An activity that reads `ActivityExecutionContext` runs inside `withActivityTestEnvironment(info:_:)`.
- A run downloads the test server on first use, so the machine running `XCoreTests` needs network access.
- Other adapter targets (`XValkeyTests`, `X<Provider>Tests`) test their own mapping the same way, and the executable's readers and defaults, when tested, are in `XTests`.
- `XPostgresTests` fail, rather than skip, when `POSTGRES_HOST` is unset. No check is turned off to make CI pass.

`<project>-core`'s products are what every service trusts, so their tests prove:

| Test target | Proves |
|---|---|
| `<Project>AuthenticationTests` | The token's exact claims; the issue-and-verify round trip; refusal of an expired token and of a `sub` that isn't a UUID; the `.user` metadata provider |
| `<Project>PersistenceTests` | Both branches of `UserSettingsInterceptor`: a bound user's setting, and nothing when none is bound |

```
Tests/
├── LoansCoreTests/         Mocks/, BorrowBookUseCaseTests.swift, …
└── LoansGRPCTests/         Mocks/, LoanServiceTests.swift, …
```

## Mocks

- A mock conforms to the protocol it stands in for and is named for it: `MockLoanRepository`, `MockCatalogClient`, `MockBorrowBookUseCase` for `BorrowBookUseCaseProtocol`.
- It's hand-written: it returns, or throws, what its initializer was given. One that records its calls is a `final class` keeping them in a `Mutex`, so it stays `Sendable` without `@unchecked`. There's no mocking framework.
- A mock lives in the `Mocks/` folder of the test target that uses it, never in a module's sources.
- A mock every service would write alike comes from a shared package's testing product instead. `<Project>Testing` holds `MockDatabase<Scope>`, which runs a transaction's closure on the scope a test gives it, and `MockAuthenticator`, which maps tokens to identities. A library whose protocols services depend on may ship such a product too.
