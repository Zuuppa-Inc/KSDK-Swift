import Foundation

/// Errors surfaced by the SDK's networking.
public enum KaanjuError: Error, LocalizedError, Sendable {
    /// The intent has no `client_secret`, so its status can't be polled. Make
    /// sure your server forwards the `client_secret` from `POST /intents`.
    case missingClientSecret
    /// The server returned a non-2xx status with an optional message.
    case server(status: Int, message: String?)
    /// A transport/decoding failure.
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingClientSecret:
            return "This payment is missing its client_secret, so its status can't be tracked."
        case let .server(status, message):
            return message ?? "Request failed (\(status))."
        case let .transport(m):
            return m
        }
    }
}

/// Thin client for the one public endpoint the SDK needs: read-only status
/// polling by `client_secret`. It never holds or transmits the account secret
/// key — only the per-intent `cs_…` token.
public struct KaanjuAPI: Sendable {
    let baseURL: URL
    let session: URLSession

    public init(config: KaanjuConfig, session: URLSession = .shared) {
        self.baseURL = config.apiBaseURL
        self.session = session
    }

    /// GET /intents/status?client_secret=cs_… — the current status of a single
    /// intent. Public and unauthenticated (the secret scopes it to one intent).
    public func status(clientSecret: String) async throws -> KaanjuStatus {
        guard clientSecret.hasPrefix("cs_") else { throw KaanjuError.missingClientSecret }

        var comps = URLComponents(
            url: baseURL.appendingPathComponent("intents/status"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "client_secret", value: clientSecret)]
        guard let url = comps.url else {
            throw KaanjuError.transport("could not build status URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw KaanjuError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw KaanjuError.transport("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw KaanjuError.server(status: http.statusCode, message: Self.errorMessage(from: data))
        }

        do {
            return try JSONDecoder().decode(KaanjuStatus.self, from: data)
        } catch {
            throw KaanjuError.transport("could not decode status: \(error)")
        }
    }

    /// POST /intents/details — attach buyer details (name / email / address) to
    /// this intent, authorized by its `client_secret`. Only the parts you set are
    /// sent. Returns the updated status. Public and unauthenticated for the same
    /// reason as `status`: the secret scopes the write to this one intent.
    public func submitDetails(
        clientSecret: String,
        details: KaanjuCustomerDetails
    ) async throws -> KaanjuStatus {
        guard clientSecret.hasPrefix("cs_") else { throw KaanjuError.missingClientSecret }

        // Body mirrors the server's SubmitDetailsReq: flat name/email + nested
        // address, plus the client_secret. Encoded via the Codable models so the
        // snake_case keys line up.
        struct Body: Encodable {
            let clientSecret: String
            let firstName: String?
            let lastName: String?
            let email: String?
            let address: KaanjuAddress?
            enum CodingKeys: String, CodingKey {
                case email, address
                case clientSecret = "client_secret"
                case firstName = "first_name"
                case lastName = "last_name"
            }
        }
        let body = Body(
            clientSecret: clientSecret,
            firstName: details.firstName,
            lastName: details.lastName,
            email: details.email,
            address: (details.address?.isEmpty ?? true) ? nil : details.address
        )

        var req = URLRequest(url: baseURL.appendingPathComponent("intents/details"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            req.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw KaanjuError.transport("could not encode details: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw KaanjuError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw KaanjuError.transport("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw KaanjuError.server(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        do {
            return try JSONDecoder().decode(KaanjuStatus.self, from: data)
        } catch {
            throw KaanjuError.transport("could not decode status: \(error)")
        }
    }

    /// POST /intents/select-token — the buyer picks a pay-in token for a
    /// USD-priced intent, which converts the USD price to that token's base units
    /// at spot and LOCKS the amount. Pass `mint = nil` for native SOL (sent as an
    /// explicit JSON `null`). Authorized by the `client_secret` (same trust model
    /// as `status`/`submitDetails` — the buyer only chooses among the merchant's
    /// tokens, never sets the amount). Returns the updated status.
    public func selectToken(
        clientSecret: String,
        mint: String?
    ) async throws -> KaanjuStatus {
        guard clientSecret.hasPrefix("cs_") else { throw KaanjuError.missingClientSecret }

        // `mint` is encoded as an explicit null for SOL (not omitted), so the
        // server matches it against the accepted SOL entry.
        struct Body: Encodable {
            let clientSecret: String
            let mint: String?
            enum CodingKeys: String, CodingKey {
                case mint
                case clientSecret = "client_secret"
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(clientSecret, forKey: .clientSecret)
                // Encode null explicitly for SOL rather than omitting the key.
                try c.encode(mint, forKey: .mint)
            }
        }
        let body = Body(clientSecret: clientSecret, mint: mint)

        var req = URLRequest(url: baseURL.appendingPathComponent("intents/select-token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            req.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw KaanjuError.transport("could not encode token selection: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw KaanjuError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw KaanjuError.transport("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw KaanjuError.server(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        do {
            return try JSONDecoder().decode(KaanjuStatus.self, from: data)
        } catch {
            throw KaanjuError.transport("could not decode status: \(error)")
        }
    }

    /// GET /intents/quote?client_secret=cs_… — preview per-token amounts for a
    /// USD-priced intent WITHOUT locking anything, so the SDK can show the buyer
    /// what each accepted token would cost. Public and unauthenticated (the secret
    /// scopes it to one intent).
    public func quote(clientSecret: String) async throws -> KaanjuQuote {
        guard clientSecret.hasPrefix("cs_") else { throw KaanjuError.missingClientSecret }

        var comps = URLComponents(
            url: baseURL.appendingPathComponent("intents/quote"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "client_secret", value: clientSecret)]
        guard let url = comps.url else {
            throw KaanjuError.transport("could not build quote URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw KaanjuError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw KaanjuError.transport("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw KaanjuError.server(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        do {
            return try JSONDecoder().decode(KaanjuQuote.self, from: data)
        } catch {
            throw KaanjuError.transport("could not decode quote: \(error)")
        }
    }

    /// Pull an `{ "error": "..." }` message out of an error body, if present.
    private static func errorMessage(from data: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let msg = obj["error"] as? String
        else { return nil }
        return msg
    }
}
