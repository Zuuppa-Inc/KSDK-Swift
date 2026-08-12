#if canImport(UIKit)
import SwiftUI
import UIKit

/// The checkout screen itself: QR + address + amount + status, a "Pay with
/// wallet" button that runs the host's callback, and a settled/cancelled
/// confirmation. Drives itself from a `CheckoutModel`.
///
/// Internal — the SDK's single public entry point is the `.zuuppaCheckout(...)`
/// sheet modifier, which wraps this view. Not presented directly by hosts.
struct ZuuppaCheckoutScreen: View {
    @State private var model: CheckoutModel
    private let onFinish: ((ZuuppaCheckoutResult) -> Void)?
    /// Guards `onFinish` to exactly one call. It's fired from `.onDisappear`, which
    /// can run more than once across a view's lifetime; this makes it idempotent.
    /// `@State`'s setter is nonmutating, so the guard works from the escaping
    /// view-lifecycle closures below.
    @State private var didFinish = false
    /// Guards the success auto-dismiss timer to a single schedule, so re-renders of
    /// the terminal view don't stack multiple dismiss tasks.
    @State private var didScheduleAutoDismiss = false

    @Environment(\.dismiss) private var dismiss

    /// Measured height of the laid-out content, used to size the sheet to fit its
    /// content exactly (and re-size as steps change). 0 until the first layout.
    @State private var contentHeight: CGFloat = 0
    /// Transient "copied" toast shown when the buyer taps the amount or address.
    @State private var toast: String?

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
        intent: ZuuppaIntent,
        config: ZuuppaConfig = .default,
        session: URLSession = .shared,
        onPayWithWallet: (@Sendable (ZuuppaIntent) async throws -> Void)? = nil,
        onFinish: ((ZuuppaCheckoutResult) -> Void)? = nil
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
            if showsDetailsStep {
                // The details step manages its own scroll + pinned Continue button.
                // Its vertical padding lives *inside* the view so it's part of the
                // measured height (fields + footer), keeping the detent exact; only
                // the horizontal inset is applied here. Comes after token selection
                // (if any), matching the original order.
                ZuuppaDetailsView(model: model) {}
                    .padding(.horizontal, 24)
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        if model.isFinished {
                            terminalView
                        } else if model.isPayingWithWallet {
                            // A wallet payment is in flight — replace the QR screen
                            // with a processing state so the (slow) wallet +
                            // on-chain confirmation feels responsive. A cancel in
                            // the wallet returns us to the QR screen (walletFlow ->
                            // idle); a detected payment routes to terminalView.
                            processingView
                        } else if model.needsTokenSelection {
                            ZuuppaTokenSelectView(model: model) {}
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
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(ZuuppaColor.textPrimary)
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        // Start small and expand to the exact height needed. Header (~44) +
        // measured content; the detent caps at ~92% of the screen via .large so a
        // very tall step (e.g. the address form) stays scrollable rather than
        // running off-screen.
        .presentationDetents(sheetDetents)
        // No grabber pill — the bare X in the header is the only chrome.
        .presentationDragIndicator(.hidden)
        // Paint the whole sheet surface with the brand background.
        .presentationBackground(ZuuppaColor.background)
        // A "copied" pill floats above the content when the buyer taps to copy.
        .overlay(alignment: .bottom) { toastView }
        .onAppear { model.start() }
        // Dismissal is the single point where the host is notified — the result is
        // delivered *after* the sheet is gone, so `onFinish` consistently means
        // "the sheet closed, here's the outcome" (the host never has to guess when
        // it's safe to tear down). Whether the buyer taps the X, swipes away, or the
        // success screen auto-dismisses:
        //   - finished  → report the terminal result (settled/expired/refunded/…)
        //   - otherwise → the checkout is still resumable, so cancel it (server
        //                  returns partial funds / marks it cancelled) and report
        //                  `.cancelled`.
        // Either way, stop polling.
        .onDisappear {
            if model.isFinished {
                fireFinishOnce(model.result)
            } else {
                model.cancel()
                fireFinishOnce(.cancelled)
            }
            model.stop()
        }
    }

    /// Invoke `onFinish` at most once across the terminal-poll path and the
    /// dismiss-cancel path.
    private func fireFinishOnce(_ result: ZuuppaCheckoutResult) {
        guard !didFinish else { return }
        didFinish = true
        onFinish?(result)
    }

    /// Detents driving the sheet's size: a single detent sized to the header plus
    /// the measured content, so the sheet is exactly as tall as it needs to be and
    /// re-sizes as the buyer moves between steps. Before the first measurement we
    /// fall back to `.medium` so the sheet has a sane initial size.
    /// Whether the details step is the current step: shown after any token
    /// selection (matching the branch order below) and never once terminal or
    /// while a wallet payment is processing.
    private var showsDetailsStep: Bool {
        !model.isFinished && !model.isPayingWithWallet
            && !model.needsTokenSelection && model.needsDetails
    }

    /// Whether the pay view is the current step (not terminal, not processing a
    /// wallet payment, past any token selection and details) — matching the branch
    /// order in `body`. During processing the header shows no back chevron.
    private var showsPayStep: Bool {
        !model.isFinished && !model.isPayingWithWallet
            && !model.needsTokenSelection && !model.needsDetails
    }

    /// Whether the header should show a back chevron, and what it does: the details
    /// step goes back to token selection; the pay step goes back to its preceding
    /// step. nil when there's nowhere to go back to.
    private var backAction: (() -> Void)? {
        if showsDetailsStep, model.canGoBackToTokenSelection {
            return { model.backToTokenSelection() }
        }
        if showsPayStep, model.canGoBackFromPay {
            return { model.backFromPay() }
        }
        return nil
    }

    private var sheetDetents: Set<PresentationDetent> {
        guard contentHeight > 0 else { return [.medium] }
        // headerHeight ≈ X button (32) + top padding (12). All step padding is now
        // inside the measured `contentHeight`, so nothing step-specific is added.
        let headerHeight: CGFloat = 44
        // A single content-sized detent. When the content is taller than the sheet
        // can be, `.height` clamps to the max and the step's own ScrollView takes
        // over — so a long address form scrolls on-screen.
        return [.height(headerHeight + contentHeight)]
    }

    // MARK: - Header

    // A bare X in the top-right, matching Stripe's PaymentSheet nav bar. On the
    // details step it also carries a centered "Your details" title, overlaid so
    // it stays centered regardless of the close button on the right.
    private var header: some View {
        HStack {
            // A back chevron whenever the current step has a preceding step to
            // return to (details → token select; pay → its prior step).
            if let back = backAction {
                Button {
                    back()
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ZuuppaColor.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Back")
            }
            Spacer()
            Button {
                // Just dismiss — `.onDisappear` is the single cancel point and
                // handles the cancel + one-shot finish (same as swipe-to-dismiss).
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ZuuppaColor.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
        }
        .overlay {
            if showsDetailsStep {
                Text("Your details")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ZuuppaColor.textPrimary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Pay view

    // A 1:1 port of the Zuuppa SDK's external-crypto QR screen (`ExternalCryptoView`):
    // SEND label → tappable amount → white QR plate → TO label → tappable address →
    // spinner/status block → "keep open" hint. Only the palette (Zuuppa colors),
    // icons (SF Symbols), and the header differ. Zuuppa's optional wallet button,
    // wrong-token refund notice, and error line are appended below.
    private var payView: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 12)
            payLabel(payIsUnderpaid ? "SEND REMAINING" : "SEND")
            Spacer().frame(height: 10)
            payAmount
            Spacer().frame(height: 20)
            qrPlate
            Spacer().frame(height: 16)
            payLabel("TO")
            Spacer().frame(height: 8)
            addressRow
            Spacer().frame(height: 36)
            payStatusBlock
            Spacer().frame(height: 14)
            Text("Keep this screen open! Your payment is detected automatically, usually within seconds.")
                .font(.system(size: 12.5))
                .foregroundStyle(ZuuppaColor.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(12.5 * 0.4)

            if let refunds = model.status?.tokenRefunds, !refunds.isEmpty {
                Spacer().frame(height: 14)
                Text("An unexpected token was received and is being returned to you.")
                    .font(.footnote)
                    .foregroundStyle(ZuuppaColor.warning)
                    .multilineTextAlignment(.center)
            }

            if model.showsWalletButton {
                Spacer().frame(height: 28)
                Button(action: { model.payWithWallet() }) {
                    HStack {
                        if model.isPayingWithWallet {
                            ProgressView().tint(ZuuppaColor.accentText)
                        }
                        Text(model.config.payWithWalletTitle)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(ZuuppaColor.accent)
                    .foregroundStyle(ZuuppaColor.accentText)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(model.isPayingWithWallet)
            }

            if let err = model.errorMessage {
                Spacer().frame(height: 14)
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(ZuuppaColor.danger)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pay view pieces (ported from ExternalCryptoView)

    /// A small, tracked, bold caption ("SEND" / "TO").
    private func payLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(ZuuppaColor.textSecondary)
    }

    /// The hero amount: big number + asset symbol, tap-to-copy. Falls back to a
    /// plain "Any amount" label when the intent has no fixed/locked amount.
    @ViewBuilder
    private var payAmount: some View {
        if hasFixedPayAmount {
            Button { copyToClipboard(payAmountNumber, label: "Amount") } label: {
                VStack(spacing: 6) {
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text(payAmountNumber)
                            .font(.system(size: 44, weight: .heavy))
                            .tracking(-1)
                            .foregroundStyle(ZuuppaColor.textPrimary)
                        Text(model.payAssetLabel)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(ZuuppaColor.textSecondary)
                            .padding(.bottom, 6)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)

                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13))
                            .foregroundStyle(ZuuppaColor.accent)
                        Text("Tap to copy")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(ZuuppaColor.accent)
                    }
                }
            }
            .buttonStyle(.plain)
        } else {
            Text("Any amount")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(ZuuppaColor.textSecondary)
        }
    }

    /// The QR code on a white plate (white in both appearances so it always scans).
    private var qrPlate: some View {
        QRView(string: model.intent.address, size: 240)
            .padding(18)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 24))
    }

    /// The truncated deposit address, tap-to-copy.
    private var addressRow: some View {
        Button { copyToClipboard(model.intent.address, label: "Address") } label: {
            HStack(spacing: 8) {
                Text(shortAddress)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ZuuppaColor.textPrimary)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 16))
                    .foregroundStyle(ZuuppaColor.accent)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy address")
    }

    /// Spinner (tinted by status) + status title + server message. The pay view
    /// only renders non-terminal phases, so the spinner is always the active
    /// indicator — terminal states route to `terminalView`.
    private var payStatusBlock: some View {
        VStack(spacing: 0) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(payStatusColor)
                .frame(width: 26, height: 26)

            Spacer().frame(height: 10)
            Text(payStatusTitle)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(payStatusColor)
                .multilineTextAlignment(.center)
            // Skip the server message when it just repeats the title (e.g. both
            // say "Waiting for payment") so it isn't shown twice. Compared after
            // trimming trailing punctuation/space, since the server message ends
            // with a period ("Waiting for payment.") but the title doesn't.
            if let message = model.status?.message, !message.isEmpty,
               !Self.sameStatusText(message, payStatusTitle) {
                Spacer().frame(height: 3)
                Text(message)
                    .font(.system(size: 13.5))
                    .foregroundStyle(ZuuppaColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(13.5 * 0.35)
            }
        }
    }

    // MARK: - Pay view derived state

    /// Underpaid with a positive remainder still owed → show "SEND REMAINING".
    private var payIsUnderpaid: Bool {
        if case .underpaid(let shortfall) = model.phase { return (shortfall ?? 0) > 0 }
        return false
    }

    /// Whether there's a concrete amount to show/copy (fixed or locked).
    private var hasFixedPayAmount: Bool {
        if payIsUnderpaid { return true }
        return model.payExpectedLamports != nil
    }

    /// The numeric part of the hero amount (remaining when underpaid, else total).
    private var payAmountNumber: String {
        let base: Int64
        if case .underpaid(let shortfall) = model.phase, let s = shortfall {
            base = s
        } else {
            base = model.payExpectedLamports ?? 0
        }
        return ZuuppaAmount.numberString(base, decimals: model.payDecimals)
    }

    /// The deposit address, truncated the same way Zuuppa's screen does.
    private var shortAddress: String {
        let a = model.intent.address
        guard a.count > 16 else { return a }
        return "\(a.prefix(8))...\(a.suffix(8))"
    }

    /// Status color for the (non-terminal) phases the pay view renders.
    private var payStatusColor: Color {
        switch model.phase {
        case .settling: return ZuuppaColor.success
        case .underpaid: return ZuuppaColor.warning
        case .refunding: return ZuuppaColor.warning
        default: return ZuuppaColor.accent
        }
    }

    /// Status title for the (non-terminal) phases the pay view renders.
    private var payStatusTitle: String {
        switch model.phase {
        case .settling: return "Payment received"
        case .underpaid: return "Partial payment"
        case .refunding: return "Refunding"
        default: return "Waiting for payment"
        }
    }

    /// Format integer USD cents as a "$X.YY" string.
    static func formatUSD(_ cents: Int64) -> String {
        let dollars = Double(cents) / 100.0
        return String(format: "$%.2f", dollars)
    }

    /// Whether two status strings are effectively the same, ignoring case and
    /// trailing punctuation/whitespace ("Waiting for payment." == "Waiting for
    /// payment").
    private static func sameStatusText(_ a: String, _ b: String) -> Bool {
        func normalize(_ s: String) -> String {
            s.trimmingCharacters(in: CharacterSet(charactersIn: " .!,")).lowercased()
        }
        return normalize(a) == normalize(b)
    }

    // MARK: - Copy + toast

    /// Copy a value and show a brief "… copied" pill (mirrors the app's SnackBar).
    private func copyToClipboard(_ value: String, label: String) {
        UIPasteboard.general.string = value
        withAnimation { toast = "\(label) copied" }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ZuuppaColor.accentText)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(ZuuppaColor.accent, in: Capsule())
                .padding(.bottom, 24)
                .transition(.opacity)
        }
    }

    // MARK: - Processing view

    /// Full-screen processing state shown after "Pay with wallet" is tapped, so the
    /// slow wallet + on-chain confirmation feels responsive instead of leaving the
    /// QR screen looking idle. Mirrors the terminal view's centered layout (a large
    /// spinner in place of the checkmark). Two messages: while the wallet callback
    /// runs (`confirming`), and after it returns while the payment is detected
    /// on-chain (`submitted`). The header X still closes the whole sheet.
    private var processingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(ZuuppaColor.accent)
                .padding(.top, 20)

            Text(processingTitle)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text(processingSubtitle)
                .font(.subheadline)
                .foregroundStyle(ZuuppaColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var processingTitle: String {
        switch model.walletFlow {
        case .submitted: return "Confirming your payment"
        default: return "Confirming in your wallet"
        }
    }

    private var processingSubtitle: String {
        switch model.walletFlow {
        // The callback returned; now we're waiting for the network to detect it.
        case .submitted: return "Waiting for the payment to confirm on-chain — this usually takes a few seconds. Keep this screen open."
        // The wallet is open / signing. Keep it vague enough for any wallet.
        default: return "Complete the payment in your wallet to continue."
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
                    .foregroundStyle(ZuuppaColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let s = model.status?.settlement {
                Text("Received \(ZuuppaAmount.format(s.destinationAmount, decimals: s.decimals, symbol: s.asset == "SOL" ? "SOL" : s.asset))")
                    .font(.footnote)
                    .foregroundStyle(ZuuppaColor.textSecondary)
            }

            // Success closes itself: the buyer gets a brief confirmation, then the
            // sheet auto-dismisses (Apple Pay style). The host is notified from
            // `.onDisappear` after we're gone, so it can't pre-empt this screen.
            // Non-success terminal states (expired / refund needs attention / …)
            // stay put behind an explicit Done button so the buyer can read them.
            if !isSuccessTerminal {
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(ZuuppaColor.accent)
                        .foregroundStyle(ZuuppaColor.accentText)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.top, 8)
            }
        }
        .onAppear {
            guard isSuccessTerminal, !didScheduleAutoDismiss else { return }
            didScheduleAutoDismiss = true
            Task {
                try? await Task.sleep(for: successAutoDismissDelay)
                dismiss()
            }
        }
    }

    /// Whether the terminal phase is a success (payment received / swept). Success
    /// auto-dismisses and hides the Done button; everything else waits for the
    /// buyer to close it. Mirrors the success cases in `terminalIcon`/`-Title`.
    private var isSuccessTerminal: Bool {
        model.phase == .settled || model.phase == .settling
    }

    /// How long the success confirmation stays up before auto-dismissing.
    private var successAutoDismissDelay: Duration { .seconds(2) }

    private var terminalIcon: String {
        switch model.phase {
        // `settling` shows the same success as `settled`: funds are received and
        // guaranteed to reach the seller, so the buyer sees payment complete.
        case .settled, .settling: return "checkmark.circle.fill"
        case .refunded: return "arrow.uturn.left.circle.fill"
        case .refundFailed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        default: return "clock.badge.xmark.fill"
        }
    }

    private var terminalColor: Color {
        switch model.phase {
        case .settled, .settling: return ZuuppaColor.success
        case .refunded: return ZuuppaColor.accent
        case .refundFailed: return ZuuppaColor.danger
        case .cancelled: return ZuuppaColor.textTertiary
        default: return ZuuppaColor.textTertiary
        }
    }

    private var terminalTitle: String {
        switch model.phase {
        case .settled, .settling: return "Payment complete"
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
/// Shared with `ZuuppaDetailsView`, which measures its own (fields + footer)
/// natural height so the details step sizes to content like every other step.
struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
