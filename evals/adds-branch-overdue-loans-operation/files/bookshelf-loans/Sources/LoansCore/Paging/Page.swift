/// One page of a list by page number, and where it sits in the whole list.
package struct Page<Item: Sendable>: Sendable {
    package let items: [Item]
    package let page: Int
    package let pageSize: Int
    package let totalCount: Int

    /// The pages the whole list fills.
    package var totalPages: Int {
        guard pageSize > 0 else {
            return 0
        }

        return (totalCount + pageSize - 1) / pageSize
    }

    package init(items: [Item], page: Int, pageSize: Int, totalCount: Int) {
        self.items = items
        self.page = page
        self.pageSize = pageSize
        self.totalCount = totalCount
    }
}
