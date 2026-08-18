import Foundation

/// A pay-in token the buyer may choose among for a USD-priced intent. Mirrors the
/// server's `accepted_tokens` array element: either native SOL (`kind == "sol"`)
/// or an SPL token (`kind == "spl"`) pinned by mint. Decimals/symbol are captured
/// authoritatively by the server; the SDK only displays them.
public struct ZuuppaAcceptedToken: Codable, Identifiable, Sendable, Equatable {
    /// "sol" or "spl".
    public let kind: String
    /// SPL mint address (nil for SOL).
    public let mint: String?
    /// Base-unit decimals (nil for SOL, which is 9).
    public let decimals: Int?
    /// Display symbol hint (e.g. "USDC"); may be nil.
    public let symbol: String?

    public init(kind: String, mint: String? = nil, decimals: Int? = nil, symbol: String? = nil) {
        self.kind = kind
        self.mint = mint
        self.decimals = decimals
        self.symbol = symbol
    }

    /// Stable id for SwiftUI lists — the mint, or "sol" for native SOL.
    public var id: String { mint ?? "sol" }

    /// True for native SOL.
    public var isSOL: Bool { kind == "sol" || mint == nil }

    /// A human label to show in the picker: the symbol, else SOL / a short mint.
    public var displayLabel: String {
        if isSOL { return "SOL" }
        if let s = symbol, !s.isEmpty { return s }
        guard let m = mint else { return "Token" }
        return m.count > 12 ? "\(m.prefix(4))…\(m.suffix(4))" : m
    }
}

/// One line of an order-mode intent's cart snapshot, as captured at checkout.
/// Present on order intents everywhere the intent is exposed (create response,
/// `/status`, and outbound webhooks); absent for custom intents. Prices are the
/// values charged at checkout, so they're stable even if the catalog changes.
public struct ZuuppaLineItem: Codable, Identifiable, Sendable, Equatable {
    /// Current catalog item id, or nil if the item was deleted after the order.
    public let itemId: String?
    /// Display name charged at checkout.
    public let name: String
    /// Unit price in integer USD cents, as charged at checkout.
    public let unitPriceUsdCents: Int64
    /// Quantity ordered.
    public let quantity: Int

    enum CodingKeys: String, CodingKey {
        case name, quantity
        case itemId = "item_id"
        case unitPriceUsdCents = "unit_price_usd_cents"
    }

    public init(itemId: String? = nil, name: String, unitPriceUsdCents: Int64, quantity: Int) {
        self.itemId = itemId
        self.name = name
        self.unitPriceUsdCents = unitPriceUsdCents
        self.quantity = quantity
    }

    /// Stable id for SwiftUI lists — the catalog id, else the name.
    public var id: String { itemId ?? name }

    /// Line total in USD cents (unit price × quantity).
    public var lineTotalUsdCents: Int64 { unitPriceUsdCents * Int64(quantity) }
}

