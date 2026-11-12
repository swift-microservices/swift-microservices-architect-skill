---
type: llm
focus: trace
---
- The reminder is a step of the existing `LoanWorkflow`, and the change to it is versioned so runs already in flight replay without a nondeterminism error.
- The workflow code waits with Temporal's timer and reads no clock, random value or UUID of its own.
- The email is sent by an activity that runs a system use case or calls a Core port, never from the workflow code itself.
- A loan returned before the reminder gets no email, decided from the loan's row as an activity reads it, not from a signal sent on return.
