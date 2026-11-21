# Observability

How each process records traces and metrics with swift-otel, and how one request's trace follows it from the gateway through the services, Temporal and the worker. The collector and the backends that store and show the data are the deployment's ([out of scope](system.md#out-of-scope)).

## The bootstrap

Every long-running root bootstraps swift-otel in its Observability section, after Logging, as [the composition root](composition.md#the-composition-root) shows:

- `OTel.bootstrap(configuration:)` sets the process's `MetricsSystem` and `InstrumentationSystem` once and returns the exporters' `Service`, which goes first in the `ServiceGroup`, so it shuts down last and flushes what the other components recorded ([lifecycle](composition.md#lifecycle)).
- Logs stay on standard output, where the deployment collects them: `logs.enabled` is `false`, so `LoggingSystem.bootstrap` keeps its handler, and its metadata provider adds the trace and span ids to every line a traced request logs ([logging](composition.md#logging)).
- The service name is the root's logger label ([naming](conventions.md#naming)): `bookshelf-loans` for serve and `bookshelf-loans-worker` for the worker.
- swift-otel reads the OpenTelemetry environment variables itself, the one source of values outside the `ConfigReader`, since the specification names them. The deployment sets `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`, and the collector's certificate paths when it requires mTLS. The root sets in code only what the code decides: the service name, and logs off.
- swift-otel is declared with `traits: ["OTLPGRPC"]`, since every process already links the gRPC stack ([traits and Foundation](packages.md#traits-and-foundation)).
- A short-lived command bootstraps nothing: it has no `ServiceGroup` to run the exporters, and its log line and exit status report it ([commands](composition.md#commands)).

## A trace across processes

Each hop continues the trace its caller started, so one borrow reads as one trace from the gateway's route to the overdue notice:

| Hop | What records it and carries the trace on |
|---|---|
| The gateway's routes | Hummingbird's `TracingMiddleware`, after CORS on the router, starts the request's span; `MetricsMiddleware` beside it records each route's requests, errors and duration ([the gateway's root](composition.md#the-gateways-root)) |
| A gRPC call out | `ClientOTelTracingInterceptor`, first in every `GRPCClient`'s pipeline, the gateway's and every service's and worker's, writes the trace into the call's metadata |
| A gRPC call in | `ServerOTelTracingInterceptor`, first in the server's pipeline, on every `XService` and `XInternalService` descriptor, continues it before authentication, so a refused call is traced too |
| Temporal | `TemporalClient.Configuration(configReader:)` and `TemporalWorker.Configuration(configReader:)` install the SDK's tracing interceptors, which carry the trace from a use case's start or signal through the workflow's headers into each activity and its port calls |

- `serverHostname` is the server's name from `grpc.server.hostname` for a server's interceptor and the upstream's host for a client's; `networkTransportMethod` is `"tcp"`.
- The interceptors keep `includeRequestMetadata` and `includeResponseMetadata` off: request metadata holds the bearer token, which never reaches a span ([user tokens](security.md#user-tokens)).
- The deployment's probes record no spans: the health service's descriptor isn't traced, and the gateway's `/health` comes before its middleware ([health](composition.md#health)).
- A root never replaces the Temporal configurations' `interceptors`, which would drop the SDK's tracing.
- A gRPC call's duration and status are on its span, so services record no metrics of their own for calls; the gateway's `MetricsMiddleware` covers the public API.
