#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

/// One page of a list read by key, and the id the next page starts after, if another follows.
package struct KeyedPage<Item: Sendable>: Sendable {
    package let items: [Item]
    package let nextCursor: UUID?

    package init(items: [Item], nextCursor: UUID?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}
