import Configuration

extension InMemoryProvider {
    /// The deployment's layout, which environment variables override key by key.
    static var applicationDefaults: Self {
        .init(values: [
            "grpc.server.host": "0.0.0.0",
            "grpc.server.port": 50051,
            "grpc.server.hostname": "loans",
            "tls.certificatePath": "/run/tls/cert.pem",
            "tls.privateKeyPath": "/run/tls/key.pem",
            "tls.trustRootsPath": "/run/tls/ca.pem",
            "jwt.publicKeyPath": "/run/jwt/public.pem",
            "postgres.port": 5432,
            "postgres.db": "bookshelf_loans",
            "postgres.owner.user": "loans_owner",
            "postgres.service.user": "loans_service",
            "postgres.internal.user": "loans_internal",
        ])
    }
}
