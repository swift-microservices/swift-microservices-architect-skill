package import BookshelfAuthentication

package protocol ListAllLoansUseCaseProtocol: Sendable {
    /// Lists every member's loans for an administrator, a page at a time, newest first.
    func callAsFunction(
        subject: UserIdentity,
        input: ListAllLoansUseCaseInput
    ) async throws(ListAllLoansUseCaseError) -> KeyedPage<Loan>
}
