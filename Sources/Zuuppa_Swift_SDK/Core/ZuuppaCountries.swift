import Foundation

/// A country for the address picker: ISO 3166-1 alpha-2 code + localized name.
public struct ZuuppaCountry: Identifiable, Sendable, Equatable {
    /// ISO 3166-1 alpha-2 code, e.g. "US".
    public let code: String
    /// Display name, localized to the current locale.
    public let name: String
    public var id: String { code }

    /// Flag emoji derived from the ISO code (regional-indicator letters).
    public var flag: String {
        code.unicodeScalars.reduce(into: "") { acc, scalar in
            if let ri = Unicode.Scalar(127397 + scalar.value) { acc.unicodeScalars.append(ri) }
        }
    }
}

/// The full list of countries, sourced from the system's region codes and named
/// in the current locale — so it's always complete and localized without us
/// shipping a hardcoded table. Sorted by localized name.
public enum ZuuppaCountries {
    /// All ISO regions with names, localized and sorted. Computed once.
    public static let all: [ZuuppaCountry] = {
        let locale = Locale.current
        let codes: [String]
        if #available(iOS 16, macOS 13, *) {
            codes = Locale.Region.isoRegions
                .filter { $0.identifier.count == 2 } // country codes only (drop 3-digit UN areas)
                .map { $0.identifier }
        } else {
            codes = Locale.isoRegionCodes
        }
        let seen = Set(codes)
        return seen
            .compactMap { code -> ZuuppaCountry? in
                guard let name = locale.localizedString(forRegionCode: code) else { return nil }
                return ZuuppaCountry(code: code, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    /// Look up a single country by ISO code (case-insensitive).
    public static func country(for code: String?) -> ZuuppaCountry? {
        guard let code, code.count == 2 else { return nil }
        let upper = code.uppercased()
        return all.first { $0.code == upper }
    }

    /// A best-guess default from the current locale's region.
    public static var current: ZuuppaCountry? {
        let code: String?
        if #available(iOS 16, macOS 13, *) {
            code = Locale.current.region?.identifier
        } else {
            code = Locale.current.regionCode
        }
        return country(for: code)
    }
}
