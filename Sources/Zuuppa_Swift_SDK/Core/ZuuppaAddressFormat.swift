import Foundation

/// A lightweight, per-country description of how the postal-address form should
/// adapt: which fields exist, what to call them, and which are required. Not
/// every country uses a city / state / postal-code system — e.g. the UK has no
/// "state" and calls the code a "Postcode", Ireland uses an "Eircode", India a
/// "PIN code", and places like Hong Kong or the UAE have no postal code at all.
///
/// This is a compact, hand-curated table (not the full 235-country dataset): it
/// captures the common variations — state presence + label, postal presence +
/// label, and the city label — and falls back to a sensible default ("City",
/// no state, "Postal code") for everything else.
struct ZuuppaAddressFormat: Sendable {
    /// Label for the locality field (e.g. "City", "Town / City", "Suburb").
    var cityLabel: String
    /// Whether the buyer enters a state/province/region.
    var showState: Bool
    /// Label for the state field (e.g. "State", "Province", "Prefecture").
    var stateLabel: String
    /// Whether the state, when shown, must be filled in.
    var stateRequired: Bool
    /// Whether this country uses a postal code at all.
    var showPostal: Bool
    /// Label for the postal field (e.g. "ZIP code", "Postcode", "Eircode").
    var postalLabel: String

    /// The generic default: city + postal code, no state. Used for any country
    /// not in the tables below.
    static let `default` = ZuuppaAddressFormat(
        cityLabel: "City",
        showState: false,
        stateLabel: "State",
        stateRequired: false,
        showPostal: true,
        postalLabel: "Postal code"
    )

    /// Resolve the format for an ISO alpha-2 country code (case-insensitive).
    /// nil / unknown ⇒ the default format.
    static func resolve(for country: String?) -> ZuuppaAddressFormat {
        guard let code = country?.trimmed.uppercased(), code.count == 2 else { return .default }

        var fmt = ZuuppaAddressFormat.default

        // City label overrides.
        switch code {
        case "GB": fmt.cityLabel = "Town / City"
        case "AU": fmt.cityLabel = "Suburb"
        case "NZ", "IE": fmt.cityLabel = "Town / City"
        default: break
        }

        // State / province / region: only a handful of countries collect one in
        // an address, each with its own name.
        if let state = Self.stateLabels[code] {
            fmt.showState = true
            fmt.stateLabel = state
            fmt.stateRequired = Self.stateRequiredCountries.contains(code)
        }

        // Postal code: absent entirely in some countries; renamed in others.
        if Self.noPostalCountries.contains(code) {
            fmt.showPostal = false
        } else if let label = Self.postalLabels[code] {
            fmt.postalLabel = label
        }

        return fmt
    }

    // MARK: - Tables

    /// Countries that collect a state/province/region, mapped to its local name.
    private static let stateLabels: [String: String] = [
        "US": "State",
        "CA": "Province",
        "AU": "State",
        "BR": "State",
        "IN": "State",
        "MX": "State",
        "JP": "Prefecture",
        "CN": "Province",
        "ID": "Province",
        "MY": "State",
        "PH": "Province",
        "AR": "Province",
        "IT": "Province",
        "ES": "Province",
    ]

    /// Of the state countries, those that *require* the field.
    private static let stateRequiredCountries: Set<String> = [
        "US", "CA", "AU", "BR", "IN", "MX", "JP", "CN",
    ]

    /// Non-default postal-code labels.
    private static let postalLabels: [String: String] = [
        "US": "ZIP code",
        "GB": "Postcode",
        "AU": "Postcode",
        "NZ": "Postcode",
        "IN": "PIN code",
        "IE": "Eircode",
        "SG": "Postal code",
    ]

    /// Countries with no postal-code system (a representative set of the common
    /// ones); the postal field is hidden entirely for these.
    private static let noPostalCountries: Set<String> = [
        "AE", "AG", "AO", "AW", "BF", "BI", "BJ", "BS", "BW", "BZ",
        "CD", "CF", "CG", "CI", "CK", "CM", "DJ", "DM", "ER", "FJ",
        "GA", "GD", "GH", "GM", "GQ", "GY", "HK", "JM", "KE", "KI",
        "KM", "KN", "KP", "KY", "LC", "ML", "MO", "MR", "MW", "NR",
        "NU", "PA", "QA", "RW", "SB", "SC", "SL", "SO", "SR", "ST",
        "SY", "TG", "TK", "TL", "TO", "TT", "TV", "TZ", "UG", "VU",
        "YE", "ZW",
    ]
}
