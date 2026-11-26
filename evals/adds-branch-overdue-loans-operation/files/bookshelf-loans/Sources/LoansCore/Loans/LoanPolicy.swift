#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

/// The lending rules operators tune.
package struct LoanPolicy: Sendable {
    /// The loans a member may hold at once.
    package let maximumActiveLoans: Int

    /// How long a loan runs before it falls due.
    package let loanPeriod: Duration

    package init(maximumActiveLoans: Int, loanPeriod: Duration) {
        self.maximumActiveLoans = maximumActiveLoans
        self.loanPeriod = loanPeriod
    }

    /// The date a loan borrowed at `borrowedAt` falls due.
    package func dueDate(borrowedAt: Date) -> Date {
        let loanSeconds = loanPeriod / .seconds(1)
        return borrowedAt.addingTimeInterval(loanSeconds)
    }
}
