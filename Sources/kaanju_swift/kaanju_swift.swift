//  kaanju_swift
//
//  A drop-in payment checkout sheet for the Kaanju processing API — the crypto
//  side of a Stripe-style flow. Any integrator whose backend has created a
//  Kaanju payment intent can present this sheet to collect the payment:
//
//    • shows the deposit address as a QR code + copyable text,
//    • offers a "Pay with wallet" button that runs YOUR wallet logic, and
//    • polls the intent's status live, driving the UI from `pending` through
//      `paid → settling → settled` (and `underpaid`/`overpaid`/`expired`/
//      refunds), then a confirmation — regardless of HOW the payment arrives.
//
//  It is generic: no events, tickets, or app-specific concepts. You give it a
//  `KaanjuIntent` (which your server got from `POST /intents`, including the
//  one-time `client_secret`) and it does the rest.
//
//  ## Security model
//
//  The Kaanju Payments API (`POST /intents`, `GET /status`, `POST /sweep`) is
//  authenticated by your SECRET api key (`sk_live_…`), which must NEVER ship in
//  an app binary. So the SDK never sees it. Instead, your server creates the
//  intent and passes the returned per-intent `client_secret` (`cs_…`) down to
//  the app. The SDK polls only the public, read-only endpoint
//  `GET /intents/status?client_secret=…`, which exposes just that ONE intent's
//  status. See `KaanjuAPI`.
//
//  ## Quick start
//
//  ```swift
//  // 1. Your server: POST /intents with your sk_ key, return the JSON to the app.
//  // 2. In the app, decode it and present the sheet:
//  .kaanjuCheckout(isPresented: $showing, intent: intent,
//                  onPayWithWallet: { intent in try await myWallet.pay(intent) },
//                  onFinish: { result in ... })
//  ```

import Foundation

/// Namespace + version marker for the SDK.
public enum KaanjuSwift {
    public static let version = "0.1.0"
}
