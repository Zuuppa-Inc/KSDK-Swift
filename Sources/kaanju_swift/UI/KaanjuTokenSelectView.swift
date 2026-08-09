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
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                }
            }

            if let err = model.errorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .onAppear { model.loadQuotes() }
    }

    private func tokenRow(_ token: KaanjuAcceptedToken) -> some View {
        Button {
            model.selectToken(mint: token.mint, onDone: onContinue)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(token.displayLabel)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if token.isSOL {
                        Text("Solana")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("SPL token")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let line = model.quoteLine(for: token) {
                    Text(KaanjuAmount.format(line.expectedLamports, decimals: line.decimals, symbol: line.symbol))
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        }
        .disabled(model.isSelectingToken)
    }
}
#endif
