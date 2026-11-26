/// Where a loan stands: out with the member, past its due date, or back at the library.
package enum LoanStatus: String, Equatable, Sendable {
    case active
    case overdue
    case returned
}
