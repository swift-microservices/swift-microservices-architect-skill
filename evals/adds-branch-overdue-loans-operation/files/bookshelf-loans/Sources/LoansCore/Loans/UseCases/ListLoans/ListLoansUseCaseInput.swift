package struct ListLoansUseCaseInput: Sendable {
    package let page: Int
    package let pageSize: Int

    package init(page: Int, pageSize: Int) {
        self.page = page
        self.pageSize = pageSize
    }
}
