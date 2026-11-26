package import BookshelfAuthentication
package import Hummingbird
package import HummingbirdAuth

/// A request whose caller the bearer middleware identifies; `IsAuthenticatedMiddleware` refuses one without.
package struct IdentityRequestContext: ChildRequestContext, AuthRequestContext {
    package var coreContext: CoreRequestContextStorage
    package var identity: UserIdentity?

    /// Carries the parent's storage rather than rebuilding it: path parameters are already
    /// extracted by the time a child context is made.
    package init(context: BasicRequestContext) throws {
        self.coreContext = context.coreContext
        self.identity = nil
    }
}
