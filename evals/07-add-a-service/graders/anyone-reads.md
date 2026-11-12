---
type: regex
target: {source: file, path: bookshelf-reviews/Sources/ReviewsPostgres/Migrations/Reviews/CreateReviewsRLSPolicy.swift}
flags: s
weight: 0.5
---
^(?=.*tenant_isolation)(?=.*everyone_read\s+ON\s+reviews\s+FOR\s+SELECT\s+USING\s*\(true\))