/// A payment intent, as returned by the Zuuppa API. This is what your server
/// gets back from `POST /intents` and passes down to the app to hand to the SDK.
///
/// The critical field for the SDK is `clientSecret` — the one-time `cs_…` token
/// the server returns at creation, used for read-only status polling. If it's
/// missing the sheet can't poll, so make sure your server forwards it.
///
/// All amounts are in the asset's base units: lamports for SOL, token base
/// units for an SPL `mint`.
public struct ZuuppaIntent: Codable, Identifiable, Sendable, Equatable {
    /// Globally-unique intent id.
    public let id: String
    /// Deposit address the buyer sends funds to (the QR payload).
    public let address: String
    /// One-time client secret (`cs_…`) for status polling. Present only on the
    /// fresh create response; nil on idempotent retrieval.
    public let clientSecret: String?
    /// SPL mint address, or nil for native SOL.
    public let mint: String?
    /// Decimals of `mint` (nil for SOL, which is 9).
    public let mintDecimals: Int?
    /// Expected amount in base units, or nil for an open-ended intent.
    public let expectedLamports: Int64?
    /// Server status string: pending | underpaid | paid | overpaid | sweeping |
    /// swept | refunding | refunded | refund_failed | expired.
    public let status: String
    /// Total received so far, in base units.
    public let receivedLamports: Int64
    /// Your caller reference (order id / memo), if you set one.
    public let reference: String?
    /// Pricing mode: "custom" or "order". Absent on legacy responses (treat as
    /// "custom").
    public let mode: String?
    /// USD price in integer cents for a USD-denominated intent (nil for a
    /// fixed-token amount). When set, the buyer selects a token to lock the amount.
    public let priceUsdCents: Int64?
    /// Pay-in tokens the buyer may choose among (nil once the asset is pinned).
    public let acceptedTokens: [ZuuppaAcceptedToken]?
    /// Cart snapshot for order-mode intents (empty for custom). Same items the
    /// dashboard and outbound webhooks see.
    public let lineItems: [ZuuppaLineItem]
    /// Solana Pay URI for `address`, built by the server: `solana:<address>` with
    /// the amount, the SPL mint and the account name already in it, so a wallet
    /// opens pre-filled. This is the QR payload — prefer it over `address`.
    ///
    /// Nil when the intent can no longer be paid (settled, expired, cancelled), so
    /// there is never a live-looking code for a dead address; and nil before a
    /// USD-priced intent locks a token, since there is no amount to put in it yet.
    /// After `selectToken` the fresh URI arrives on `ZuuppaStatus`, not here.
    public let paymentUri: String?

    enum CodingKeys: String, CodingKey {
        case id, address, mint, reference, status, mode
        case clientSecret = "client_secret"
        case mintDecimals = "mint_decimals"
        case expectedLamports = "expected_lamports"
        case receivedLamports = "received_lamports"
        case priceUsdCents = "price_usd_cents"
        case acceptedTokens = "accepted_tokens"
        case lineItems = "line_items"
        case paymentUri = "payment_uri"
    }

    public init(
        id: String,
        address: String,
        clientSecret: String?,
        mint: String? = nil,
        mintDecimals: Int? = nil,
        expectedLamports: Int64? = nil,
        status: String = "pending",
        receivedLamports: Int64 = 0,
        reference: String? = nil,
        mode: String? = nil,
        priceUsdCents: Int64? = nil,
        acceptedTokens: [ZuuppaAcceptedToken]? = nil,
        lineItems: [ZuuppaLineItem] = [],
        paymentUri: String? = nil
    ) {
        self.id = id
        self.address = address
        self.clientSecret = clientSecret
        self.mint = mint
        self.mintDecimals = mintDecimals
        self.expectedLamports = expectedLamports
        self.status = status
        self.receivedLamports = receivedLamports
        self.reference = reference
        self.mode = mode
        self.priceUsdCents = priceUsdCents
        self.acceptedTokens = acceptedTokens
        self.lineItems = lineItems
        self.paymentUri = paymentUri
    }

