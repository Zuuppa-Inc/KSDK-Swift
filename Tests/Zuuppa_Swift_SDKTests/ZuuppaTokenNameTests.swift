import XCTest
@testable import Zuuppa_Swift_SDK

final class ZuuppaTokenNameTests: XCTestCase {
    private let usdUnlocked = ZuuppaIntent(
        id: "33333333-3333-3333-3333-333333333333",
        address: "So1anaAddrExample1111111111111111111111111",
        clientSecret: "cs_abc123",
        expectedLamports: nil,
        status: "pending",
        mode: "custom",
        priceUsdCents: 1250,
        acceptedTokens: [
            ZuuppaAcceptedToken(kind: "sol"),
            ZuuppaAcceptedToken(kind: "spl", mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", decimals: 6, symbol: "USDC"),
            // An SPL token with no symbol hint — should fall back to a short mint.
            ZuuppaAcceptedToken(kind: "spl", mint: "MintWithNoSymbolHint000000000000000000000000", decimals: 6),
        ]
    )

    /// Before any directory lookup resolves, rows fall back to the server's symbol
    /// hint (or a short mint), never a raw full-length mint address.
    @MainActor
    func testDisplayFallbacksWithoutResolution() {
        let model = CheckoutModel(intent: usdUnlocked, config: .default)
        let tokens = model.acceptedTokens

        // SOL.
        XCTAssertEqual(model.displayName(for: tokens[0]), "SOL")
        XCTAssertEqual(model.ticker(for: tokens[0]), "SOL")

        // USDC via the symbol hint.
        XCTAssertEqual(model.displayName(for: tokens[1]), "USDC")
        XCTAssertEqual(model.ticker(for: tokens[1]), "USDC")

        // No symbol hint → short-mint label, generic ticker.
        XCTAssertEqual(model.displayName(for: tokens[2]), "Mint…0000")
        XCTAssertEqual(model.ticker(for: tokens[2]), "SPL token")
    }

    /// A resolved directory hit overrides the fallback with the real name/ticker.
    @MainActor
    func testResolvedMetaOverridesFallback() {
        let model = CheckoutModel(intent: usdUnlocked, config: .default)
        let usdc = model.acceptedTokens[1]

        model.applyTokenMetaForTesting(
            ZuuppaTokenMeta(mint: usdc.mint!, name: "USD Coin", symbol: "USDC"),
            forKey: usdc.id
        )
        XCTAssertEqual(model.displayName(for: usdc), "USD Coin")
        XCTAssertEqual(model.ticker(for: usdc), "USDC")
    }

    /// The directory pins fuzzy search results to the exact mint queried and pulls
    /// out name / symbol / icon.
    func testDirectoryDecodesExactMint() async {
        let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
        let body = """
        [
          {"id":"SomeOtherFuzzyMatch","name":"Wrong","symbol":"NO"},
          {"id":"\(mint)","name":"USD Coin","symbol":"USDC","icon":"https://example.com/usdc.png"}
        ]
        """.data(using: .utf8)!

        let session = StubProtocol.session(returning: body)
        let directory = ZuuppaTokenDirectory(session: session, baseURL: URL(string: "https://stub.local")!)
        let meta = await directory.metadata(forMint: mint)

        XCTAssertEqual(meta?.name, "USD Coin")
        XCTAssertEqual(meta?.symbol, "USDC")
        XCTAssertEqual(meta?.iconURL, URL(string: "https://example.com/usdc.png"))
    }

    /// A malformed / empty directory response resolves to nil (soft failure).
    func testDirectoryFailsSoftOnGarbage() async {
        let session = StubProtocol.session(returning: Data("not json".utf8))
        let directory = ZuuppaTokenDirectory(session: session, baseURL: URL(string: "https://stub.local")!)
        let meta = await directory.metadata(forMint: "AnyMint")
        XCTAssertNil(meta)
    }

    /// An `ipfs://` icon is rewritten to a fast HTTPS gateway.
    func testIPFSSchemeIconRewritten() async {
        let mint = "PumpMint1111111111111111111111111111111111"
        let body = """
        [{"id":"\(mint)","name":"Jelly","symbol":"JELLY","icon":"ipfs://QmABC123/logo.png"}]
        """.data(using: .utf8)!
        let session = StubProtocol.session(returning: body)
        let directory = ZuuppaTokenDirectory(session: session, baseURL: URL(string: "https://stub.local")!)
        let meta = await directory.metadata(forMint: mint)
        XCTAssertEqual(meta?.iconURL, URL(string: "https://dweb.link/ipfs/QmABC123/logo.png"))
    }

    /// A slow public-gateway icon (ipfs.io) has just its host swapped, path intact.
    func testSlowIPFSGatewayRewritten() async {
        let mint = "PumpMint2222222222222222222222222222222222"
        let body = """
        [{"id":"\(mint)","name":"Jelly","symbol":"JELLY","icon":"https://ipfs.io/ipfs/QmWT4jA2/logo.png"}]
        """.data(using: .utf8)!
        let session = StubProtocol.session(returning: body)
        let directory = ZuuppaTokenDirectory(session: session, baseURL: URL(string: "https://stub.local")!)
        let meta = await directory.metadata(forMint: mint)
        XCTAssertEqual(meta?.iconURL, URL(string: "https://dweb.link/ipfs/QmWT4jA2/logo.png"))
    }

    /// A normal HTTPS icon (githubusercontent) is left untouched.
    func testNonIPFSIconUntouched() async {
        let mint = "NormalMint333333333333333333333333333333333"
        let url = "https://raw.githubusercontent.com/x/y/logo.png"
        let body = """
        [{"id":"\(mint)","name":"Coin","symbol":"COIN","icon":"\(url)"}]
        """.data(using: .utf8)!
        let session = StubProtocol.session(returning: body)
        let directory = ZuuppaTokenDirectory(session: session, baseURL: URL(string: "https://stub.local")!)
        let meta = await directory.metadata(forMint: mint)
        XCTAssertEqual(meta?.iconURL, URL(string: url))
    }
}

/// Minimal URLProtocol stub so directory tests don't hit the network.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData = Data()

    static func session(returning data: Data) -> URLSession {
        responseData = data
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
