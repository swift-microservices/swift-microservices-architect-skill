package import BookshelfAuthentication

package protocol ListLoansUseCaseProtocol: Sendable {
    /// Lists the subject's own loans, a page at a time, newest first.
    func callAsFunction(
        subject: UserIdentity,
        input: ListLoansUseCaseInput
    ) async throws(ListLoansUseCaseError) -> Page<Loan>
}
