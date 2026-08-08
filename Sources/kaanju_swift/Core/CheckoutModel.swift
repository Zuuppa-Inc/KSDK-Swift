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

    /// Buyer details being collected in the details step (bound by the form).
    /// Empty until the buyer types; submitted to the server on `submitDetails`.
    public var details = KaanjuCustomerDetails()
    /// True while the details step should be shown (before payment). Starts true
    /// when any field is configured; cleared once details are submitted.
    public private(set) var needsDetails: Bool
    /// True while a details submission is in flight.
    public private(set) var isSubmittingDetails = false

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
        // Show the details step first only when the integrator configured fields
        // to collect AND we can actually submit them (we need a client_secret).
        self.needsDetails = config.fields.collectsAnything && intent.clientSecret != nil
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

    // MARK: - Details step

    /// Validate the currently-entered details against the configured
    /// requirements. Returns nil when valid, or a human message describing the
    /// first problem (missing required field / malformed email).
    public func validateDetails() -> String? {
        let f = config.fields
        let d = details

        if f.name.isRequired {
            if (d.firstName ?? "").trimmed.isEmpty { return "Please enter your first name." }
            if (d.lastName ?? "").trimmed.isEmpty { return "Please enter your last name." }
        }
        if f.email.isShown {
            let email = (d.email ?? "").trimmed
            if email.isEmpty {
                if f.email.isRequired { return "Please enter your email." }
            } else if !Self.looksLikeEmail(email) {
                return "Please enter a valid email address."
            }
        }
        if f.address.isRequired {
            let a = d.address ?? KaanjuAddress()
            if (a.country ?? "").trimmed.isEmpty { return "Please select your country." }
            if (a.line1 ?? "").trimmed.isEmpty { return "Please enter your street address." }
            if (a.city ?? "").trimmed.isEmpty { return "Please enter your city." }
            if (a.postalCode ?? "").trimmed.isEmpty { return "Please enter your postal code." }
        }
        return nil
    }

    /// Submit the entered details to the server, then advance past the details
    /// step to payment. On a validation error nothing is sent; on a network
    /// error we surface it and stay on the step. `onDone` is called only on
    /// success (so the UI can move forward).
    public func submitDetails(onDone: @escaping () -> Void) {
        guard !isSubmittingDetails else { return }
        if let problem = validateDetails() {
            errorMessage = problem
            return
        }
        guard let secret = intent.clientSecret else {
            // No secret to authorize the write — skip the step rather than block.
            needsDetails = false
            onDone()
            return
        }
        isSubmittingDetails = true
        errorMessage = nil
        let payload = normalizedDetails()
        Task { [weak self] in
            guard let self else { return }
            do {
                let s = try await self.api.submitDetails(clientSecret: secret, details: payload)
                await MainActor.run {
                    self.apply(s)
                    self.isSubmittingDetails = false
                    self.needsDetails = false
                    onDone()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = (error as? KaanjuError)?.errorDescription
                        ?? error.localizedDescription
                    self.isSubmittingDetails = false
                }
            }
        }
    }

    /// Skip an all-optional details step without submitting.
    public func skipDetails() {
        needsDetails = false
    }

    /// Whether the details step may be skipped (nothing is required).
    public var detailsAreSkippable: Bool {
        let f = config.fields
        return !f.name.isRequired && !f.email.isRequired && !f.address.isRequired
    }

    /// Trim all fields and drop blanks before sending.
    private func normalizedDetails() -> KaanjuCustomerDetails {
        func c(_ s: String?) -> String? {
            let t = (s ?? "").trimmed
            return t.isEmpty ? nil : t
        }
        let f = config.fields
        var out = KaanjuCustomerDetails()
        if f.name.isShown {
            out.firstName = c(details.firstName)
            out.lastName = c(details.lastName)
        }
        if f.email.isShown {
            out.email = c(details.email)
        }
        if f.address.isShown, let a = details.address {
            let addr = KaanjuAddress(
                country: c(a.country)?.uppercased(),
                line1: c(a.line1),
                line2: c(a.line2),
                city: c(a.city),
                state: c(a.state),
                postalCode: c(a.postalCode)
            )
            out.address = addr.isEmpty ? nil : addr
        }
        return out
    }

    private static func looksLikeEmail(_ s: String) -> Bool {
        // Minimal, locale-agnostic sanity check; the server re-validates.
        guard !s.contains(" ") else { return false }
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        return parts[1].contains(".") && !parts[1].hasSuffix(".")
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
