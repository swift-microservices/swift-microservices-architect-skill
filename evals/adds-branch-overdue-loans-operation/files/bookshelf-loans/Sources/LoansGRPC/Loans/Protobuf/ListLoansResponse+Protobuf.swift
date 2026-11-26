import LoansCore
import LoansProtos

extension Bookshelf_Loans_V1_ListLoansResponse {
    init(_ page: Page<Loan>) {
        self.init()
        self.loans = page.items.map(Bookshelf_Loans_V1_Loan.init)
        self.pageInfo = Bookshelf_Loans_V1_PageInfo(page)
    }
}
