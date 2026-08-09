#if canImport(UIKit)
import SwiftUI

/// The pay-in token step, shown before payment for a USD-priced intent whose
/// amount isn't locked yet. Lists the merchant's `acceptedTokens`; tapping one
/// converts the USD price to that token's base units server-side and advances to
/// payment. Per-token preview amounts are shown once the quote loads.
struct KaanjuTokenSelectView: View {
    @Bindable var model: CheckoutModel
    /// Called once a token is selected (amount locked) to advance to pay.
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                if let cents = model.intent.priceUsdCents {
                    Text(KaanjuCheckoutScreen.formatUSD(cents))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                }
                Text("Choose how to pay")
                    .font(.subheadline)
                    .foregroundStyle(KaanjuColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            VStack(spacing: 12) {
                ForEach(model.acceptedTokens) { token in
                    tokenRow(token)
                }
            }

            if model.isSelectingToken {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Computing total…")
                        .font(.footnote)
                        .foregroundStyle(KaanjuColor.textSecondary)
                }
            }

            if let err = model.errorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(KaanjuColor.danger)
                    .multilineTextAlignment(.center)
            }
        }
        // Note: we intentionally don't load/show per-token conversion quotes here —
        // the buyer just picks a token; the amount is locked on the next step.
        .onAppear { model.resolveTokenNames() }
    }

    private func tokenRow(_ token: KaanjuAcceptedToken) -> some View {
        Button {
            model.selectToken(mint: token.mint, onDone: onContinue)
        } label: {
            HStack(spacing: 12) {
                TokenLogo(url: model.meta(for: token)?.iconURL, fallback: model.ticker(for: token))

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName(for: token))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(KaanjuColor.textPrimary)
                    Text(model.ticker(for: token))
                        .font(.caption)
                        .foregroundStyle(KaanjuColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KaanjuColor.textTertiary)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 12).fill(KaanjuColor.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(KaanjuColor.border))
        }
        // Plain style so nothing inside the label (the logo image especially) gets
        // tinted with the accent color — a templated logo would render as a solid
        // accent blob.
        .buttonStyle(.plain)
        .disabled(model.isSelectingToken)
    }
}

/// A small round token logo, loaded async from the directory's icon URL. Falls
/// back to a monogram circle (first letter of the ticker) while loading or when
/// there's no logo — so the row layout is stable either way.
struct TokenLogo: View {
    let url: URL?
    let fallback: String

    private let size: CGFloat = 32

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        // `.original` keeps the logo's real colors — otherwise a
                        // button/label context can tint it to the accent color.
                        image
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFill()
                    default:
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(KaanjuColor.border, lineWidth: 0.5))
    }

    private var monogram: some View {
        ZStack {
            KaanjuColor.surface
            Text(fallback.prefix(1).uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(KaanjuColor.textSecondary)
        }
    }
}
#endif
