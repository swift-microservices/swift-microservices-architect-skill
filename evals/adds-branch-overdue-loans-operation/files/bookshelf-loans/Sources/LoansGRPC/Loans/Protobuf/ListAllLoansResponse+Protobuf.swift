import LoansCore
import LoansProtos

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension Bookshelf_Loans_V1_ListAllLoansResponse {
    init(_ page: KeyedPage<Loan>) {
        self.init()
        self.loans = page.items.map(Bookshelf_Loans_V1_Loan.init)
        if let nextCursor = page.nextCursor {
            self.nextPageToken = nextCursor.uuidString.lowercased()
        }
    }
}
