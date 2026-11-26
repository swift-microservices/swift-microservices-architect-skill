package import BookshelfAuthentication
package import Logging

import Foundation

/// Extends a member's loan by one loan period.
package struct ExtendLoanUseCase: Sendable {
    private let loanRepository: any LoanRepository
    private let noticeSender: any NoticeSender
    private let policy: LoanPolicy
    private let logger: Logger

    package init(loanRepository: any LoanRepository, noticeSender: any NoticeSender, policy: LoanPolicy, logger: Logger) {
        self.loanRepository = loanRepository
        self.noticeSender = noticeSender
        self.policy = policy
        self.logger = logger
    }

    package func callAsFunction(subject: UserIdentity, loanID: UUID) async throws -> Loan {
        var extendedLoan: Loan?
        do {
            guard let loan = try? await loanRepository.loan(id: loanID) else {
                throw ExtendLoanUseCaseError.loanNotFound
            }
            guard canExtend(loan) else {
                throw ExtendLoanUseCaseError.extensionLimitReached
            }
            extendedLoan = try await loanRepository.updateDueDate(id: loan.id, dueDate: policy.dueDate(borrowedAt: loan.dueDate))
        } catch {
            logger.error("Extending failed", metadata: ["error": "\(String(reflecting: error))"])
            throw ExtendLoanUseCaseError.unknown
        }

        Task {
            try await noticeSender.sendExtensionNotice(userID: subject.userID, loanID: loanID)
        }

        return extendedLoan!
    }

    private func canExtend(_ loan: Loan) -> Bool {
        loan.extensionCount < policy.maximumExtensions && !loan.isPastDue(at: Date.now)
    }
}
