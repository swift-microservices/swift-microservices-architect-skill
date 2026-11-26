import GRPCCore
import LoansCore
import LoansProtos

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension ListAllLoansUseCaseInput {
    init(_ request: Bookshelf_Loans_V1_ListAllLoansRequest) throws {
        guard request.pageSize >= 0 else {
            throw RPCError(code: .invalidArgument, message: "page_size must not be negative.")
        }

        // An empty token asks for the first page; any other is the last id of a page this service answered.
        let startingAfter = UUID(uuidString: request.pageToken)
        guard request.pageToken.isEmpty || startingAfter != nil else {
            throw RPCError(code: .invalidArgument, message: "page_token is not a token this service issued.")
        }

        let requestedPageSize = request.pageSize == 0 ? PageSize.standard : Int(request.pageSize)
        let pageSize = min(requestedPageSize, PageSize.maximum)
        self.init(startingAfter: startingAfter, pageSize: pageSize)
    }
}
