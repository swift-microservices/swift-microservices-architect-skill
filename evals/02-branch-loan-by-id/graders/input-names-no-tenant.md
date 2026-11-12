---
type: regex
target: {source: file, path: bookshelf-loans/Sources/LoansCore/Loans/UseCases/GetBranchLoan/GetBranchLoanUseCaseInput.swift}
match: not_contains
flags: i
weight: 0.5
---
let\s+(branch|user)\w*\s*:
