import Foundation

/// Formatting helpers for base-unit amounts (lamports / token base units) in an
/// intent's asset. Kept dependency-free and locale-friendly.
public enum KaanjuAmount {
    /// Decimal-adjusted value of `baseUnits` for a given decimals count.
    public static func ui(_ baseUnits: Int64, decimals: Int) -> Double {
        Double(baseUnits) / pow(10.0, Double(decimals))
    }

    /// Human string like "0.05 SOL" or "1.5 <MINT>". Trims trailing zeros.
    public static func format(_ baseUnits: Int64, decimals: Int, symbol: String) -> String {
        let value = ui(baseUnits, decimals: decimals)
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = max(0, min(decimals, 9))
        nf.usesGroupingSeparator = false
        let num = nf.string(from: NSNumber(value: value)) ?? String(value)
        return "\(num) \(symbol)"
    }

    /// Convenience for an intent: format an amount in the intent's own asset.
    public static func format(_ baseUnits: Int64, for intent: KaanjuIntent) -> String {
        format(baseUnits, decimals: intent.decimals, symbol: intent.assetLabel)
    }
}
