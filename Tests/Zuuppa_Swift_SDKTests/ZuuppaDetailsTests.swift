import XCTest
@testable import Zuuppa_Swift_SDK

final class ZuuppaDetailsTests: XCTestCase {
    private let intent = ZuuppaIntent(
        id: "11111111-1111-1111-1111-111111111111",
        address: "So1anaAddrExample1111111111111111111111111",
        clientSecret: "cs_abc123",
        expectedLamports: 10_000_000
    )

    /// No fields configured → no details step, straight to payment.
    @MainActor
    func testNoFieldsSkipsDetailsStep() {
        let model = CheckoutModel(intent: intent, config: .default)
        XCTAssertFalse(model.needsDetails)
    }

    /// Any configured field triggers the details step (when a client_secret exists).
    @MainActor
    func testConfiguredFieldsTriggerDetailsStep() {
        var cfg = ZuuppaConfig.default
        cfg.fields.email = .optional
        let model = CheckoutModel(intent: intent, config: cfg)
        XCTAssertTrue(model.needsDetails)
    }

    /// Without a client_secret we can't submit, so the step is skipped even if
    /// fields are configured (rather than blocking the buyer).
    @MainActor
    func testNoClientSecretSkipsDetailsStep() {
        let noSecret = ZuuppaIntent(id: "x", address: "y", clientSecret: nil)
        var cfg = ZuuppaConfig.default
        cfg.fields.name = .required
        let model = CheckoutModel(intent: noSecret, config: cfg)
        XCTAssertFalse(model.needsDetails)
    }

    /// Required fields must be filled; validation reports the first gap.
    @MainActor
    func testValidationRequiresConfiguredFields() {
        var cfg = ZuuppaConfig.default
        cfg.fields = ZuuppaCheckoutFields(name: .required, email: .required, address: .required)
        let model = CheckoutModel(intent: intent, config: cfg)

        XCTAssertNotNil(model.validateDetails()) // empty → invalid

        model.details.firstName = "Ada"
        model.details.lastName = "Lovelace"
        model.details.email = "ada@example.com"
        model.details.address = ZuuppaAddress(
            country: "GB",
            line1: "12 Baker St",
            city: "London",
            postalCode: "NW1"
        )
        XCTAssertNil(model.validateDetails()) // all present → valid
    }

    /// A malformed email is rejected even when the field is only optional.
    @MainActor
    func testInvalidEmailRejected() {
        var cfg = ZuuppaConfig.default
        cfg.fields.email = .optional
        let model = CheckoutModel(intent: intent, config: cfg)

        model.details.email = "not-an-email"
        XCTAssertNotNil(model.validateDetails())

        model.details.email = "ok@example.com"
        XCTAssertNil(model.validateDetails())

        model.details.email = "" // blank is fine when optional
        XCTAssertNil(model.validateDetails())
    }

    /// An all-optional set is skippable; any required field makes it not.
    @MainActor
    func testSkippability() {
        var optionalCfg = ZuuppaConfig.default
        optionalCfg.fields = ZuuppaCheckoutFields(name: .optional, email: .optional)
        XCTAssertTrue(CheckoutModel(intent: intent, config: optionalCfg).detailsAreSkippable)

        var requiredCfg = ZuuppaConfig.default
        requiredCfg.fields.email = .required
        XCTAssertFalse(CheckoutModel(intent: intent, config: requiredCfg).detailsAreSkippable)
    }

