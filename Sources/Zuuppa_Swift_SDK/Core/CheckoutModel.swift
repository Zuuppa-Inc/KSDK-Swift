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
    public let intent: ZuuppaIntent
    public let config: ZuuppaConfig

    /// Latest polled status (nil until the first successful poll).
    public private(set) var status: ZuuppaStatus?
    /// High-level phase for the UI, derived from the latest status.
    public private(set) var phase: ZuuppaPhase = .awaitingPayment
    /// Non-fatal error text to surface (polling/wallet), if any.
    public private(set) var errorMessage: String?
    /// Where the buyer is in the "Pay with wallet" flow. Drives a full-screen
    /// processing state so the (slow) wallet + on-chain confirmation feels
    /// responsive instead of leaving the QR screen looking idle.
    public private(set) var walletFlow: WalletFlow = .idle

    /// The stages of a "Pay with wallet" tap. `confirming` covers the host's
    /// wallet callback running (Apple Pay / external wallet signing + submitting);
    /// `submitted` covers the gap after it returns while we watch the chain for the
    /// payment to land. Both show the processing screen; a cancel/error returns to
    /// `idle` (back to the QR screen).
    public enum WalletFlow: Sendable, Equatable {
        case idle
        case confirming
        case submitted
    }

    /// Whether a wallet payment is in flight (either stage). The button uses this
    /// to guard against re-taps; the UI uses it to show the processing screen.
    public var isPayingWithWallet: Bool { walletFlow != .idle }

    /// Buyer details being collected in the details step (bound by the form).
    /// Empty until the buyer types; submitted to the server on `submitDetails`.
    public var details = ZuuppaCustomerDetails()
    /// True while the details step should be shown (before payment). Starts true
    /// when any field is configured; cleared once details are submitted.
    public private(set) var needsDetails: Bool
    /// Whether the details step was ever part of this checkout. Stays true after
    /// details are submitted, so the pay step knows it can offer a "back" button.
    private let hadDetailsStep: Bool
    /// True while a details submission is in flight.
    public private(set) var isSubmittingDetails = false

    /// True while the buyer must pick a pay-in token before paying (USD-priced
    /// intent whose amount isn't locked yet). Cleared once a token is selected.
    public private(set) var needsTokenSelection: Bool
    /// Whether token selection was ever a step for this checkout. Stays true after
    /// a token is picked, so the details step knows it can offer a "back" button.
    private let hadTokenSelectionStep: Bool
    /// Per-token preview amounts for the token-select step (nil until loaded).
    public private(set) var quotes: ZuuppaQuote?
    /// True while a token selection (lock) is in flight.
    public private(set) var isSelectingToken = false
    /// The mint the buyer selected (nil = SOL); set once selection succeeds.
    public private(set) var selectedMint: String?
    /// The locked amount after a selection (drives the pay view for USD intents).
    public private(set) var lockedExpectedLamports: Int64?
    /// The locked asset's mint after selection (nil = SOL).
    public private(set) var lockedMint: String?
    /// The locked asset's decimals after selection.
    public private(set) var lockedDecimals: Int?

    /// Resolved human metadata (name / ticker / logo) per mint, keyed by the same
    /// id `ZuuppaAcceptedToken.id` uses ("sol" for native SOL). Filled in the
    /// background from the token directory; the UI reads it to show real names
    /// instead of raw mint addresses. Empty until lookups return.
    public private(set) var tokenMeta: [String: ZuuppaTokenMeta] = [:]

    private let api: ZuuppaAPI
    private let directory: ZuuppaTokenDirectory
    private let onPayWithWallet: (@Sendable (ZuuppaIntent) async throws -> Void)?
    private var pollTask: Task<Void, Never>?
    private var didFinish = false
    private var didCancel = false

    public init(
        intent: ZuuppaIntent,
        config: ZuuppaConfig = .default,
        session: URLSession = .shared,
        directory: ZuuppaTokenDirectory = .shared,
        onPayWithWallet: (@Sendable (ZuuppaIntent) async throws -> Void)? = nil
    ) {
        self.intent = intent
        self.config = config
        self.api = ZuuppaAPI(config: config, session: session)
        self.directory = directory
        self.onPayWithWallet = onPayWithWallet
        // Show the details step first only when the integrator configured fields
        // to collect AND we can actually submit them (we need a client_secret).
        let details = config.fields.collectsAnything && intent.clientSecret != nil
        self.needsDetails = details
        self.hadDetailsStep = details
        // Show the token-select step for a USD-priced intent whose amount isn't
        // locked yet (and only when we can actually select — need a client_secret).
        let tokenSelection = intent.needsTokenSelection && intent.clientSecret != nil
        self.needsTokenSelection = tokenSelection
        // Remember whether token selection was a step at all, so the details step
        // can offer a "back" affordance only when it followed token selection.
        self.hadTokenSelectionStep = tokenSelection
        // Seed the phase from the intent's initial status so the UI isn't blank
        // before the first poll returns.
        self.phase = ZuuppaPhase.from(action: Self.actionFromStatus(intent.status), shortfall: nil)
    }

    /// The accepted tokens the buyer may choose among (empty when the asset is
    /// already pinned). Sourced from the intent.
    public var acceptedTokens: [ZuuppaAcceptedToken] {
        intent.acceptedTokens ?? []
    } 

    // MARK: - Token names / tickers

    /// Look up human name + ticker (+ logo) for every asset the sheet might show —
    /// each accepted token, plus whatever's already pinned on the intent — so the
    /// UI can display "USD Coin · USDC" instead of a raw mint. Best-effort and
    /// cached: failures leave the label falling back to the symbol hint or a short
    /// mint. Safe to call more than once (only unresolved mints hit the network).
    public func resolveTokenNames() {
        guard config.resolveTokenNames else { return }
        var mints = Set(acceptedTokens.map { $0.mint ?? "sol" })
        mints.insert((lockedMint ?? intent.mint) ?? "sol")
        for key in mints where tokenMeta[key] == nil {
            let mint = key == "sol" ? nil : key
            Task { [weak self, directory] in
                guard let meta = await directory.metadata(forMint: mint) else { return }
                await MainActor.run { self?.tokenMeta[key] = meta }
            }
        }
    }

    /// Resolved metadata for an accepted token, if the lookup has returned.
    public func meta(for token: ZuuppaAcceptedToken) -> ZuuppaTokenMeta? {
        tokenMeta[token.id]
    }

    /// Inject resolved metadata directly, bypassing the network lookup — for tests
    /// and previews only.
    func applyTokenMetaForTesting(_ meta: ZuuppaTokenMeta, forKey key: String) {
        tokenMeta[key] = meta
    }

    /// Drive the phase from a server `action` string as the poll loop would, for
    /// tests and previews only (bypasses the network).
    func applyActionForTesting(_ action: String, shortfall: Int64? = nil) {
        phase = ZuuppaPhase.from(action: action, shortfall: shortfall)
    }

    /// The best label for an accepted token row: the resolved name if we have it,
    /// else the server's symbol hint, else the token's own short-mint fallback.
    public func displayName(for token: ZuuppaAcceptedToken) -> String {
        tokenMeta[token.id]?.name ?? token.displayLabel
    }

    /// The ticker line under the name (e.g. "SOL" / "USDC"), or a generic asset
    /// kind when we can't resolve one.
    public func ticker(for token: ZuuppaAcceptedToken) -> String {
        if let symbol = tokenMeta[token.id]?.symbol, !symbol.isEmpty { return symbol }
        if let symbol = token.symbol, !symbol.isEmpty { return symbol }
        return token.isSOL ? "SOL" : "SPL token"
    }

    /// Whether the buyer's flow has reached a stopping point: any terminal phase,
    /// OR `settling`. We treat `settling` as done because once funds are received
    /// the server guarantees they reach the seller — completing to the seller if
    /// the split settlement gets stuck rather than ever returning them to the
    /// buyer. So the buyer can be confidently shown success and finished the moment
    /// we detect payment, without waiting for the on-chain sweep. Drives the
    /// confirmation screen, `onFinish`, poll-stop, and cancellation guarding.
    public var isFinished: Bool {
        phase.isTerminal || phase == .settling
    }

    /// Whether the "Pay with wallet" button should be shown.
    public var showsWalletButton: Bool {
        config.showPayWithWallet && onPayWithWallet != nil && !isFinished
    }

    /// The final result for `onFinish`, once finished. `settling` maps to a
    /// `.settled` success (the settlement breakdown isn't available yet, so it's
    /// carried as nil until the sweep records it).
    public var result: ZuuppaCheckoutResult {
        switch phase {
        case .settled, .settling: return .settled(status?.settlement)
        case .expired: return .expired
        case .refunded: return .refunded
        case .cancelled: return .cancelled
        default: return .cancelled
        }
    }

    /// Begin polling. Safe to call once when the sheet appears.
    public func start() {
        // Resolve token names/logos in the background regardless of which step the
        // sheet opens on (fixed-token intents skip token-select entirely).
        resolveTokenNames()
        guard pollTask == nil else { return }
        guard let secret = intent.clientSecret else {
            errorMessage = ZuuppaError.missingClientSecret.localizedDescription
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

    /// Cancel the checkout when the buyer can no longer resume it (they closed or
    /// swiped away the sheet before a terminal state). Stops polling and tells the
    /// server to cancel the intent immediately — a partial payment is refunded,
    /// otherwise the intent is marked `cancelled`. Fire-and-forget: the request is
    /// detached with a value-captured client so it completes even as the model is
    /// torn down, and any failure is harmless because the server's 10-minute
    /// timeout is the backstop. No-op once terminal or already cancelled.
    public func cancel() {
        // Never cancel once the buyer's flow is finished — in particular, once
        // funds are received (`settling`) the payment is committed and must not be
        // cancelled (the server no-ops it anyway, but we don't even try).
        guard !isFinished, !didCancel else { return }
        didCancel = true
        stop()
        guard let secret = intent.clientSecret, secret.hasPrefix("cs_") else { return }
        let api = self.api
        Task.detached {
            _ = try? await api.cancel(clientSecret: secret)
        }
    }

    /// Run the host's wallet callback. The poll loop keeps running, so however
    /// the payment lands (this callback, or the buyer scanning the QR), the UI
    /// advances the same way.
    ///
    /// Drives `walletFlow` so the UI can show a full-screen processing state:
    ///   - `.confirming` while the callback runs (wallet signing/submitting)
    ///   - `.submitted` once it returns successfully, while we wait for the payment
    ///     to be detected on-chain (the poll loop advances to a terminal phase)
    ///   - back to `.idle` on cancel or error, returning the buyer to the QR screen
    /// We deliberately do NOT reset to `.idle` on success: the buyer stays on the
    /// processing screen until the poll loop flips to a terminal phase (settling),
    /// which routes to the confirmation screen.
    public func payWithWallet() {
        guard let onPayWithWallet, walletFlow == .idle else { return }
        walletFlow = .confirming
        errorMessage = nil
        let intent = self.intent
        Task { [weak self] in
            do {
                try await onPayWithWallet(intent)
                // Submitted — keep the processing screen up and let polling carry
                // the buyer to the confirmation screen once the payment lands.
                await MainActor.run { self?.walletFlow = .submitted }
            } catch is CancellationError {
                // Buyer backed out of their wallet flow: return to the QR screen
                // (they can retry or scan/copy instead). Nothing to surface.
                await MainActor.run { self?.walletFlow = .idle }
            } catch {
                await MainActor.run {
                    self?.errorMessage = error.localizedDescription
                    self?.walletFlow = .idle
                }
            }
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
            let a = d.address ?? ZuuppaAddress()
            if (a.country ?? "").trimmed.isEmpty { return "Please select your country." }
            if (a.line1 ?? "").trimmed.isEmpty { return "Please enter your street address." }
            // Required-ness follows the country's own format: some countries have
            // no postal code, and only some collect (and require) a state/region.
            let fmt = ZuuppaAddressFormat.resolve(for: a.country)
            if (a.city ?? "").trimmed.isEmpty { return "Please enter your \(fmt.cityLabel.lowercased())." }
            if fmt.showState, fmt.stateRequired, (a.state ?? "").trimmed.isEmpty {
                return "Please enter your \(fmt.stateLabel.lowercased())."
            }
            if fmt.showPostal, (a.postalCode ?? "").trimmed.isEmpty {
                return "Please enter your \(fmt.postalLabel.lowercased())."
            }
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
                    self.errorMessage = (error as? ZuuppaError)?.errorDescription
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

    /// Whether the details step can go back to the token-select step — only when
    /// token selection preceded it (so details wasn't the opening screen) and no
    /// submission is in flight.
    public var canGoBackToTokenSelection: Bool {
        hadTokenSelectionStep && !isSubmittingDetails
    }

    /// Return from the details step to the token-select step, re-showing it so the
    /// buyer can change their pay-in token. Keeps any details they've entered.
    public func backToTokenSelection() {
        guard canGoBackToTokenSelection else { return }
        errorMessage = nil
        needsTokenSelection = true
    }

    /// Whether the pay step can go back to a preceding step — only before payment
    /// starts (still awaiting), and only when some step preceded it (details or
    /// token selection). Nothing to go back to once funds are in flight/terminal.
    public var canGoBackFromPay: Bool {
        guard phase == .awaitingPayment, !isPayingWithWallet else { return false }
        return hadDetailsStep || hadTokenSelectionStep
    }

    /// Return from the pay step to the previous step: the details step if it was
    /// part of this checkout, otherwise the token-select step. Re-shows that step
    /// so the buyer can revise their entry / pay-in token before paying.
    public func backFromPay() {
        guard canGoBackFromPay else { return }
        errorMessage = nil
        if hadDetailsStep {
            needsDetails = true
        } else if hadTokenSelectionStep {
            needsTokenSelection = true
        }
    }

    /// Whether the details step may be skipped (nothing is required).
    public var detailsAreSkippable: Bool {
        let f = config.fields
        return !f.name.isRequired && !f.email.isRequired && !f.address.isRequired
    }

    // MARK: - Token selection (USD-priced intents)

    /// Load per-token preview amounts for the token-select step. Non-fatal on
    /// error — the buyer can still pick a token (which computes its amount then).
    public func loadQuotes() {
        guard let secret = intent.clientSecret else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let q = try await self.api.quote(clientSecret: secret)
                await MainActor.run { self.quotes = q }
            } catch {
                // Preview is best-effort; selecting a token still works without it.
            }
        }
    }

    /// The preview amount for one accepted token, if quotes are loaded.
    public func quoteLine(for token: ZuuppaAcceptedToken) -> ZuuppaQuoteLine? {
        quotes?.quotes.first { $0.mint == token.mint }
    }

    /// Select a pay-in token: locks the amount server-side (USD → base units at
    /// spot) and advances past the token-select step. `mint == nil` = SOL. On a
    /// network error we surface it and stay on the step. `onDone` runs only on
    /// success (so the UI can move to payment).
    public func selectToken(mint: String?, onDone: @escaping () -> Void) {
        guard !isSelectingToken else { return }
        guard let secret = intent.clientSecret else {
            // No secret to authorize the selection — can't proceed on this path.
            errorMessage = ZuuppaError.missingClientSecret.localizedDescription
            return
        }
        isSelectingToken = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let s = try await self.api.selectToken(clientSecret: secret, mint: mint)
                await MainActor.run {
                    self.selectedMint = mint
                    self.apply(s)
                    self.isSelectingToken = false
                    self.needsTokenSelection = false
                    onDone()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = (error as? ZuuppaError)?.errorDescription
                        ?? error.localizedDescription
                    self.isSelectingToken = false
                }
            }
        }
    }

    /// Trim all fields and drop blanks before sending.
    private func normalizedDetails() -> ZuuppaCustomerDetails {
        func c(_ s: String?) -> String? {
            let t = (s ?? "").trimmed
            return t.isEmpty ? nil : t
        }
        let f = config.fields
        var out = ZuuppaCustomerDetails()
        if f.name.isShown {
            out.firstName = c(details.firstName)
            out.lastName = c(details.lastName)
        }
        if f.email.isShown {
            out.email = c(details.email)
        }
        if f.address.isShown, let a = details.address {
            let addr = ZuuppaAddress(
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
                // Stop as soon as the buyer's flow is finished — including
                // `settling`, where the payment is committed and we send the buyer
                // to confirmation without waiting for the sweep.
                if isFinished { break }
            } catch is CancellationError {
                break
            } catch {
                // Transient — surface softly, keep polling.
                errorMessage = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: UInt64(config.pollInterval * 1_000_000_000))
        }
    }

    private func apply(_ s: ZuuppaStatus) {
        status = s
        errorMessage = nil
        phase = ZuuppaPhase.from(action: s.action, shortfall: s.shortfallLamports)
        // Once the amount is locked (by a token selection), capture the pinned
        // asset so the pay view can render the amount even though the immutable
        // `intent` was created without it.
        if let locked = s.expectedLamports {
            lockedExpectedLamports = locked
            lockedMint = s.mint
            lockedDecimals = s.mint == nil ? 9 : s.mintDecimals
            // The pinned asset may not have been among the accepted tokens we
            // already resolved; make sure its name/logo gets looked up too.
            resolveTokenNames()
        }
    }

    /// The amount to display/QR-encode on the pay view: the locked amount (once a
    /// USD-priced intent's token is selected) else the intent's fixed amount.
    public var payExpectedLamports: Int64? {
        lockedExpectedLamports ?? intent.expectedLamports
    }

    /// The asset label to display on the pay view (reflects a locked selection).
    /// Prefers a resolved ticker, then a truncated mint, then "SOL".
    public var payAssetLabel: String {
        let mint = lockedMint ?? intent.mint
        if let symbol = tokenMeta[mint ?? "sol"]?.symbol, !symbol.isEmpty { return symbol }
        guard let mint else { return "SOL" }
        return mint.count > 12 ? "\(mint.prefix(4))…\(mint.suffix(4))" : mint
    }

    /// The full asset name for the pay view subtitle (e.g. "USD Coin" / "Solana"),
    /// once resolved; nil when we only have a ticker/mint.
    public var payAssetName: String? {
        tokenMeta[(lockedMint ?? intent.mint) ?? "sol"]?.name
    }

    /// The decimals to use when formatting the pay amount (reflects a selection).
    public var payDecimals: Int {
        if let d = lockedDecimals { return d }
        return intent.decimals
    }

    /// Map a raw intent `status` string to the equivalent `action` string used
    /// by `ZuuppaPhase.from` (they diverge only for sweeping → paid).
    private static func actionFromStatus(_ status: String) -> String {
        switch status {
        case "pending": return "waiting"
        case "sweeping": return "paid"
        default: return status
        }
    }
}
