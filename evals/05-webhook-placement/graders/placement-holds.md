---
type: llm
focus: last_message
---
- The gateway's webhook route sits in the tier with no caller and forwards the body unparsed, with the headers the provider signs, to the email-sending service's RPC for anyone; the gateway verifies nothing itself and holds no business rules or tables.
- The service's use case verifies the signature and its timestamp before anything else, through a port that a provider-specific target implements, with the signing secret read as a secret, and refuses an event that fails as unauthenticated.
- The use case runs without a signed-in caller, on a database role that isn't confined to one user.
- A redelivered event changes nothing the first delivery didn't, because the transaction that acts records the provider's event id under a unique key.
