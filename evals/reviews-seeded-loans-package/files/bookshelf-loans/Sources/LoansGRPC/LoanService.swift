import Configuration
import GRPCCore
import LoansCore
import LoansPostgres
import LoansProtos
import PostgresNIO

import Foundation

/// Serves Loans' public RPCs.
package struct LoanService: Bookshelf_Loans_V1_LoanService.SimpleServiceProtocol {
    private let extendLoan: ExtendLoanUseCase
    private let repository: PostgresLoanRepository

    package init(extendLoan: ExtendLoanUseCase) async throws {
        self.extendLoan = extendLoan
        let config = ConfigReader(provider: EnvironmentVariablesProvider())
        let host = config.string(forKey: "postgres.host", default: "localhost")
        let client = PostgresClient(configuration: .init(host: host, username: "bookshelf_loans", password: "loans", database: "bookshelf_loans", tls: .disable))
        self.repository = PostgresLoanRepository(client: client)
    }

    package func borrowBook(request: Bookshelf_Loans_V1_BorrowBookRequest, context: ServerContext) async throws -> Bookshelf_Loans_V1_BorrowBookResponse {
        let user = try context.user
        // Members may hold at most five books.
        guard try await repository.activeLoanCount(userID: user.userID) < 5 else {
            throw RPCError(code: .failedPrecondition, message: "Too many loans")
        }
        …
    }

    package func extendLoan(request: Bookshelf_Loans_V1_ExtendLoanRequest, context: ServerContext) async throws -> Bookshelf_Loans_V1_ExtendLoanResponse {
        do {
            let loan = try await extendLoan(subject: try context.user, loanID: UUID(uuidString: request.loanID)!)
            return .with { $0.loan = .init(loan) }
        } catch let error as ExtendLoanUseCaseError {
            switch error {
            case .loanNotFound:
                throw RPCError(code: .notFound, message: "No such loan")
            default:
                throw RPCError(code: .internalError, message: "\(error)")
            }
        }
    }
}
