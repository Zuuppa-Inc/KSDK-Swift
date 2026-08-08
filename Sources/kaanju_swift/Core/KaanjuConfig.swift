import Foundation

/// Configuration for a checkout session. Sensible production defaults are baked
/// in; override `apiBaseURL` to point at a staging/self-hosted server or tune
/// polling.
public struct KaanjuConfig: Sendable {
    /// Base URL of the Kaanju API. Defaults to production.
    public var apiBaseURL: URL

    /// How often to poll the intent's status while the sheet is open.
    public var pollInterval: TimeInterval

    /// Whether to show the "Pay with wallet" button. Set false to present a
    /// QR-only sheet (the buyer pays from any external wallet by scanning).
    public var showPayWithWallet: Bool

    /// Label for the wallet button.
    public var payWithWalletTitle: String

    /// Which buyer details to collect before payment (name / email / address),
    /// each toggled off / optional / required. Defaults to none, so the sheet
    /// goes straight to payment. Set these to add a details step.
    public var fields: KaanjuCheckoutFields

    public init(
        apiBaseURL: URL = URL(string: "https://api.kaanju.com")!,
        pollInterval: TimeInterval = 3.0,
        showPayWithWallet: Bool = true,
        payWithWalletTitle: String = "Pay with wallet",
        fields: KaanjuCheckoutFields = .none
    ) {
        self.apiBaseURL = apiBaseURL
        self.pollInterval = pollInterval
        self.showPayWithWallet = showPayWithWallet
        self.payWithWalletTitle = payWithWalletTitle
        self.fields = fields
    }

    /// Production defaults.
    public static let `default` = KaanjuConfig()
}
