import Hummingbird
import LoansProtos

extension Components.Schemas.LoanKeyedPageResponse: ResponseCodable {
    init(_ response: Bookshelf_Loans_V1_ListAllLoansResponse) throws {
        let loans = try response.loans.map(Components.Schemas.LoanResponse.init)
        self.init(loans: loans, nextPageToken: response.nextPageToken)
    }
}
