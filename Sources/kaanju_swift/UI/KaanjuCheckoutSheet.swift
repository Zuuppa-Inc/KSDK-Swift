#if canImport(UIKit)
import SwiftUI
import UIKit

/// The checkout screen itself: QR + address + amount + status, a "Pay with
/// wallet" button that runs the host's callback, and a settled/expired
/// confirmation. Drives itself from a `CheckoutModel`.
///
/// Present it directly, or use the `.kaanjuCheckout(...)` modifier for a sheet.
public struct KaanjuCheckoutScreen: View {
    @State private var model: CheckoutModel
    private let onFinish: ((KaanjuCheckoutResult) -> Void)?

    @Environment(\.dismiss) private var dismiss

    /// - Parameters:
    ///   - intent: the intent to pay (from your server's `POST /intents`,
    ///     including its `client_secret`).
    ///   - config: presentation + polling config.
    ///   - session: URLSession override (mainly for testing).
    ///   - onPayWithWallet: your wallet logic, run when the buyer taps the
    ///     wallet button. Omit (or set `config.showPayWithWallet = false`) for a
    ///     QR-only sheet.
    ///   - onFinish: called once with the terminal result.
    public init(
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

    public var body: some View {
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
                .padding(24)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        // Fire onFinish exactly once when we reach a terminal phase.
        .onChange(of: model.phase) { _, newPhase in
            if newPhase.isTerminal { onFinish?(model.result) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Payment")
                .font(.headline)
            Spacer()
            Button {
                // Dismissing before terminal is a cancellation.
                if !model.phase.isTerminal { onFinish?(.cancelled) }
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Pay view

    private var payView: some View {
        VStack(spacing: 20) {
            amountView

            QRView(string: model.intent.address, size: 220)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))

            addressView

            StatusBadge(phase: model.phase)

            if let message = model.status?.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            tokenRefundNotice

            if model.showsWalletButton {
                Button(action: { model.payWithWallet() }) {
                    HStack {
                        if model.isPayingWithWallet {
                            ProgressView().tint(.white)
                        }
                        Text(model.config.payWithWalletTitle)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(model.isPayingWithWallet)
            }

            if let err = model.errorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
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
                    .foregroundStyle(.secondary)
            } else {
                Text("Any amount")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Text(payAssetSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var payAssetSubtitle: String {
        (model.lockedMint ?? model.intent.mint) == nil ? "Solana" : "SPL token"
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
                .foregroundStyle(.secondary)
            Button {
                UIPasteboard.general.string = model.intent.address
            } label: {
                HStack(spacing: 6) {
                    Text(truncated(model.intent.address))
                        .font(.system(.footnote, design: .monospaced))
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .foregroundStyle(.primary)
            }
            .accessibilityLabel("Copy address")
        }
    }

    @ViewBuilder
    private var tokenRefundNotice: some View {
        if let refunds = model.status?.tokenRefunds, !refunds.isEmpty {
            Text("An unexpected token was received and is being returned to you.")
                .font(.footnote)
                .foregroundStyle(.orange)
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
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let s = model.status?.settlement {
                Text("Received \(KaanjuAmount.format(s.destinationAmount, decimals: s.decimals, symbol: s.asset == "SOL" ? "SOL" : s.asset))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
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
        default: return "clock.badge.xmark.fill"
        }
    }

    private var terminalColor: Color {
        switch model.phase {
        case .settled: return .green
        case .refunded: return .blue
        case .refundFailed: return .red
        default: return .gray
        }
    }

    private var terminalTitle: String {
        switch model.phase {
        case .settled: return "Payment complete"
        case .refunded: return "Funds returned"
        case .refundFailed: return "Refund needs attention"
        case .expired: return "Payment expired"
        default: return "Done"
        }
    }

    private func truncated(_ s: String, keep: Int = 6) -> String {
        guard s.count > keep * 2 + 1 else { return s }
        return "\(s.prefix(keep))…\(s.suffix(keep))"
    }
}
#endif
