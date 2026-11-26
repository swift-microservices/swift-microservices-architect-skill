import LoansCore
import LoansProtos

extension Bookshelf_Loans_V1_LoanStatus {
    init(_ status: LoanStatus) {
        switch status {
        case .active:
            self = .active
        case .overdue:
            self = .overdue
        case .returned:
            self = .returned
        }
    }
}
