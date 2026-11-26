import Hummingbird
import LoansProtos

extension Components.Schemas.LoanPageResponse: ResponseCodable {
    init(_ response: Bookshelf_Loans_V1_ListLoansResponse) throws {
        guard response.hasPageInfo else {
            throw UpstreamValueError(field: "page_info")
        }

        let loans = try response.loans.map(Components.Schemas.LoanResponse.init)
        let pageInfo = Components.Schemas.PageInfo(response.pageInfo)
        self.init(loans: loans, pageInfo: pageInfo)
    }
}
