package import LoansCore
package import PostgresNIO

extension LoanStatus: PostgresCodable {
    package static var psqlType: PostgresDataType {
        .text
    }

    package static var psqlFormat: PostgresFormat {
        .binary
    }

    package func encode<JSONEncoder: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<JSONEncoder>
    ) {
        rawValue.encode(into: &byteBuffer, context: context)
    }

    package init<JSONDecoder: PostgresJSONDecoder>(
        from buffer: inout ByteBuffer,
        type: PostgresDataType,
        format: PostgresFormat,
        context: PostgresDecodingContext<JSONDecoder>
    ) throws {
        let rawValue = try String(from: &buffer, type: type, format: format, context: context)
        guard let status = LoanStatus(rawValue: rawValue) else {
            throw PostgresDecodingError.Code.failure
        }

        self = status
    }
}