    // Custom decode so `line_items` (omitted for custom intents) defaults to []
    // rather than throwing on the missing key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        address = try c.decode(String.self, forKey: .address)
        clientSecret = try c.decodeIfPresent(String.self, forKey: .clientSecret)
        mint = try c.decodeIfPresent(String.self, forKey: .mint)
        mintDecimals = try c.decodeIfPresent(Int.self, forKey: .mintDecimals)
        expectedLamports = try c.decodeIfPresent(Int64.self, forKey: .expectedLamports)
        status = try c.decode(String.self, forKey: .status)
        receivedLamports = try c.decode(Int64.self, forKey: .receivedLamports)
        reference = try c.decodeIfPresent(String.self, forKey: .reference)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        priceUsdCents = try c.decodeIfPresent(Int64.self, forKey: .priceUsdCents)
        acceptedTokens = try c.decodeIfPresent([ZuuppaAcceptedToken].self, forKey: .acceptedTokens)
        lineItems = try c.decodeIfPresent([ZuuppaLineItem].self, forKey: .lineItems) ?? []
        paymentUri = try c.decodeIfPresent(String.self, forKey: .paymentUri)
    }

    // Encoding mirrors the wire shape: omit `line_items` when empty (matches the
    // server's serde skip), so round-trips are stable.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(address, forKey: .address)
        try c.encodeIfPresent(clientSecret, forKey: .clientSecret)
        try c.encodeIfPresent(mint, forKey: .mint)
        try c.encodeIfPresent(mintDecimals, forKey: .mintDecimals)
        try c.encodeIfPresent(expectedLamports, forKey: .expectedLamports)
        try c.encode(status, forKey: .status)
        try c.encode(receivedLamports, forKey: .receivedLamports)
        try c.encodeIfPresent(reference, forKey: .reference)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(priceUsdCents, forKey: .priceUsdCents)
        try c.encodeIfPresent(acceptedTokens, forKey: .acceptedTokens)
        if !lineItems.isEmpty { try c.encode(lineItems, forKey: .lineItems) }
        try c.encodeIfPresent(paymentUri, forKey: .paymentUri)
    }

    /// True for SOL (no SPL mint).
    public var isSOL: Bool { mint == nil }

    /// Decimals for display: 9 for SOL, else the mint's decimals (0 if unknown).
    public var decimals: Int { mint == nil ? 9 : (mintDecimals ?? 0) }

    /// Human asset symbol: "SOL" or the mint address.
    public var assetLabel: String { mint ?? "SOL" }

    /// True when the amount is denominated in USD (buyer picks a token to lock it).
    public var isUsdPriced: Bool { priceUsdCents != nil }

    /// The buyer must choose a pay-in token before paying: the amount isn't locked
    /// yet (no `expectedLamports`) and there are accepted tokens to choose from.
    public var needsTokenSelection: Bool {
        expectedLamports == nil && (acceptedTokens?.isEmpty == false)
    }
}

/// A wrong-token refund entry, surfaced alongside the SOL status when the buyer
/// sent an unexpected token (it's returned automatically on an independent track).
public struct ZuuppaTokenRefund: Codable, Sendable, Equatable {
    public let mint: String
    /// pending | settling | refunded | failed
    public let status: String
}

/// The exact on-chain amounts delivered once the intent settled (swept). Present
/// only after settlement — the source of truth for "what was collected".
public struct ZuuppaSettlement: Codable, Sendable, Equatable {
    /// "SOL" or the SPL mint address.
    public let asset: String
    public let decimals: Int
    /// Base units delivered to the sweep destination (net of platform fee).
    public let destinationAmount: Int64
    /// Decimal-adjusted amount to the destination.
    public let destinationUi: Double
    /// Base units sent to the platform wallet (0 when fees off).
    public let platformFeeAmount: Int64
    public let platformFeeUi: Double
    /// On-chain sweep signatures.
    public let signatures: [String]

    enum CodingKeys: String, CodingKey {
        case asset, decimals, signatures
        case destinationAmount = "destination_amount"
        case destinationUi = "destination_ui"
        case platformFeeAmount = "platform_fee_amount"
        case platformFeeUi = "platform_fee_ui"
    }
}

/// The full status response the SDK polls. Flattens the intent plus a
/// human-readable message, a machine `action`, and (once settled) the
/// settlement breakdown.
public struct ZuuppaStatus: Codable, Sendable, Equatable {
    // Flattened intent fields (same keys as the create response).
    public let id: String
    public let address: String
    public let mint: String?
    public let mintDecimals: Int?
    public let expectedLamports: Int64?
    public let status: String
    public let receivedLamports: Int64
    public let reference: String?

    /// SOL-side action: waiting | paid | underpaid | overpaid | refunding |
    /// refunded | swept | expired | refund_failed.
    public let action: String
    /// Human message safe to show the payer.
    public let message: String
    /// For underpayment: how many more base units are needed.
    public let shortfallLamports: Int64?
    /// Wrong-token refunds for this address (empty when none).
    public let tokenRefunds: [ZuuppaTokenRefund]
    /// Actual settled amounts once swept (nil until then).
    public let settlement: ZuuppaSettlement?
    /// Pricing mode: "custom" or "order" (absent on legacy responses).
    public let mode: String?
    /// USD price in integer cents for a USD-denominated intent (nil for fixed).
    public let priceUsdCents: Int64?
    /// Pay-in tokens the buyer may choose among (nil once the asset is pinned).
    public let acceptedTokens: [ZuuppaAcceptedToken]?
    /// Cart snapshot for order-mode intents (empty for custom). Same items the
    /// dashboard and outbound webhooks see.
    public let lineItems: [ZuuppaLineItem]
    /// Solana Pay URI for `address`, built by the server — see
    /// ``ZuuppaIntent/paymentUri``. This is the one to render: it is rebuilt on every
    /// status read, so after a token selection or a partial payment it carries the
    /// amount actually owed now. Nil once the intent can no longer be paid.
    public let paymentUri: String?

