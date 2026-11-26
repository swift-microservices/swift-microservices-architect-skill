import GRPCCore
package import Hummingbird
import Logging

/// Turns every failure on the router into a `Problem`, which the router renders.
package struct ErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    package init() {}

    package func handle(
        _ request: Request,
        context: Context,
        next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as HTTPError {
            throw Problem(status: error.status, detail: error.body, headers: error.headers)
        } catch let error as any HTTPResponseError {
            throw Problem(status: error.status)
        } catch let error as RPCError {
            let status = HTTPResponse.Status(error.code)
            guard status.kind == .clientError else {
                context.logger.error("Upstream call failed", metadata: ["error": "\(error)"])
                throw Problem(status: status)
            }

            throw Problem(status: status, detail: error.message)
        } catch {
            context.logger.error("Request failed: unknown error", metadata: ["error": "\(error)"])
            throw Problem(status: .internalServerError)
        }
    }
}
