---
max_turns: 20
timeout_seconds: 300
allowed_tools: [Skill, Read, Glob, Grep]
---
Review this use case from our Swift server's Loans service before I merge it, without stopping to ask me anything. Its repository's `setStatus(_:id:)` runs `UPDATE loans SET status = $1 WHERE id = $2 RETURNING …`.

```swift
import Foundation
import Logging
import Persistence

package struct ReturnBookUseCase: ReturnBookUseCaseProtocol {
    private let database: any Database<any ReturnBookUseCaseScope>
    private let logger: Logger

    package func callAsFunction(_ input: ReturnBookUseCaseInput, subject: UserIdentity) async throws(ReturnBookUseCaseError) -> Loan {
        var returnedLoan: Loan?
        do {
            returnedLoan = try await database.withTransaction { scope in
                guard let loan = try await scope.loanRepository.loan(id: input.loanID), loan.userID == input.userID else {
                    throw ReturnBookUseCaseError.loanNotFound
                }
                guard loan.status != .returned else {
                    throw ReturnBookUseCaseError.alreadyReturned
                }
                return try await scope.loanRepository.setStatus(.returned, id: loan.id)
            }
        } catch let error as ReturnBookUseCaseError {
            throw error
        } catch {
            logger.error("Returning failed: unknown error", metadata: ["error": "\(String(reflecting: error))"])
        }
        try? await notifyBranch(returnedLoan)
        guard let returnedLoan else {
            throw .unknown
        }
        return returnedLoan
    }

    private func notifyBranch(_ loan: Loan?) async throws {
        …
    }
}
```