    enum CodingKeys: String, CodingKey {
        case id, address, mint, status, reference, action, message, settlement, mode
        case paymentUri = "payment_uri"
        case mintDecimals = "mint_decimals"
        case expectedLamports = "expected_lamports"
        case receivedLamports = "received_lamports"
        case shortfallLamports = "shortfall_lamports"
        case tokenRefunds = "token_refunds"
        case priceUsdCents = "price_usd_cents"
        case acceptedTokens = "accepted_tokens"
        case lineItems = "line_items"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        address = try c.decode(String.self, forKey: .address)
        mint = try c.decodeIfPresent(String.self, forKey: .mint)
        mintDecimals = try c.decodeIfPresent(Int.self, forKey: .mintDecimals)
        expectedLamports = try c.decodeIfPresent(Int64.self, forKey: .expectedLamports)
        status = try c.decode(String.self, forKey: .status)
        receivedLamports = try c.decode(Int64.self, forKey: .receivedLamports)
        reference = try c.decodeIfPresent(String.self, forKey: .reference)
        action = try c.decode(String.self, forKey: .action)
        message = try c.decode(String.self, forKey: .message)
        shortfallLamports = try c.decodeIfPresent(Int64.self, forKey: .shortfallLamports)
        // `token_refunds` is omitted entirely when empty (serde skip), so default.
        tokenRefunds = try c.decodeIfPresent([ZuuppaTokenRefund].self, forKey: .tokenRefunds) ?? []
        settlement = try c.decodeIfPresent(ZuuppaSettlement.self, forKey: .settlement)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        priceUsdCents = try c.decodeIfPresent(Int64.self, forKey: .priceUsdCents)
        acceptedTokens = try c.decodeIfPresent([ZuuppaAcceptedToken].self, forKey: .acceptedTokens)
        // `line_items` is omitted for custom intents (serde skip), so default.
        lineItems = try c.decodeIfPresent([ZuuppaLineItem].self, forKey: .lineItems) ?? []
        paymentUri = try c.decodeIfPresent(String.self, forKey: .paymentUri)
    }

    // Encoding is only needed for tests/round-trips; not used by the SDK at runtime.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(address, forKey: .address)
        try c.encodeIfPresent(mint, forKey: .mint)
        try c.encodeIfPresent(mintDecimals, forKey: .mintDecimals)
        try c.encodeIfPresent(expectedLamports, forKey: .expectedLamports)
        try c.encode(status, forKey: .status)
        try c.encode(receivedLamports, forKey: .receivedLamports)
        try c.encodeIfPresent(reference, forKey: .reference)
        try c.encode(action, forKey: .action)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(shortfallLamports, forKey: .shortfallLamports)
        if !tokenRefunds.isEmpty { try c.encode(tokenRefunds, forKey: .tokenRefunds) }
        try c.encodeIfPresent(settlement, forKey: .settlement)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(priceUsdCents, forKey: .priceUsdCents)
        try c.encodeIfPresent(acceptedTokens, forKey: .acceptedTokens)
        if !lineItems.isEmpty { try c.encode(lineItems, forKey: .lineItems) }
        try c.encodeIfPresent(paymentUri, forKey: .paymentUri)
    }

    public var isSOL: Bool { mint == nil }
    public var decimals: Int { mint == nil ? 9 : (mintDecimals ?? 0) }
    public var assetLabel: String { mint ?? "SOL" }

    /// True when the amount is denominated in USD (buyer picks a token to lock it).
    public var isUsdPriced: Bool { priceUsdCents != nil }

    /// The buyer must choose a pay-in token before paying (amount not yet locked).
    public var needsTokenSelection: Bool {
        expectedLamports == nil && (acceptedTokens?.isEmpty == false)
    }
}

