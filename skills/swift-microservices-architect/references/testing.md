# Testing

Tests follow the module map: each target is tested on its own, over mocks of the protocols it depends on. The test code inside, with Swift Testing's `@Test`, `#expect`, traits and parameterized cases, follows the Swift Testing skill (`swift-testing-expert`).

## Test targets

Each module has a test target that depends on the module and the mocks it needs, and nothing else:

```swift
.testTarget(
    name: "LoansCoreTests",
    dependencies: [
        "LoansCore",
        .product(name: "BookshelfTesting", package: "bookshelf-core"),
    ],
    swiftSettings: swiftSettings
),
```

| Test target | Tests | Over |
|---|---|---|
| `XCoreTests` | Each use case: its result and every case of its error | `MockDatabase` with a scope of mock repositories, and mocks of its ports |
| `XGRPCTests` | Each handler: the caller it requires, its conversions, every error case's status | Mock use cases, and a principal bound in `OperationContext` |
| `XTemporalTests` | Each workflow's path, and replays of recorded histories; each activity's mapping | Temporal's time-skipping test server with mock activities; mock use cases and ports |
| `XPostgresTests` | Statements, repositories, row-level security as each role, migrations | A real Postgres, the one dependency a mock can't stand in for |
| `GatewayHTTPTests` | Routes in their tiers, conversions, problem details | Mock upstream clients and `MockAuthenticator` |

- A test target never depends on a sibling module or the executable: a handler's test doesn't build a use case, and a use case's test never reaches Postgres.
- Other adapter targets (`XValkeyTests`, `X<Provider>Tests`) test their own mapping the same way, and the executable's readers and defaults, when tested, are in `XTests`.

```
Tests/
├── LoansCoreTests/         Mocks/, BorrowBookUseCaseTests.swift, …
└── LoansGRPCTests/         Mocks/, LoanServiceTests.swift, …
```

## Mocks

- A mock conforms to the protocol it stands in for and is named for it: `MockLoanRepository`, `MockCatalogClient`, `MockBorrowBookUseCase` for `BorrowBookUseCaseProtocol`.
- It's hand-written: it returns, or throws, what its initializer was given. One that records its calls is a `final class` keeping them in a `Mutex`, so it stays `Sendable` without `@unchecked`. There's no mocking framework.
- A mock lives in the `Mocks/` folder of the test target that uses it, never in a module's sources.
- A mock every service would write alike comes from a shared package's testing product instead. `<Org>Testing` holds `MockDatabase<Scope>`, which runs a transaction's closure on the scope a test gives it, and `MockAuthenticator`, which maps tokens to identities. A library whose protocols services depend on may ship such a product too.
