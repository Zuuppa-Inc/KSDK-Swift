#if canImport(UIKit)
import SwiftUI

public extension View {
    /// Present the Zuuppa checkout sheet.
    ///
    /// ```swift
    /// .zuuppaCheckout(
    ///     isPresented: $showCheckout,
    ///     intent: intent,
    ///     onPayWithWallet: { intent in try await wallet.pay(to: intent.address) },
    ///     onFinish: { result in if case .settled = result { /* … */ } }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - isPresented: binding controlling the sheet.
    ///   - intent: the intent to pay (must carry a `client_secret`).
    ///   - config: presentation + polling config.
    ///   - onPayWithWallet: your wallet logic; omit for a QR-only sheet.
    ///   - onFinish: terminal result callback. The sheet is NOT auto-dismissed on
    ///     finish (the buyer taps "Done"); flip `isPresented` here if you want to
    ///     dismiss on cancellation.
    func zuuppaCheckout(
        isPresented: Binding<Bool>,
        intent: ZuuppaIntent,
        config: ZuuppaConfig = .default,
        onPayWithWallet: (@Sendable (ZuuppaIntent) async throws -> Void)? = nil,
        onFinish: ((ZuuppaCheckoutResult) -> Void)? = nil
    ) -> some View {
        sheet(isPresented: isPresented) {
            ZuuppaCheckoutScreen(
                intent: intent,
                config: config,
                onPayWithWallet: onPayWithWallet,
                onFinish: onFinish
            )
            // No grabber pill — the screen sets `.hidden` itself; this keeps the
            // presentation clean (the bare X is the only chrome).
            .presentationDragIndicator(.hidden)
        }
    }
}
#endif