    /// Address encodes with the server's snake_case keys (postal_code) and skips
    /// nil components.
    func testAddressEncoding() throws {
        let addr = ZuuppaAddress(country: "JP", line1: "1-1", city: "Tokyo", postalCode: "100-0001")
        let data = try JSONEncoder().encode(addr)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["country"] as? String, "JP")
        XCTAssertEqual(obj["postal_code"] as? String, "100-0001")
        XCTAssertNil(obj["line2"]) // nil components omitted
        XCTAssertNil(obj["state"])
    }

    /// The country list is populated and lookups are case-insensitive.
    func testCountryLookup() {
        XCTAssertFalse(ZuuppaCountries.all.isEmpty)
        XCTAssertEqual(ZuuppaCountries.country(for: "us")?.code, "US")
        XCTAssertNil(ZuuppaCountries.country(for: "ZZ"))
    }

    /// Going back to token selection is only offered when it preceded details,
    /// and re-showing it keeps entered details.
    @MainActor
    func testBackToTokenSelectionOnlyWhenItPreceded() {
        // A fixed-token intent has no token-select step → no back affordance.
        var cfg = ZuuppaConfig.default
        cfg.fields.name = .required
        let noSelection = CheckoutModel(intent: intent, config: cfg)
        XCTAssertFalse(noSelection.canGoBackToTokenSelection)
        noSelection.backToTokenSelection()
        XCTAssertFalse(noSelection.needsTokenSelection) // no-op

        // A USD-priced intent with accepted tokens has token selection first.
        let usdIntent = ZuuppaIntent(
            id: "33333333-3333-3333-3333-333333333333",
            address: "So1anaAddrExample1111111111111111111111111",
            clientSecret: "cs_abc123",
            priceUsdCents: 500,
            acceptedTokens: [ZuuppaAcceptedToken(kind: "native", mint: nil, symbol: "SOL")]
        )
        let model = CheckoutModel(intent: usdIntent, config: cfg)
        XCTAssertTrue(model.needsTokenSelection)
        // Simulate having moved past selection to details.
        model.details.firstName = "Ada"
        XCTAssertTrue(model.canGoBackToTokenSelection)
        model.backToTokenSelection()
        XCTAssertTrue(model.needsTokenSelection) // back on the token step
        XCTAssertEqual(model.details.firstName, "Ada") // details preserved
    }

    /// The pay step offers "back" when a step preceded it (details or token
    /// selection), returning to details first, and never once payment is settled.
    @MainActor
    func testBackFromPayReturnsToPrecedingStep() {
        // Fixed-token intent with no collected fields → nothing precedes pay.
        let bare = CheckoutModel(intent: intent, config: .default)
        XCTAssertFalse(bare.canGoBackFromPay)

        // Details configured → pay can go back to details.
        var cfg = ZuuppaConfig.default
        cfg.fields.email = .required
        let withDetails = CheckoutModel(intent: intent, config: cfg)
        withDetails.skipDetails() // advance past details to pay
        XCTAssertFalse(withDetails.needsDetails)
        XCTAssertTrue(withDetails.canGoBackFromPay)
        withDetails.backFromPay()
        XCTAssertTrue(withDetails.needsDetails) // back on the details step

        // USD-priced intent with no fields: token selection preceded pay, so the
        // back affordance is available (the header pairs it with the pay step).
        let usdIntent = ZuuppaIntent(
            id: "44444444-4444-4444-4444-444444444444",
            address: "So1anaAddrExample1111111111111111111111111",
            clientSecret: "cs_abc123",
            priceUsdCents: 500,
            acceptedTokens: [ZuuppaAcceptedToken(kind: "native", mint: nil, symbol: "SOL")]
        )
        let usd = CheckoutModel(intent: usdIntent, config: .default)
        XCTAssertTrue(usd.needsTokenSelection)
        XCTAssertTrue(usd.canGoBackFromPay) // token selection preceded pay
        usd.backFromPay()
        XCTAssertTrue(usd.needsTokenSelection) // returns to (stays on) token select
    }

    /// Once payment is received (`settling`), the buyer's flow is finished: the
    /// sheet shows confirmation, `onFinish` reports `.settled`, and a dismiss no
    /// longer cancels — the server guarantees the funds reach the seller.
    @MainActor
    func testSettlingFinishesAsSettled() {
        let model = CheckoutModel(intent: intent, config: .default)
        XCTAssertFalse(model.isFinished) // awaiting payment

        // Server reports funds received (paid/overpaid → settling).
        model.applyActionForTesting("paid")
        XCTAssertEqual(model.phase, .settling)
        XCTAssertTrue(model.isFinished)
        XCTAssertEqual(model.result, .settled(nil)) // success, no breakdown yet
    }

    /// An overpaid detection also finishes as settled (same commit point).
    @MainActor
    func testOverpaidFinishesAsSettled() {
        let model = CheckoutModel(intent: intent, config: .default)
        model.applyActionForTesting("overpaid")
        XCTAssertEqual(model.phase, .settling)
        XCTAssertTrue(model.isFinished)
        XCTAssertEqual(model.result, .settled(nil))
    }

    /// Underpaid is not finished — the buyer still owes the shortfall.
    @MainActor
    func testUnderpaidIsNotFinished() {
        let model = CheckoutModel(intent: intent, config: .default)
        model.applyActionForTesting("underpaid", shortfall: 5_000_000)
        XCTAssertFalse(model.isFinished)
    }

    // MARK: - Per-country address format

    /// The format adapts field presence and labels per country.
    func testAddressFormatAdaptsPerCountry() {
        let us = ZuuppaAddressFormat.resolve(for: "US")
        XCTAssertTrue(us.showState)
        XCTAssertTrue(us.stateRequired)
        XCTAssertEqual(us.stateLabel, "State")
        XCTAssertEqual(us.postalLabel, "ZIP code")

        let gb = ZuuppaAddressFormat.resolve(for: "gb") // case-insensitive
        XCTAssertFalse(gb.showState)
        XCTAssertTrue(gb.showPostal)
        XCTAssertEqual(gb.postalLabel, "Postcode")

        let jp = ZuuppaAddressFormat.resolve(for: "JP")
        XCTAssertEqual(jp.stateLabel, "Prefecture")

        let ie = ZuuppaAddressFormat.resolve(for: "IE")
        XCTAssertEqual(ie.postalLabel, "Eircode")

        // Hong Kong has no postal-code system.
        let hk = ZuuppaAddressFormat.resolve(for: "HK")
        XCTAssertFalse(hk.showPostal)

        // Unknown / nil falls back to the default (city + postal, no state).
        let def = ZuuppaAddressFormat.resolve(for: nil)
        XCTAssertFalse(def.showState)
        XCTAssertTrue(def.showPostal)
        XCTAssertEqual(def.cityLabel, "City")
        XCTAssertEqual(def.postalLabel, "Postal code")
    }

    /// Validation follows the country's format: the US requires a state and ZIP;
    /// a no-postal country (HK) is valid without a postal code.
    @MainActor
    func testValidationFollowsCountryFormat() {
        var cfg = ZuuppaConfig.default
        cfg.fields.address = .required
        let model = CheckoutModel(intent: intent, config: cfg)

        // US without a state is invalid...
        model.details.address = ZuuppaAddress(
            country: "US", line1: "1 Infinite Loop", city: "Cupertino", postalCode: "95014"
        )
        XCTAssertNotNil(model.validateDetails())
        // ...valid once the state is filled.
        model.details.address?.state = "CA"
        XCTAssertNil(model.validateDetails())

        // Hong Kong: no postal code needed, no state.
        model.details.address = ZuuppaAddress(
            country: "HK", line1: "8 Finance St", city: "Central"
        )
        XCTAssertNil(model.validateDetails())
    }
}
