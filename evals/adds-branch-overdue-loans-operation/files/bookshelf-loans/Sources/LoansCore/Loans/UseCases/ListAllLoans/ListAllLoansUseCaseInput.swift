#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

package struct ListAllLoansUseCaseInput: Sendable {
    /// The last loan of the previous page, or `nil` for the first page.
    package let startingAfter: UUID?
    package let pageSize: Int

    package init(startingAfter: UUID?, pageSize: Int) {
        self.startingAfter = startingAfter
        self.pageSize = pageSize
    }
}
