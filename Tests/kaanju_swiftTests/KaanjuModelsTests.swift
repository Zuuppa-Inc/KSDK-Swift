import XCTest
@testable import kaanju_swift

final class KaanjuModelsTests: XCTestCase {
    /// The create response flattens the intent and adds `client_secret`.
    func testDecodeCreateResponse() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "derivation_index": 5,
          "address": "So1anaAddrExample1111111111111111111111111",
          "client_secret": "cs_abc123",
          "mint": null,
          "mint_decimals": null,
          "expected_lamports": 10000000,
          "status": "pending",
          "received_lamports": 0,
          "reference": "order-42"
        }
        """.data(using: .utf8)!

        let intent = try JSONDecoder().decode(KaanjuIntent.self, from: json)
        XCTAssertEqual(intent.clientSecret, "cs_abc123")
        XCTAssertEqual(intent.expectedLamports, 10_000_000)
        XCTAssertTrue(intent.isSOL)
        XCTAssertEqual(intent.decimals, 9)
        XCTAssertEqual(intent.assetLabel, "SOL")
    }

    /// The status response includes action/message and (once swept) settlement.
    func testDecodeStatusSettled() throws {
        let json = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "address": "So1anaAddrExample1111111111111111111111111",
          "mint": null,
          "mint_decimals": null,
          "expected_lamports": 10000000,
          "status": "swept",
          "received_lamports": 10000000,
          "reference": null,
          "action": "swept",
          "message": "Payment received and settled.",
          "settlement": {
            "asset": "SOL",
            "decimals": 9,
            "destination_amount": 9995000,
            "destination_ui": 0.009995,
            "platform_fee_amount": 0,
            "platform_fee_ui": 0.0,
            "signatures": ["sig1"]
          }
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(KaanjuStatus.self, from: json)
        XCTAssertEqual(status.action, "swept")
        XCTAssertTrue(status.tokenRefunds.isEmpty)
        XCTAssertEqual(status.settlement?.destinationAmount, 9_995_000)

        let phase = KaanjuPhase.from(action: status.action, shortfall: status.shortfallLamports)
        XCTAssertEqual(phase, .settled)
        XCTAssertTrue(phase.isTerminal)
    }

    func testUnderpaidPhaseCarriesShortfall() {
        let phase = KaanjuPhase.from(action: "underpaid", shortfall: 500)
        XCTAssertEqual(phase, .underpaid(shortfall: 500))
        XCTAssertFalse(phase.isTerminal)
    }

    func testAmountFormatting() {
        XCTAssertEqual(KaanjuAmount.format(10_000_000, decimals: 9, symbol: "SOL"), "0.01 SOL")
        XCTAssertEqual(KaanjuAmount.format(1_500_000, decimals: 6, symbol: "USDC"), "1.5 USDC")
    }

    /// A USD-priced create response carries `mode`/`price_usd_cents`/`accepted_tokens`
    /// and no locked asset yet, so the buyer must pick a token.
    func testDecodeUsdPricedIntent() throws {
        let json = """
        {
          "id": "44444444-4444-4444-4444-444444444444",
          "address": "So1anaAddrExample1111111111111111111111111",
          "client_secret": "cs_usd",
          "mint": null,
          "mint_decimals": null,
          "expected_lamports": null,
          "status": "pending",
          "received_lamports": 0,
          "reference": "order-usd",
          "mode": "custom",
          "price_usd_cents": 1250,
          "accepted_tokens": [
            { "kind": "sol" },
            { "kind": "spl", "mint": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", "decimals": 6, "symbol": "USDC" }
          ]
        }
        """.data(using: .utf8)!

        let intent = try JSONDecoder().decode(KaanjuIntent.self, from: json)
        XCTAssertEqual(intent.mode, "custom")
        XCTAssertEqual(intent.priceUsdCents, 1250)
        XCTAssertTrue(intent.isUsdPriced)
        XCTAssertNil(intent.expectedLamports)
        XCTAssertTrue(intent.needsTokenSelection)
        XCTAssertEqual(intent.acceptedTokens?.count, 2)
        let usdc = intent.acceptedTokens?.last
        XCTAssertEqual(usdc?.displayLabel, "USDC")
        XCTAssertEqual(usdc?.decimals, 6)
        XCTAssertFalse(usdc?.isSOL ?? true)
        XCTAssertTrue(intent.acceptedTokens?.first?.isSOL ?? false)
    }

    /// A legacy fixed-token intent (no accepted tokens) never enters token-select.
    func testLegacyIntentSkipsTokenSelection() throws {
        let json = """
        {
          "id": "55555555-5555-5555-5555-555555555555",
          "address": "So1anaAddrExample1111111111111111111111111",
          "client_secret": "cs_legacy",
          "mint": null,
          "mint_decimals": null,
          "expected_lamports": 10000000,
          "status": "pending",
          "received_lamports": 0,
          "reference": null
        }
        """.data(using: .utf8)!

        let intent = try JSONDecoder().decode(KaanjuIntent.self, from: json)
        XCTAssertNil(intent.mode)
        XCTAssertFalse(intent.isUsdPriced)
        XCTAssertFalse(intent.needsTokenSelection)
    }

    /// The status response round-trips the new USD fields (decode → encode → decode).
    func testStatusRoundTripsUsdFields() throws {
        let json = """
        {
          "id": "66666666-6666-6666-6666-666666666666",
          "address": "So1anaAddrExample1111111111111111111111111",
          "mint": null,
          "mint_decimals": null,
          "expected_lamports": null,
          "status": "pending",
          "received_lamports": 0,
          "reference": null,
          "action": "waiting",
          "message": "Awaiting payment.",
          "mode": "order",
          "price_usd_cents": 999,
          "accepted_tokens": [ { "kind": "sol" } ]
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(KaanjuStatus.self, from: json)
        XCTAssertEqual(status.mode, "order")
        XCTAssertEqual(status.priceUsdCents, 999)
        XCTAssertTrue(status.needsTokenSelection)

        let reencoded = try JSONEncoder().encode(status)
        let again = try JSONDecoder().decode(KaanjuStatus.self, from: reencoded)
        XCTAssertEqual(again.mode, "order")
        XCTAssertEqual(again.priceUsdCents, 999)
        XCTAssertEqual(again.acceptedTokens?.count, 1)
    }

    /// The quote response maps snake_case keys and per-token lines.
    func testDecodeQuote() throws {
        let json = """
        {
          "price_usd_cents": 1250,
          "expires_in_seconds": 600,
          "quotes": [
            { "mint": null, "symbol": "SOL", "decimals": 9, "expected_lamports": 83333334 },
            { "mint": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", "symbol": "USDC", "decimals": 6, "expected_lamports": 12500000 }
          ]
        }
        """.data(using: .utf8)!

        let quote = try JSONDecoder().decode(KaanjuQuote.self, from: json)
        XCTAssertEqual(quote.priceUsdCents, 1250)
        XCTAssertEqual(quote.expiresInSeconds, 600)
        XCTAssertEqual(quote.quotes.count, 2)
        XCTAssertEqual(quote.quotes.first?.symbol, "SOL")
        XCTAssertEqual(quote.quotes.first?.id, "sol")
        XCTAssertEqual(quote.quotes.last?.expectedLamports, 12_500_000)
        XCTAssertEqual(quote.quotes.last?.mint, "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
    }
}
