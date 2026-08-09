#if canImport(UIKit)
import SwiftUI

/// The checkout sheet's reusable color palette — the single place every view
/// pulls its colors from, so the look is consistent and easy to retheme. Values
/// come from the bundled `KaanjuColors.xcassets` color sets (each with a light
/// and dark appearance), mirroring the Kaanju web design tokens (flat, dark,
/// one blue accent). Load via `Bundle.module` since this is a Swift package.
///
/// Reference these instead of raw `.secondary` / `.white` / `Color.accentColor`
/// so re-theming is a one-file change (edit the asset catalog).
public enum KaanjuColor {
    /// The sheet's page background.
    public static let background = named("Background")
    /// Raised surfaces — cards, rows, the QR tile.
    public static let surface = named("Surface")
    /// Hairline borders / strokes around surfaces and inputs.
    public static let border = named("Border")

    /// Primary text (titles, values).
    public static let textPrimary = named("TextPrimary")
    /// Secondary text (labels, captions, subtitles).
    public static let textSecondary = named("TextSecondary")
    /// Tertiary text (de-emphasized glyphs like chevrons).
    public static let textTertiary = named("TextTertiary")

    /// The brand accent — primary buttons, selected states.
    public static let accent = named("Accent")
    /// Text/!glyphs drawn on top of the accent (e.g. button labels).
    public static let accentText = named("AccentText")

    /// Positive / settled state.
    public static let success = named("Success")
    /// Caution state (refunds in progress, warnings).
    public static let warning = named("Warning")
    /// Error / destructive state.
    public static let danger = named("Danger")

    /// Load a named color from the package's asset catalog. If it's somehow
    /// missing (shouldn't happen), fall back to a sensible system color rather
    /// than crashing.
    private static func named(_ name: String) -> Color {
        Color(name, bundle: .module)
    }
}
#endif
