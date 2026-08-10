import Foundation

/// Human metadata for a pay-in asset — its full name, ticker, and logo — resolved
/// from a mint. The server only hands the SDK a mint (and sometimes a symbol hint),
/// so the sheet looks the rest up to show "USD Coin · USDC" instead of a raw
/// `EPjF…Dt1v` address, the way Stripe shows "Visa" rather than a card token.
public struct ZuuppaTokenMeta: Sendable, Equatable {
    /// The mint this describes (the wrapped-SOL mint for native SOL).
    public let mint: String
    /// Full name, e.g. "USD Coin" / "Solana".
    public let name: String
    /// Ticker, e.g. "USDC" / "SOL".
    public let symbol: String
    /// Logo URL, if the directory has one.
    public let iconURL: URL?

    public init(mint: String, name: String, symbol: String, iconURL: URL? = nil) {
        self.mint = mint
        self.name = name
        self.symbol = symbol
        self.iconURL = iconURL
    }
}

/// Resolves token name / ticker / logo from a mint via Jupiter's public,
/// key-less token search (`lite-api.jup.ag/tokens/v2/search`). Purely cosmetic —
/// amounts and decimals always come from the Zuuppa server; this only prettifies
/// the label. Results are cached in-process for the app's lifetime (token
/// metadata is effectively immutable), and every lookup fails soft: on any error
/// the caller falls back to the symbol hint or a truncated mint.
public actor ZuuppaTokenDirectory {
    /// Shared instance so lookups are cached across checkout sheets.
    public static let shared = ZuuppaTokenDirectory()

    /// The canonical wrapped-SOL mint, used to look up native SOL (`mint == nil`).
    public static let wrappedSOLMint = "So11111111111111111111111111111111111111112"

    private let session: URLSession
    private let baseURL: URL
    /// Mint → resolved metadata. `nil` value marks a mint we tried and couldn't
    /// resolve, so we don't hammer the network on every re-render.
    private var cache: [String: ZuuppaTokenMeta?] = [:]
    /// In-flight lookups, so concurrent callers for the same mint share one request.
    private var inFlight: [String: Task<ZuuppaTokenMeta?, Never>] = [:]

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://lite-api.jup.ag")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    /// Resolve metadata for a token. `mint == nil` means native SOL (looked up via
    /// the wrapped-SOL mint). Returns nil if the directory can't resolve it.
    public func metadata(forMint mint: String?) async -> ZuuppaTokenMeta? {
        let key = mint ?? Self.wrappedSOLMint

        if let cached = cache[key] { return cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task<ZuuppaTokenMeta?, Never> { [session, baseURL] in
            await Self.fetch(mint: key, session: session, baseURL: baseURL)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        cache[key] = result
        return result
    }

    /// One key-less GET against the token search endpoint. Best-effort: any
    /// transport/decoding failure resolves to nil.
    private static func fetch(mint: String, session: URLSession, baseURL: URL) async -> ZuuppaTokenMeta? {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("tokens/v2/search"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "query", value: mint)]
        guard let url = comps?.url else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        guard
            let (data, response) = try? await session.data(for: req),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let rows = try? JSONDecoder().decode([JupiterToken].self, from: data)
        else { return nil }

        // The search is a fuzzy match, so pin to the exact mint we asked for.
        guard let hit = rows.first(where: { $0.id == mint }) ?? rows.first else { return nil }
        let name = hit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = hit.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !symbol.isEmpty else { return nil }
        return ZuuppaTokenMeta(
            mint: mint,
            name: name.isEmpty ? symbol : name,
            symbol: symbol.isEmpty ? name : symbol,
            iconURL: hit.icon.flatMap(normalizeIconURL)
        )
    }

    /// A fast IPFS gateway to serve token logos through. Many meme/pump-token
    /// logos are pinned to IPFS and handed to us via `ipfs://…` or a slow public
    /// gateway (notably `ipfs.io`, which frequently times out); routing them
    /// through a fast gateway makes those logos actually load in the sheet.
    /// `dweb.link` is Protocol Labs' own gateway — fast and stable (Cloudflare's
    /// `cloudflare-ipfs.com` was shut down, so don't use it).
    private static let ipfsGatewayHost = "dweb.link"

    /// Public IPFS gateway hosts we rewrite to `ipfsGatewayHost`. The path (which
    /// carries the `/ipfs/<cid>` part) is preserved, so only the slow host swaps.
    private static let slowIPFSHosts: Set<String> = [
        "ipfs.io", "www.ipfs.io", "gateway.ipfs.io", "cloudflare-ipfs.com", "gateway.pinata.cloud",
    ]

    /// Normalize a raw icon string into a loadable HTTPS URL, rewriting IPFS
    /// references to a fast gateway:
    ///   - `ipfs://<cid>[/path]`            → `https://<gateway>/ipfs/<cid>[/path]`
    ///   - `https://ipfs.io/ipfs/<cid>…`    → `https://<gateway>/ipfs/<cid>…`
    /// Anything else (githubusercontent, static.jup.ag, arweave, …) is returned
    /// unchanged. Returns nil if the string isn't a usable URL.
    private static func normalizeIconURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // ipfs://<cid>/<path> → https://<gateway>/ipfs/<cid>/<path>
        if trimmed.lowercased().hasPrefix("ipfs://") {
            let rest = String(trimmed.dropFirst("ipfs://".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rest.isEmpty else { return nil }
            return URL(string: "https://\(ipfsGatewayHost)/ipfs/\(rest)")
        }

        guard var comps = URLComponents(string: trimmed) else { return nil }
        // Rewrite the host of a slow public IPFS gateway, keeping its /ipfs/… path.
        if let host = comps.host?.lowercased(), slowIPFSHosts.contains(host) {
            comps.host = ipfsGatewayHost
            comps.scheme = "https"
        }
        return comps.url
    }

    /// The subset of the Jupiter token-search row we consume.
    private struct JupiterToken: Decodable {
        let id: String
        let name: String
        let symbol: String
        let icon: String?
    }
}
