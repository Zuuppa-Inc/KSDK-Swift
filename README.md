# kaanju_swift

A drop-in **payment checkout sheet** for the [Kaanju](https://api.kaanju.com)
processing API. It's the crypto side of a Stripe-style flow: your app creates a
payment intent, and this SDK presents a sheet that shows the deposit **QR code**,
offers a **"Pay with wallet"** button (running *your* wallet logic), and **tracks
the payment live** until it settles — for any SOL or SPL-token intent.

It is fully generic. No events, tickets, or app-specific concepts: you hand it a
payment intent, it collects the payment.

- iOS 17+, SwiftUI.
- **Zero dependencies** — the QR is rendered with CoreImage, networking with
  URLSession.
- Add via SPM.

## How it fits together

```
┌──────────────┐   sk_live_ key    ┌───────────────┐
│  YOUR SERVER │ ────────────────▶ │  Kaanju API   │   POST /intents
│              │ ◀──────────────── │               │   → intent + client_secret
└──────┬───────┘   intent JSON     └───────────────┘
       │ (forward the intent, incl. client_secret, to the app)
       ▼
┌──────────────┐   cs_ client_secret   ┌───────────────┐
│   YOUR APP   │ ────────────────────▶ │  Kaanju API   │   GET /intents/status
│ (this SDK)   │ ◀──────────────────── │   (public)    │   → live status
└──────────────┘   status (polled)     └───────────────┘
```

### Why your server creates the intent

The Kaanju **Payments API** (`POST /intents`, `GET /status`, `POST /sweep`) is
authenticated by your **secret** API key (`sk_live_…`). That key must **never**
ship in an app binary — anyone could extract it and create intents or read your
whole account.

So, exactly like Stripe: **your server** creates the intent with the secret key
and gets back a one-time **`client_secret`** (`cs_…`). You forward the intent
(including that `client_secret`) to the app. The SDK then polls only the
**public, read-only** endpoint `GET /intents/status?client_secret=…`, which
exposes just that *one* intent's status. A leaked `client_secret` can only ever
reveal that single payment — never the account or any other intent.

## Server-side: create the intent

```bash
curl -s -X POST https://api.kaanju.com/intents \
  -H "Authorization: Bearer sk_live_…" \
  -H "Content-Type: application/json" \
  -d '{"expected_lamports": 10000000, "reference": "order-42"}'
```

```json
{
  "id": "…", "address": "So1ana…", "client_secret": "cs_…",
  "expected_lamports": 10000000, "status": "pending", "received_lamports": 0,
  "reference": "order-42"
}
```

- `expected_lamports` — amount in base units (lamports for SOL; token base units
  if `mint` is set). Omit for an open-ended "any amount" intent.
- `mint` — an SPL mint address to accept that token instead of SOL (optional).
- `reference` — your order id (optional; makes creation idempotent).
- `expires_in_secs` — optional payment window.

Return that JSON to your app. **`client_secret` is only present on the first
create** (it's shown once and only its hash is stored), so persist/forward it
then.

## App-side: present the sheet

Decode the intent your server sent and present the checkout:

```swift
import kaanju_swift

struct BuyButton: View {
    let intent: KaanjuIntent          // decoded from your server's response
    @State private var showCheckout = false

    var body: some View {
        Button("Buy") { showCheckout = true }
            .kaanjuCheckout(
                isPresented: $showCheckout,
                intent: intent,
                onPayWithWallet: { intent in
                    // YOUR wallet logic — Phantom deeplink, in-app signer, etc.
                    // The address to pay is `intent.address`.
                    try await MyWallet.shared.send(to: intent.address)
                },
                onFinish: { result in
                    switch result {
                    case .settled:   print("paid ✅")
                    case .expired:   print("expired")
                    case .refunded:  print("returned")
                    case .cancelled: print("closed")
                    }
                }
            )
    }
}
```

Or present the screen directly (e.g. push it, or in your own sheet):

```swift
KaanjuCheckoutScreen(
    intent: intent,
    config: .default,
    onPayWithWallet: { intent in try await MyWallet.shared.send(to: intent.address) },
    onFinish: { result in … }
)
```

### The "Pay with wallet" button

`onPayWithWallet` is your closure `(KaanjuIntent) async throws -> Void`. Do
whatever your app needs — open a wallet deeplink, sign and send in-app, etc.
Throwing surfaces an inline error; the SDK keeps polling regardless.

The buyer can **also** just scan the QR from any external wallet. Detection is
on-chain and server-side, so either path lands in the same polled status — you
don't have to reconcile anything.

Omit `onPayWithWallet` (or set `config.showPayWithWallet = false`) for a
**QR-only** sheet.

## Statuses the sheet handles

Driven by the server's real state machine:

| Phase | Meaning |
|---|---|
| Waiting for payment | nothing (or not enough) received yet |
| Underpaid | partial payment; shows how much more to send |
| Payment received | detected; settling on-chain |
| Paid | settled (swept) — terminal success |
| Refunding / Refunded | overpayment excess or a late payment is returned |
| Expired | window closed with no completed payment |

Wrong-token payments are returned automatically and surfaced as a notice. Once
settled, `onFinish(.settled(settlement))` includes the exact on-chain amounts.

## Configuration

```swift
var cfg = KaanjuConfig.default
cfg.apiBaseURL = URL(string: "https://staging.kaanju.com")!  // default: api.kaanju.com
cfg.pollInterval = 3.0                                        // seconds
cfg.showPayWithWallet = true
cfg.payWithWalletTitle = "Pay with Phantom"
```

## Testing the whole flow locally (DEBUG)

A **DEBUG-only** test harness lets you exercise create → QR → poll → settle
against a local server without building a backend. It's compiled out of release
builds (`#if DEBUG`).

1. Run the server: `cd kaanju/server && cargo run` (listens on `:8080`).
2. Mint a test key (dashboard, or the dashboard API) — an `sk_test_…`.
3. Open **`KaanjuPreviewHarness`** — either the `#Preview("Harness (live server)")`
   in `Debug/KaanjuPreviewHarness.swift`, or drop it in your app:
   ```swift
   #if DEBUG
   KaanjuPreviewHarness(baseURL: "http://localhost:8080", apiKey: "sk_test_…")
   #endif
   ```
4. Enter URL + key + amount → **Create intent** → the real `KaanjuCheckoutScreen`
   opens. Pay by scanning the QR from a devnet wallet (or wire your own wallet
   callback via the initializer); polling drives it to settled.

The harness's `KaanjuDebugClient` does the `POST /intents` step the secret key —
i.e. your *server's* job — locally. **Never** ship an `sk_` key in a real app.

There are also two offline static previews (`Checkout — awaiting`, `QR only`)
for iterating on the UI without a server.

> **Local HTTP note:** iOS App Transport Security blocks plain `http://`. The
> **Simulator** reaches `http://localhost:8080` fine (localhost is exempt). On a
> **device**, use your Mac's LAN IP and add an ATS exception in the host app's
> Info.plist, or run the server behind `https`.

## Build

```bash
# iOS (the checkout UI is iOS-only, UIKit-gated):
xcodebuild -scheme kaanju_swift -destination 'generic/platform=iOS Simulator' build
# Model/decoding unit tests (run on a dev Mac):
swift test
```

> SourceKit in an editor may show false "Cannot find type" / "No such module"
> errors because it indexes against macOS. Trust the `xcodebuild` / `swift test`
> result.
