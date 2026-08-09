#if DEBUG
import Foundation

/// **DEBUG-ONLY test helper.** Creates a payment intent by calling
/// `POST /intents` directly with your SECRET `sk_` key.
///
/// In production this is your *server's* job — the secret key must NEVER ship in
/// an app. This exists purely so you can exercise the full create → QR → poll →
/// settle flow against a local server from a SwiftUI preview / harness, without
/// standing up a backend. It is compiled out of release builds by `#if DEBUG`.
public struct KaanjuDebugClient {
    let baseURL: URL
    /// Secret API key (`sk_live_…` / `sk_test_…`).
    let apiKey: String
    let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    /// Create an intent. Mirrors the server's `POST /intents` body. Returns the
    /// intent including its one-time `client_secret`, ready to hand to the sheet.
    ///
    /// - `mode`: "custom" (default) or "order".
    /// - `amountUsdCents`: for a USD-priced custom intent (with `acceptedTokens`).
    /// - `acceptedTokens`: pay-in tokens the buyer chooses among (USD/order modes).
    ///   Each is `["kind": "sol"]` or `["kind": "spl", "mint": "…"]`.
    /// - `cart`: order-mode line items, each `["item_id": "…", "quantity": n]`.
    public func createIntent(
        expectedLamports: Int64? = nil,
        mint: String? = nil,
        reference: String? = nil,
        expiresInSecs: Int64? = nil,
        mode: String? = nil,
        amountUsdCents: Int64? = nil,
        acceptedTokens: [[String: Any]]? = nil,
        cart: [[String: Any]]? = nil
    ) async throws -> KaanjuIntent {
        var body: [String: Any] = [:]
        if let mode, !mode.isEmpty { body["mode"] = mode }
        if let expectedLamports { body["expected_lamports"] = expectedLamports }
        if let mint, !mint.isEmpty { body["mint"] = mint }
        if let amountUsdCents { body["amount_usd_cents"] = amountUsdCents }
        if let acceptedTokens { body["accepted_tokens"] = acceptedTokens }
        if let cart { body["cart"] = cart }
        if let reference, !reference.isEmpty { body["reference"] = reference }
        if let expiresInSecs { body["expires_in_secs"] = expiresInSecs }

        var req = URLRequest(url: baseURL.appendingPathComponent("intents"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

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
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw KaanjuError.server(status: http.statusCode, message: msg)
        }
        do {
            return try JSONDecoder().decode(KaanjuIntent.self, from: data)
        } catch {
            throw KaanjuError.transport("could not decode intent: \(error)")
        }
    }
}
#endif
