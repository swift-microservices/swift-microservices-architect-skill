---
type: llm
focus: {source: file, path: bookshelf-loans/Sources/LoansCore/Loans/UseCases/GetBranchLoan/GetBranchLoanUseCase.swift}
---
- A caller who isn't a librarian acting for a branch is refused as forbidden before anything else.
- The loan is read by the input's id in one transaction, and a loan the branch can't see answers as not found.
