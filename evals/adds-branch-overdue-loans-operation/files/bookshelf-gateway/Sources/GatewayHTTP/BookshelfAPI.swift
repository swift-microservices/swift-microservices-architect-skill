package import Authentication
import AuthenticationHummingbird
package import BookshelfAuthentication
package import Hummingbird
import HummingbirdAuth
package import LoansProtos

/// The whole HTTP surface, built from the clients it needs and nothing else.
package struct BookshelfAPI: Sendable {
    private let authenticator: any Authenticator<String, UserIdentity>
    private let loanClient: any Bookshelf_Loans_V1_LoanService.ClientProtocol

    package init(
        authenticator: any Authenticator<String, UserIdentity>,
        loanClient: any Bookshelf_Loans_V1_LoanService.ClientProtocol
    ) {
        self.authenticator = authenticator
        self.loanClient = loanClient
    }

    package func addRoutes(to group: RouterGroup<BasicRequestContext>) {
        let loanController = LoanController(client: loanClient)

        // MARK: - A caller

        let bearerAuthentication = BearerAuthenticationMiddleware<IdentityRequestContext>(authenticator: authenticator)
        let authenticated = group
            .group(context: IdentityRequestContext.self)
            .add(middleware: bearerAuthentication)
            .add(middleware: IsAuthenticatedMiddleware())

        loanController.addAuthenticatedRoutes(to: authenticated.group("loans"))
        loanController.addAdministratorRoutes(to: authenticated.group("admin/loans"))
    }
}
