import XCTest
@testable import kaanju_swift

final class KaanjuDetailsTests: XCTestCase {
    private let intent = KaanjuIntent(
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
        var cfg = KaanjuConfig.default
        cfg.fields.email = .optional
        let model = CheckoutModel(intent: intent, config: cfg)
        XCTAssertTrue(model.needsDetails)
    }

    /// Without a client_secret we can't submit, so the step is skipped even if
    /// fields are configured (rather than blocking the buyer).
    @MainActor
    func testNoClientSecretSkipsDetailsStep() {
        let noSecret = KaanjuIntent(id: "x", address: "y", clientSecret: nil)
        var cfg = KaanjuConfig.default
        cfg.fields.name = .required
        let model = CheckoutModel(intent: noSecret, config: cfg)
        XCTAssertFalse(model.needsDetails)
    }

    /// Required fields must be filled; validation reports the first gap.
    @MainActor
    func testValidationRequiresConfiguredFields() {
        var cfg = KaanjuConfig.default
        cfg.fields = KaanjuCheckoutFields(name: .required, email: .required, address: .required)
        let model = CheckoutModel(intent: intent, config: cfg)

        XCTAssertNotNil(model.validateDetails()) // empty → invalid

        model.details.firstName = "Ada"
        model.details.lastName = "Lovelace"
        model.details.email = "ada@example.com"
        model.details.address = KaanjuAddress(
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
        var cfg = KaanjuConfig.default
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
        var optionalCfg = KaanjuConfig.default
        optionalCfg.fields = KaanjuCheckoutFields(name: .optional, email: .optional)
        XCTAssertTrue(CheckoutModel(intent: intent, config: optionalCfg).detailsAreSkippable)

        var requiredCfg = KaanjuConfig.default
        requiredCfg.fields.email = .required
        XCTAssertFalse(CheckoutModel(intent: intent, config: requiredCfg).detailsAreSkippable)
    }

    /// Address encodes with the server's snake_case keys (postal_code) and skips
    /// nil components.
    func testAddressEncoding() throws {
        let addr = KaanjuAddress(country: "JP", line1: "1-1", city: "Tokyo", postalCode: "100-0001")
        let data = try JSONEncoder().encode(addr)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["country"] as? String, "JP")
        XCTAssertEqual(obj["postal_code"] as? String, "100-0001")
        XCTAssertNil(obj["line2"]) // nil components omitted
        XCTAssertNil(obj["state"])
    }

    /// The country list is populated and lookups are case-insensitive.
    func testCountryLookup() {
        XCTAssertFalse(KaanjuCountries.all.isEmpty)
        XCTAssertEqual(KaanjuCountries.country(for: "us")?.code, "US")
        XCTAssertNil(KaanjuCountries.country(for: "ZZ"))
    }
}
