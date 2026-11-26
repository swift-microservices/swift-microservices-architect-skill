import LoansCore
import LoansProtos

extension Bookshelf_Loans_V1_PageInfo {
    init<Item>(_ page: Page<Item>) {
        self.init()
        self.page = Int32(page.page)
        self.pageSize = Int32(page.pageSize)
        self.totalCount = Int32(page.totalCount)
        self.totalPages = Int32(page.totalPages)
    }
}
