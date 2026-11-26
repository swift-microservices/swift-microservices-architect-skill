import LoansProtos

extension Components.Schemas.PageInfo {
    init(_ pageInfo: Bookshelf_Loans_V1_PageInfo) {
        self.init(
            page: pageInfo.page,
            pageSize: pageInfo.pageSize,
            totalCount: pageInfo.totalCount,
            totalPages: pageInfo.totalPages
        )
    }
}
