import GRPCCore
import LoansCore
import LoansProtos

extension ListLoansUseCaseInput {
    init(_ request: Bookshelf_Loans_V1_ListLoansRequest) throws {
        guard request.pageSize >= 0 else {
            throw RPCError(code: .invalidArgument, message: "page_size must not be negative.")
        }

        guard request.page >= 0 else {
            throw RPCError(code: .invalidArgument, message: "page must not be negative.")
        }

        // A size of 0 asks for the default, and a page of 0, left out, for the first page.
        let requestedPageSize = request.pageSize == 0 ? PageSize.standard : Int(request.pageSize)
        let pageSize = min(requestedPageSize, PageSize.maximum)
        let page = max(Int(request.page), 1)
        self.init(page: page, pageSize: pageSize)
    }
}
