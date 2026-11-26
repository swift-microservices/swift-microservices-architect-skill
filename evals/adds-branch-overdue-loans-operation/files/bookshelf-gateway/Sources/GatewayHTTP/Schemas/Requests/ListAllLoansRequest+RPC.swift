import Hummingbird
import LoansProtos

extension Bookshelf_Loans_V1_ListAllLoansRequest {
    /// The query's `pageSize` and `pageToken`; the token passes through unchanged, for the service to read.
    init(query: Parameters) throws {
        self.init()

        if let pageSizeValue = query["pageSize"] {
            guard let pageSize = Int32(pageSizeValue) else {
                throw HTTPError(.badRequest, message: "pageSize must be an integer.")
            }

            self.pageSize = pageSize
        }

        if let pageToken = query["pageToken"] {
            self.pageToken = String(pageToken)
        }
    }
}
