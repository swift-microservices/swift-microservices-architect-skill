/// An upstream answered a value the HTTP contract can't carry, such as an unspecified enum or an unset
/// field the schema requires. It isn't an HTTP error, so `ErrorMiddleware` logs it and answers `500`.
package struct UpstreamValueError: Error, Equatable {
    /// The upstream message's field, as the contract names it.
    package let field: String

    package init(field: String) {
        self.field = field
    }
}
