/// The page sizes every paged list of Loans' contract applies.
enum PageSize {
    /// What a request that asks for size 0 gets.
    static let standard = 20

    /// The most a page holds, whatever size a request asks for.
    static let maximum = 100
}
