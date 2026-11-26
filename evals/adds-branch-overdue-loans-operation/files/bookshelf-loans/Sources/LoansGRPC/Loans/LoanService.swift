import Authentication
import BookshelfAuthentication
package import GRPCCore
package import LoansCore
package import LoansProtos
import OperationContext

/// Loans for people, through the gateway, grouped as the contract groups them.
///
/// The bearer interceptor identifies the caller when a token is present, and the settings
/// interceptor binds the tenant; each handler requires what its group needs.
package struct LoanService: Bookshelf_Loans_V1_LoanService.SimpleServiceProtocol {
    private let listLoansUseCase: any ListLoansUseCaseProtocol
    private let listAllLoansUseCase: any ListAllLoansUseCaseProtocol

    package init(
        listLoansUseCase: any ListLoansUseCaseProtocol,
        listAllLoansUseCase: any ListAllLoansUseCaseProtocol
    ) {
        self.listLoansUseCase = listLoansUseCase
        self.listAllLoansUseCase = listAllLoansUseCase
    }

    // MARK: - The caller's own

    package func listLoans(
        request: Bookshelf_Loans_V1_ListLoansRequest,
        context: ServerContext
    ) async throws -> Bookshelf_Loans_V1_ListLoansResponse {
        let subject = try requireUser()
        let input = try ListLoansUseCaseInput(request)

        do {
            let page = try await listLoansUseCase(subject: subject, input: input)
            return Bookshelf_Loans_V1_ListLoansResponse(page)
        } catch {
            switch error {
            case .unknown:
                throw RPCError(code: .internalError, message: "The loans could not be listed.")
            }
        }
    }

    // MARK: - Administrators

    package func listAllLoans(
        request: Bookshelf_Loans_V1_ListAllLoansRequest,
        context: ServerContext
    ) async throws -> Bookshelf_Loans_V1_ListAllLoansResponse {
        let subject = try requireUser()
        let input = try ListAllLoansUseCaseInput(request)

        do {
            let page = try await listAllLoansUseCase(subject: subject, input: input)
            return Bookshelf_Loans_V1_ListAllLoansResponse(page)
        } catch {
            switch error {
            case .forbidden:
                throw RPCError(code: .permissionDenied, message: "Administrator access is required.")
            case .unknown:
                throw RPCError(code: .internalError, message: "The loans could not be listed.")
            }
        }
    }

    // MARK: - Caller

    /// The interceptor identifies a user without requiring one; the caller's own and
    /// administrators' RPCs require one.
    private func requireUser() throws -> UserIdentity {
        guard let user = OperationContext.current.user else {
            throw RPCError(code: .unauthenticated, message: "Authentication is required.")
        }

        return user.identity
    }
}
