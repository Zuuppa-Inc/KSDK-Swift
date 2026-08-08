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
}
