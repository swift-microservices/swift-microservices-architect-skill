import GRPCCore
import HTTPTypes

extension HTTPResponse.Status {
    /// The status a client reads for an upstream's gRPC status code.
    init(_ code: RPCError.Code) {
        switch code {
        case .invalidArgument, .failedPrecondition, .outOfRange:
            self = .badRequest
        case .unauthenticated:
            self = .unauthorized
        case .permissionDenied:
            self = .forbidden
        case .notFound:
            self = .notFound
        case .alreadyExists:
            self = .conflict
        case .aborted:
            self = .preconditionFailed
        case .resourceExhausted:
            self = .tooManyRequests
        case .cancelled:
            self = HTTPResponse.Status(code: 499, reasonPhrase: "Client Closed Request")
        case .unimplemented:
            self = .notImplemented
        case .unavailable:
            self = .serviceUnavailable
        case .deadlineExceeded:
            self = .gatewayTimeout
        default:
            self = .internalServerError
        }
    }
}
