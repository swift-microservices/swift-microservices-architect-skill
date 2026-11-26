package import BookshelfAuthentication
package import Hummingbird

/// A caller checked to be an administrator: reaching a handler through this context is the proof.
package struct AdministratorRequestContext: ChildRequestContext {
    package var coreContext: CoreRequestContextStorage
    package let identity: UserIdentity

    package init(context: IdentityRequestContext) throws {
        guard let identity = context.identity else {
            throw HTTPError(.unauthorized, message: "Authentication is required.")
        }

        guard identity.role == .admin else {
            throw HTTPError(.forbidden, message: "Administrator access is required.")
        }

        self.coreContext = context.coreContext
        self.identity = identity
    }
}
