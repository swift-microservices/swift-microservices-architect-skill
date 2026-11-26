package import HTTPTypes
package import Hummingbird

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// RFC 9457 problem details. Without a `type`, a problem means what its status means.
package struct Problem: HTTPResponseError {
    package let status: HTTPResponse.Status
    package let detail: String?
    package let headers: HTTPFields

    package init(status: HTTPResponse.Status, detail: String? = nil, headers: HTTPFields = [:]) {
        self.status = status
        self.detail = detail
        self.headers = headers
    }

    package func response(from request: Request, context: some RequestContext) throws -> Response {
        // The request's id is the `hb.request.id` on its log lines, so a reported problem names its trace.
        let instance = "urn:bookshelf:request:\(context.id)"
        let body = Body(title: status.reasonPhrase, status: status.code, detail: detail, instance: instance)
        let encoder = JSONEncoder()
        var response = try encoder.encode(body, from: request, context: context)
        response.status = status
        response.headers[.contentType] = "application/problem+json"
        response.headers.append(contentsOf: headers)
        return response
    }

    private struct Body: Encodable {
        let title: String
        let status: Int
        let detail: String?
        let instance: String
    }
}
