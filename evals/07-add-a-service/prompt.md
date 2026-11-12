---
max_turns: 60
timeout_seconds: 900
allowed_tools: [Skill, Read, Glob, Grep, Write, Edit]
---
Start a Reviews service for our Bookshelf backend. A member rates and reviews a book they've returned, at most one review per book; anyone reads a book's reviews. For now, write the bookshelf-reviews package's Package.swift, ReviewsCore with what writing a review needs, and ReviewsPostgres' migrations; the contract, the gRPC target and the gateway come later. Write each file at its path under bookshelf-reviews/, and finish with a short summary of where each part lives. Don't stop to ask me anything.
