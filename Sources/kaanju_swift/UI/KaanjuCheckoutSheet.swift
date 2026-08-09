#if canImport(UIKit)
import SwiftUI
import UIKit

/// The checkout screen itself: QR + address + amount + status, a "Pay with
/// wallet" button that runs the host's callback, and a settled/cancelled
/// confirmation. Drives itself from a `CheckoutModel`.
///
/// Internal — the SDK's single public entry point is the `.kaanjuCheckout(...)`
/// sheet modifier, which wraps this view. Not presented directly by hosts.
struct KaanjuCheckoutScreen: View {
    @State private var model: CheckoutModel
    private let onFinish: ((KaanjuCheckoutResult) -> Void)?
    /// Guards `onFinish` to exactly one call — a checkout can reach terminal via
    /// polling (`onChange`) OR be cancelled on dismissal (`onDisappear`); without
    /// this both paths could fire. `@State`'s setter is nonmutating, so the guard
    /// works from the escaping view-lifecycle closures below.
    @State private var didFinish = false

    @Environment(\.dismiss) private var dismiss

    /// Measured height of the laid-out content, used to size the sheet to fit its
    /// content exactly (and re-size as steps change). 0 until the first layout.
    @State private var contentHeight: CGFloat = 0

    /// - Parameters:
    ///   - intent: the intent to pay (from your server's `POST /intents`,
    ///     including its `client_secret`).
    ///   - config: presentation + polling config.
    ///   - session: URLSession override (mainly for testing).
    ///   - onPayWithWallet: your wallet logic, run when the buyer taps the
    ///     wallet button. Omit (or set `config.showPayWithWallet = false`) for a
    ///     QR-only sheet.
    ///   - onFinish: called once with the terminal result.
    init(
        intent: KaanjuIntent,
        config: KaanjuConfig = .default,
        session: URLSession = .shared,
        onPayWithWallet: (@Sendable (KaanjuIntent) async throws -> Void)? = nil,
        onFinish: ((KaanjuCheckoutResult) -> Void)? = nil
    ) {
        _model = State(
            initialValue: CheckoutModel(
                intent: intent,
                config: config,
                session: session,
                onPayWithWallet: onPayWithWallet
            )
        )
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 24) {
                    if model.phase.isTerminal {
                        terminalView
                    } else if model.needsTokenSelection {
                        KaanjuTokenSelectView(model: model) {}
                    } else if model.needsDetails {
                        KaanjuDetailsView(model: model) {}
                    } else {
                        payView
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                // Measure the content so the sheet can size itself to fit exactly.
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            // The content grows/shrinks between steps (token-select → pay →
            // terminal); don't let the ScrollView bounce when it already fits.
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(KaanjuColor.textPrimary)
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        // Start small and expand to the exact height needed. Header (~44) +
        // measured content; the detent caps at ~92% of the screen via .large so a
        // very tall step (e.g. the address form) stays scrollable rather than
        // running off-screen.
        .presentationDetents(sheetDetents)
        // No grabber pill — the bare X in the header is the only chrome.
        .presentationDragIndicator(.hidden)
        // Paint the whole sheet surface with the brand background.
        .presentationBackground(KaanjuColor.background)
        .onAppear { model.start() }
        // Dismissal is the single cancel point: whether the buyer taps the X or
        // swipes the sheet away, if the checkout is still resumable we cancel it
        // (server returns partial funds / marks it cancelled) and finish once.
        // Once terminal there's nothing to cancel — just stop polling.
        .onDisappear {
            if !model.phase.isTerminal {
                model.cancel()
                fireFinishOnce(.cancelled)
            }
            model.stop()
        }
        // Fire onFinish exactly once when we reach a terminal phase via polling.
        .onChange(of: model.phase) { _, newPhase in
            if newPhase.isTerminal { fireFinishOnce(model.result) }
        }
    }

    /// Invoke `onFinish` at most once across the terminal-poll path and the
    /// dismiss-cancel path.
    private func fireFinishOnce(_ result: KaanjuCheckoutResult) {
        guard !didFinish else { return }
        didFinish = true
        onFinish?(result)
    }

    /// Detents driving the sheet's size: a single detent sized to the header plus
    /// the measured content, so the sheet is exactly as tall as it needs to be and
    /// re-sizes as the buyer moves between steps. Before the first measurement we
    /// fall back to `.medium` so the sheet has a sane initial size.
    private var sheetDetents: Set<PresentationDetent> {
        guard contentHeight > 0 else { return [.medium] }
        // headerHeight ≈ X button (32) + top padding (12).
        let headerHeight: CGFloat = 44
        return [.height(headerHeight + contentHeight)]
    }

    // MARK: - Header

    // A bare X in the top-right, matching Stripe's PaymentSheet nav bar: no title,
    // no filled background — just the glyph, tinted like a secondary control.
    private var header: some View {
        HStack {
            Spacer()
            Button {
                // Just dismiss — `.onDisappear` is the single cancel point and
                // handles the cancel + one-shot finish (same as swipe-to-dismiss).
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(KaanjuColor.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Pay view

    private var payView: some View {
        VStack(spacing: 20) {
            amountView

            // QR codes need a white quiet zone to scan reliably, so this tile
            // stays white in both light and dark — it's not a theming surface.
            QRView(string: model.intent.address, size: 220)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(KaanjuColor.border))

            addressView

            StatusBadge(phase: model.phase)

            if let message = model.status?.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(KaanjuColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            tokenRefundNotice

            if model.showsWalletButton {
                Button(action: { model.payWithWallet() }) {
                    HStack {
                        if model.isPayingWithWallet {
                            ProgressView().tint(KaanjuColor.accentText)
                        }
                        Text(model.config.payWithWalletTitle)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(KaanjuColor.accent)
                    .foregroundStyle(KaanjuColor.accentText)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(model.isPayingWithWallet)
            }

            if let err = model.errorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(KaanjuColor.danger)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var amountView: some View {
        VStack(spacing: 4) {
            if let expected = model.payExpectedLamports {
                // A locked/fixed amount: show it in the pinned asset.
                Text(KaanjuAmount.format(expected, decimals: model.payDecimals, symbol: model.payAssetLabel))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
            } else if let cents = model.intent.priceUsdCents {
                // USD-priced but no token chosen yet (shouldn't normally reach the
                // pay view, but render the USD total defensively).
                Text(Self.formatUSD(cents))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Choose a token to pay")
                    .font(.caption)
                    .foregroundStyle(KaanjuColor.textSecondary)
            } else {
                Text("Any amount")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(KaanjuColor.textSecondary)
            }
            Text(payAssetSubtitle)
                .font(.caption)
                .foregroundStyle(KaanjuColor.textSecondary)
        }
    }

    private var payAssetSubtitle: String {
        if let name = model.payAssetName { return name }
        return (model.lockedMint ?? model.intent.mint) == nil ? "Solana" : "SPL token"
    }

    /// Format integer USD cents as a "$X.YY" string.
    static func formatUSD(_ cents: Int64) -> String {
        let dollars = Double(cents) / 100.0
        return String(format: "$%.2f", dollars)
    }

    private var addressView: some View {
        VStack(spacing: 6) {
            Text("Send to this address")
                .font(.caption)
                .foregroundStyle(KaanjuColor.textSecondary)
            Button {
                UIPasteboard.general.string = model.intent.address
            } label: {
                HStack(spacing: 6) {
                    Text(truncated(model.intent.address))
                        .font(.system(.footnote, design: .monospaced))
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .foregroundStyle(KaanjuColor.textPrimary)
            }
            .accessibilityLabel("Copy address")
        }
    }

    @ViewBuilder
    private var tokenRefundNotice: some View {
        if let refunds = model.status?.tokenRefunds, !refunds.isEmpty {
            Text("An unexpected token was received and is being returned to you.")
                .font(.footnote)
                .foregroundStyle(KaanjuColor.warning)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Terminal view

    private var terminalView: some View {
        VStack(spacing: 20) {
            Image(systemName: terminalIcon)
                .font(.system(size: 56))
                .foregroundStyle(terminalColor)
                .padding(.top, 20)

            Text(terminalTitle)
                .font(.title2.weight(.bold))

            if let message = model.status?.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(KaanjuColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let s = model.status?.settlement {
                Text("Received \(KaanjuAmount.format(s.destinationAmount, decimals: s.decimals, symbol: s.asset == "SOL" ? "SOL" : s.asset))")
                    .font(.footnote)
                    .foregroundStyle(KaanjuColor.textSecondary)
            }

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(KaanjuColor.accent)
                    .foregroundStyle(KaanjuColor.accentText)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 8)
        }
    }

    private var terminalIcon: String {
        switch model.phase {
        case .settled: return "checkmark.circle.fill"
        case .refunded: return "arrow.uturn.left.circle.fill"
        case .refundFailed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        default: return "clock.badge.xmark.fill"
        }
    }

    private var terminalColor: Color {
        switch model.phase {
        case .settled: return KaanjuColor.success
        case .refunded: return KaanjuColor.accent
        case .refundFailed: return KaanjuColor.danger
        case .cancelled: return KaanjuColor.textTertiary
        default: return KaanjuColor.textTertiary
        }
    }

    private var terminalTitle: String {
        switch model.phase {
        case .settled: return "Payment complete"
        case .refunded: return "Funds returned"
        case .refundFailed: return "Refund needs attention"
        case .expired: return "Payment expired"
        case .cancelled: return "Checkout cancelled"
        default: return "Done"
        }
    }

    private func truncated(_ s: String, keep: Int = 6) -> String {
        guard s.count > keep * 2 + 1 else { return s }
        return "\(s.prefix(keep))…\(s.suffix(keep))"
    }
}

/// Carries the measured content height up so the sheet can size itself to fit.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
