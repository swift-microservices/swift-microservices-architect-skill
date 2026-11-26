import LoansProtos

extension Components.Schemas.LoanStatus {
    init(_ status: Bookshelf_Loans_V1_LoanStatus) throws {
        switch status {
        case .active:
            self = .active
        case .overdue:
            self = .overdue
        case .returned:
            self = .returned
        case .unspecified, .UNRECOGNIZED:
            throw UpstreamValueError(field: "status")
        }
    }
}
