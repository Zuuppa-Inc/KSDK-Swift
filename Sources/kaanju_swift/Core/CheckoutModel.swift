import Foundation
import Observation

/// Observable state machine driving the checkout sheet. It owns the poll loop,
/// exposes the latest status/phase for the UI, and runs the host's wallet
/// callback. UI-facing state is mutated on the main actor.
@MainActor
@Observable
public final class CheckoutModel {
    /// The intent being paid. Its `address` (QR) and asset are stable; its
    /// status is refreshed from polling.
    public let intent: KaanjuIntent
    public let config: KaanjuConfig

    /// Latest polled status (nil until the first successful poll).
    public private(set) var status: KaanjuStatus?
    /// High-level phase for the UI, derived from the latest status.
    public private(set) var phase: KaanjuPhase = .awaitingPayment
    /// Non-fatal error text to surface (polling/wallet), if any.
    public private(set) var errorMessage: String?
    /// True while the host's wallet callback is running.
    public private(set) var isPayingWithWallet = false

    private let api: KaanjuAPI
    private let onPayWithWallet: (@Sendable (KaanjuIntent) async throws -> Void)?
    private var pollTask: Task<Void, Never>?
    private var didFinish = false

    public init(
        intent: KaanjuIntent,
        config: KaanjuConfig = .default,
        session: URLSession = .shared,
        onPayWithWallet: (@Sendable (KaanjuIntent) async throws -> Void)? = nil
    ) {
        self.intent = intent
        self.config = config
        self.api = KaanjuAPI(config: config, session: session)
        self.onPayWithWallet = onPayWithWallet
        // Seed the phase from the intent's initial status so the UI isn't blank
        // before the first poll returns.
        self.phase = KaanjuPhase.from(action: Self.actionFromStatus(intent.status), shortfall: nil)
    }

    /// Whether the "Pay with wallet" button should be shown.
    public var showsWalletButton: Bool {
        config.showPayWithWallet && onPayWithWallet != nil && !phase.isTerminal
    }

    /// The final result for `onFinish`, once terminal.
    public var result: KaanjuCheckoutResult {
        switch phase {
        case .settled: return .settled(status?.settlement)
        case .expired: return .expired
        case .refunded: return .refunded
        default: return .cancelled
        }
    }

    /// Begin polling. Safe to call once when the sheet appears.
    public func start() {
        guard pollTask == nil else { return }
        guard let secret = intent.clientSecret else {
            errorMessage = KaanjuError.missingClientSecret.localizedDescription
            return
        }
        pollTask = Task { [weak self] in
            await self?.pollLoop(clientSecret: secret)
        }
    }

    /// Stop polling (call when the sheet disappears).
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Run the host's wallet callback. The poll loop keeps running, so however
    /// the payment lands (this callback, or the buyer scanning the QR), the UI
    /// advances the same way.
    public func payWithWallet() {
        guard let onPayWithWallet, !isPayingWithWallet else { return }
        isPayingWithWallet = true
        errorMessage = nil
        let intent = self.intent
        Task { [weak self] in
            do {
                try await onPayWithWallet(intent)
            } catch is CancellationError {
                // Buyer backed out of their wallet flow; nothing to surface.
            } catch {
                await MainActor.run { self?.errorMessage = error.localizedDescription }
            }
            await MainActor.run { self?.isPayingWithWallet = false }
        }
    }

    // MARK: - Polling

    private func pollLoop(clientSecret: String) async {
        while !Task.isCancelled {
            do {
                let s = try await api.status(clientSecret: clientSecret)
                apply(s)
                if phase.isTerminal { break }
            } catch is CancellationError {
                break
            } catch {
                // Transient — surface softly, keep polling.
                errorMessage = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: UInt64(config.pollInterval * 1_000_000_000))
        }
    }

    private func apply(_ s: KaanjuStatus) {
        status = s
        errorMessage = nil
        phase = KaanjuPhase.from(action: s.action, shortfall: s.shortfallLamports)
    }

    /// Map a raw intent `status` string to the equivalent `action` string used
    /// by `KaanjuPhase.from` (they diverge only for sweeping → paid).
    private static func actionFromStatus(_ status: String) -> String {
        switch status {
        case "pending": return "waiting"
        case "sweeping": return "paid"
        default: return status
        }
    }
}
