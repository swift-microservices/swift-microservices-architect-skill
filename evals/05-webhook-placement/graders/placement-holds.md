---
type: llm
focus: last_message
---
- The gateway exposes the webhook route, verifies the provider's signature over the raw body before decoding it, and refuses an unverified request.
- The gateway forwards the verified event to the service that sent the emails over that service's gRPC contract; the gateway holds no business rules or tables.
- The service handles the event in a use case that runs without a signed-in caller, on a database role that isn't confined to one user.
- A redelivered event changes nothing the first delivery didn't, such as by recording it under the provider's event id.
