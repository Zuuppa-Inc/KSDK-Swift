#if canImport(UIKit)
import SwiftUI

public extension View {
    /// Present the Kaanju checkout sheet.
    ///
    /// ```swift
    /// .kaanjuCheckout(
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
    func kaanjuCheckout(
        isPresented: Binding<Bool>,
        intent: KaanjuIntent,
        config: KaanjuConfig = .default,
        onPayWithWallet: (@Sendable (KaanjuIntent) async throws -> Void)? = nil,
        onFinish: ((KaanjuCheckoutResult) -> Void)? = nil
    ) -> some View {
        sheet(isPresented: isPresented) {
            KaanjuCheckoutScreen(
                intent: intent,
                config: config,
                onPayWithWallet: onPayWithWallet,
                onFinish: onFinish
            )
            .presentationDragIndicator(.visible)
        }
    }
}
#endif
