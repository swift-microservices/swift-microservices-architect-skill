---
type: regex
target: {source: file, path: bookshelf-reviews/Sources/ReviewsPostgres/Migrations/Reviews/CreateReviewsTable.swift}
flags: i
weight: 0.5
---
UNIQUE\s*(INDEX\s+\w+\s+ON\s+reviews\s*)?\(\s*(user_id,\s*book_id|book_id,\s*user_id)\s*\)
