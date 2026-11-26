import Hummingbird
import LoansProtos

extension Bookshelf_Loans_V1_ListLoansRequest {
    /// The query's `page` and `pageSize`; one the client leaves out reaches the service as 0, its default.
    init(query: Parameters) throws {
        self.init()

        if let pageValue = query["page"] {
            guard let page = Int32(pageValue) else {
                throw HTTPError(.badRequest, message: "page must be an integer.")
            }

            self.page = page
        }

        if let pageSizeValue = query["pageSize"] {
            guard let pageSize = Int32(pageSizeValue) else {
                throw HTTPError(.badRequest, message: "pageSize must be an integer.")
            }

            self.pageSize = pageSize
        }
    }
}
