---
type: llm
focus: last_message
---
- ReviewsCore holds the review model, its error, the repository protocol, a port for asking Loans whether the member returned the book, and the use case.
- Nothing in Reviews reads Loans' database; it learns about returns only through that port.
- A second review of the same book by the same member is refused by the unique constraint, which the repository's error and the use case's error name, with no check before the insert.
