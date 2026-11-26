package import Hummingbird
package import LoansProtos

/// The `/v1/loans` resource: the caller's own loans, and every member's for administrators.
package struct LoanController: Sendable {
    private let client: any Bookshelf_Loans_V1_LoanService.ClientProtocol

    package init(client: any Bookshelf_Loans_V1_LoanService.ClientProtocol) {
        self.client = client
    }

    /// Wired at `loans`.
    package func addAuthenticatedRoutes(to group: RouterGroup<IdentityRequestContext>) {
        group
            .get(use: listLoans)
    }

    /// Wired at `admin/loans`.
    package func addAdministratorRoutes(to group: RouterGroup<IdentityRequestContext>) {
        group
            .group(context: AdministratorRequestContext.self)
            .get(use: listAllLoans)
    }

    private func listLoans(
        request: Request,
        context: IdentityRequestContext
    ) async throws -> Components.Schemas.LoanPageResponse {
        let listLoansRequest = try Bookshelf_Loans_V1_ListLoansRequest(query: request.uri.queryParameters)
        let response = try await client.listLoans(listLoansRequest)
        return try Components.Schemas.LoanPageResponse(response)
    }

    private func listAllLoans(
        request: Request,
        context: AdministratorRequestContext
    ) async throws -> Components.Schemas.LoanKeyedPageResponse {
        let listAllLoansRequest = try Bookshelf_Loans_V1_ListAllLoansRequest(query: request.uri.queryParameters)
        let response = try await client.listAllLoans(listAllLoansRequest)
        return try Components.Schemas.LoanKeyedPageResponse(response)
    }
}
