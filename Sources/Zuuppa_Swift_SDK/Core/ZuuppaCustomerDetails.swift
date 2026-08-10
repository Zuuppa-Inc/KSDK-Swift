import Foundation

extension String {
    /// Whitespace/newline-trimmed copy. Used throughout the details flow.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Whether a checkout field is collected, and if so whether it's required.
public enum ZuuppaFieldRequirement: String, Sendable, Codable {
    /// Don't show or collect this field.
    case off
    /// Show it, but the buyer may leave it blank.
    case optional
    /// Show it and require a non-empty value before continuing.
    case required

    /// Whether the field is shown at all.
    public var isShown: Bool { self != .off }
    /// Whether the field must be filled in.
    public var isRequired: Bool { self == .required }
}

/// Which buyer details the checkout should gather, each independently toggled
/// off / optional / required. All default to `.off`, so by default the sheet
/// collects nothing and goes straight to payment — opt in to what you need.
///
/// ```swift
/// var cfg = ZuuppaConfig.default
/// cfg.fields.name = .required
/// cfg.fields.email = .required
/// cfg.fields.address = .optional
/// ```
public struct ZuuppaCheckoutFields: Sendable, Equatable {
    /// Buyer's first + last name.
    public var name: ZuuppaFieldRequirement
    /// Buyer's email (validated as an address when required/provided).
    public var email: ZuuppaFieldRequirement
    /// Buyer's postal address (international — country picker + local fields).
    public var address: ZuuppaFieldRequirement

    public init(
        name: ZuuppaFieldRequirement = .off,
        email: ZuuppaFieldRequirement = .off,
        address: ZuuppaFieldRequirement = .off
    ) {
        self.name = name
        self.email = email
        self.address = address
    }

    /// Collect nothing (default): the sheet skips the details step entirely.
    public static let none = ZuuppaCheckoutFields()

    /// True if any field is shown — i.e. the details step should appear.
    public var collectsAnything: Bool {
        name.isShown || email.isShown || address.isShown
    }
}

/// A postal address, kept generic so it works internationally: `country` is an
/// ISO 3166-1 alpha-2 code (e.g. "US", "GB", "JP"); the rest map to the usual
/// local components. All parts optional.
public struct ZuuppaAddress: Codable, Sendable, Equatable {
    /// ISO 3166-1 alpha-2 country code (uppercased).
    public var country: String?
    public var line1: String?
    public var line2: String?
    public var city: String?
    /// State / province / region.
    public var state: String?
    public var postalCode: String?

    public init(
        country: String? = nil,
        line1: String? = nil,
        line2: String? = nil,
        city: String? = nil,
        state: String? = nil,
        postalCode: String? = nil
    ) {
        self.country = country
        self.line1 = line1
        self.line2 = line2
        self.city = city
        self.state = state
        self.postalCode = postalCode
    }

    enum CodingKeys: String, CodingKey {
        case country, line1, line2, city, state
        case postalCode = "postal_code"
    }

    /// True when at least one component is set.
    public var isEmpty: Bool {
        [country, line1, line2, city, state, postalCode].allSatisfy { ($0 ?? "").isEmpty }
    }
}

/// Buyer details collected at checkout. Every field optional; the integrator
/// chooses which to gather via `ZuuppaConfig.fields`.
public struct ZuuppaCustomerDetails: Codable, Sendable, Equatable {
    public var firstName: String?
    public var lastName: String?
    public var email: String?
    public var address: ZuuppaAddress?

    public init(
        firstName: String? = nil,
        lastName: String? = nil,
        email: String? = nil,
        address: ZuuppaAddress? = nil
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.address = address
    }

    enum CodingKeys: String, CodingKey {
        case email, address
        case firstName = "first_name"
        case lastName = "last_name"
    }

    /// True when nothing has been entered.
    public var isEmpty: Bool {
        (firstName ?? "").isEmpty
            && (lastName ?? "").isEmpty
            && (email ?? "").isEmpty
            && (address?.isEmpty ?? true)
    }
}