/// A single per-token amount for a USD-priced intent, as returned by the quote
/// endpoint — what one accepted token would cost right now.
public struct ZuuppaQuoteLine: Codable, Identifiable, Sendable, Equatable {
    /// SPL mint (nil for native SOL).
    public let mint: String?
    /// Display symbol (e.g. "SOL", "USDC").
    public let symbol: String
    /// Base-unit decimals.
    public let decimals: Int
    /// Amount in the token's base units.
    public let expectedLamports: Int64

    enum CodingKeys: String, CodingKey {
        case mint, symbol, decimals
        case expectedLamports = "expected_lamports"
    }

    public init(mint: String?, symbol: String, decimals: Int, expectedLamports: Int64) {
        self.mint = mint
        self.symbol = symbol
        self.decimals = decimals
        self.expectedLamports = expectedLamports
    }

    /// Stable id for SwiftUI lists.
    public var id: String { mint ?? "sol" }
}

/// The quote response: per-token preview amounts for a USD-priced intent, plus
/// the USD price and how long the quote is considered fresh. Purely a preview —
/// selecting a token (not quoting) is what locks the amount.
public struct ZuuppaQuote: Codable, Sendable, Equatable {
    public let priceUsdCents: Int64
    public let expiresInSeconds: Int
    public let quotes: [ZuuppaQuoteLine]

    enum CodingKeys: String, CodingKey {
        case quotes
        case priceUsdCents = "price_usd_cents"
        case expiresInSeconds = "expires_in_seconds"
    }

    public init(priceUsdCents: Int64, expiresInSeconds: Int, quotes: [ZuuppaQuoteLine]) {
        self.priceUsdCents = priceUsdCents
        self.expiresInSeconds = expiresInSeconds
        self.quotes = quotes
    }
}

/// A high-level phase for the checkout UI, derived from the server's `action`.
/// Keeps the view logic simple and stable even as server strings evolve.
public enum ZuuppaPhase: Sendable, Equatable {
    /// Waiting for the buyer to pay (nothing / not enough received yet).
    case awaitingPayment
    /// Underpaid — needs `shortfall` more base units.
    case underpaid(shortfall: Int64?)
    /// Payment detected; funds are being settled.
    case settling
    /// Fully settled (swept). Terminal success.
    case settled
    /// Payment window expired with no (completed) payment. Terminal.
    case expired
    /// Funds are being returned to the buyer (overpay excess / late payment).
    case refunding
    /// Funds were returned. Terminal.
    case refunded
    /// A refund failed and needs support. Terminal-ish.
    case refundFailed
    /// The checkout was cancelled (timed out or dismissed) before completing.
    /// Terminal.
    case cancelled

    /// Whether this phase is terminal (polling can stop).
    public var isTerminal: Bool {
        switch self {
        case .settled, .expired, .refunded, .refundFailed, .cancelled: return true
        default: return false
        }
    }

    /// Map a server `action` string (with optional shortfall) to a phase.
    public static func from(action: String, shortfall: Int64?) -> ZuuppaPhase {
        switch action {
        case "waiting": return .awaitingPayment
        case "underpaid": return .underpaid(shortfall: shortfall)
        case "paid", "overpaid": return .settling
        case "swept": return .settled
        case "expired": return .expired
        case "refunding": return .refunding
        case "refunded": return .refunded
        case "refund_failed": return .refundFailed
        case "cancelled": return .cancelled
        default: return .awaitingPayment
        }
    }
}

/// The outcome handed to `onFinish` when the sheet closes.
public enum ZuuppaCheckoutResult: Sendable, Equatable {
    /// Payment completed and settled. Carries the final settlement if available.
    case settled(ZuuppaSettlement?)
    /// The intent expired before payment completed.
    case expired
    /// Funds were returned to the buyer.
    case refunded
    /// The buyer dismissed the sheet before a terminal state.
    case cancelled
}
