import Configuration

extension InMemoryProvider {
    /// The deployment's layout, which environment variables override key by key.
    static var applicationDefaults: Self {
        .init(values: [
            "http.server.host": "0.0.0.0",
            "http.server.port": 8080,
            "grpc.loans.port": 50051,
            "tls.certificatePath": "/run/tls/cert.pem",
            "tls.privateKeyPath": "/run/tls/key.pem",
            "tls.trustRootsPath": "/run/tls/ca.pem",
            "jwt.publicKeyPath": "/run/jwt/public.pem",
        ])
    }
}
