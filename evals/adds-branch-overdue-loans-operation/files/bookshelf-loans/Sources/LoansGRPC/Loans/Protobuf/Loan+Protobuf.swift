import LoansCore
import LoansProtos
import SwiftProtobuf

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension Bookshelf_Loans_V1_Loan {
    init(_ loan: Loan) {
        self.init()
        self.id = loan.id.uuidString.lowercased()
        self.userID = loan.userID.uuidString.lowercased()
        self.bookID = loan.bookID.uuidString.lowercased()
        self.status = Bookshelf_Loans_V1_LoanStatus(loan.status)
        self.dueDate = Google_Protobuf_Timestamp(date: loan.dueDate)
        self.creationDate = Google_Protobuf_Timestamp(date: loan.creationDate)
    }
}
