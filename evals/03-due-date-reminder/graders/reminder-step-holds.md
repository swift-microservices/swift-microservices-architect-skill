---
type: llm
focus: {source: file, path: bookshelf-loans/Sources/LoansCore/Workflows/LoanWorkflow/LoanWorkflow.swift}
---
- The reminder step is versioned, so runs already in flight replay without a nondeterminism error.
- The email goes out through an activity, never from the workflow code.
- A loan returned before the reminder gets no email, decided by what an activity reads from the loan's row, not by a signal sent on return.
