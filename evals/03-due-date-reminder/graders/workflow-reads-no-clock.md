---
type: regex
target: {source: file, path: bookshelf-loans/Sources/LoansCore/Workflows/LoanWorkflow/LoanWorkflow.swift}
match: not_contains
weight: 0.5
---
Date\.now|Date\(\)|UUID\(\)|Task\.sleep|\.random\(
