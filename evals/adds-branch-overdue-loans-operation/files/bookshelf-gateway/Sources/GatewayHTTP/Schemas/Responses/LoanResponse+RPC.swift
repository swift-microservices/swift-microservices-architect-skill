import Hummingbird
import LoansProtos
import SwiftProtobuf

extension Components.Schemas.LoanResponse: ResponseCodable {
    init(_ loan: Bookshelf_Loans_V1_Loan) throws {
        guard loan.hasDueDate else {
            throw UpstreamValueError(field: "due_date")
        }

        let status = try Components.Schemas.LoanStatus(loan.status)
        self.init(id: loan.id, bookID: loan.bookID, status: status, dueDate: loan.dueDate.date)
    }
}
