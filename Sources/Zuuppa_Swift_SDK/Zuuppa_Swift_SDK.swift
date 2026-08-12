//  Zuuppa_Swift_SDK
//
//  A drop-in payment checkout sheet for the Zuuppa processing API — the crypto
//  side of a Stripe-style flow. Any integrator whose backend has created a
//  Zuuppa payment intent can present this sheet to collect the payment:
//
//    • shows the deposit address as a QR code + copyable text,
//    • offers a "Pay with wallet" button that runs YOUR wallet logic, and
//    • polls the intent's status live, driving the UI from `pending` through
//      `paid → settling → settled` (and `underpaid`/`overpaid`/`expired`/
//      refunds), then a confirmation — regardless of HOW the payment arrives.
//
//  It is generic: no events, tickets, or app-specific concepts. You give it a
//  `ZuuppaIntent` (which your server got from `POST /intents`, including the
//  one-time `client_secret`) and it does the rest.
//
//  ## Security model
//
//  The Zuuppa Payments API (`POST /intents`, `GET /status`, `POST /sweep`) is
//  authenticated by your SECRET api key (`sk_live_…`), which must NEVER ship in
//  an app binary. So the SDK never sees it. Instead, your server creates the
//  intent and passes the returned per-intent `client_secret` (`cs_…`) down to
//  the app. The SDK polls only the public, read-only endpoint
//  `GET /intents/status?client_secret=…`, which exposes just that ONE intent's
//  status. See `ZuuppaAPI`.
//
//  ## Quick start
//
//  ```swift
//  // 1. Your server: POST /intents with your sk_ key, return the JSON to the app.
//  // 2. In the app, decode it and present the sheet:
//  .zuuppaCheckout(isPresented: $showing, intent: intent,
//                  onPayWithWallet: { intent in try await myWallet.pay(intent) },
//                  onFinish: { result in ... }) // fires after the sheet closes
//  ```
//
//  On success the sheet shows a brief confirmation and dismisses itself; `onFinish`
//  is called once, after the sheet is gone, so it's always safe to tear down or
//  present your own follow-up UI there.

import Foundation

/// Namespace + version marker for the SDK.
public enum ZuuppaSwift {
    public static let version = "0.1.0"
}
