package enum LoanRepositoryError: Error, Equatable {
    case alreadyBorrowed
    case idempotencyConflict
}
