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

    /// Pull an `{ "error": "..." }` message out of an error body, if present.
    private static func errorMessage(from data: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let msg = obj["error"] as? String
        else { return nil }
        return msg
    }
}
