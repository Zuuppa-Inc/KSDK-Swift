# Zuuppa Swift SDK

A drop-in checkout sheet for iOS. You hand it a payment intent your backend
created; it shows the deposit address as a QR code, offers an optional "Pay with
wallet" button that runs *your* wallet code, polls the payment live, and closes
itself with a result.

- **Zero dependencies.** QR via CoreImage, networking via URLSession, colors from
  a bundled asset catalog. Nothing to resolve.
- **Your secret key never ships.** The SDK only ever holds a per-intent
  `client_secret`.
- **One line to present.** `.zuuppaCheckout(isPresented:intent:)` on any SwiftUI
  view.

This README goes from an empty Xcode project to a working payment. The same
material lives in the hosted docs at
**<https://zuuppa.com/docs/06-swift-sdk>**.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [How the pieces fit](#how-the-pieces-fit)
- [Step 1: Your backend creates the intent](#step-1-your-backend-creates-the-intent)
- [Step 2: Decode it into a `ZuuppaIntent`](#step-2-decode-it-into-a-zuuppaintent)
- [Step 3: Present the sheet](#step-3-present-the-sheet)
- [Step 4: React to the result](#step-4-react-to-the-result)
- [What the sheet actually does](#what-the-sheet-actually-does)
- [`zuuppaCheckout`: the one entry point](#zuuppacheckout-the-one-entry-point)
- [`ZuuppaConfig`](#zuuppaconfig)
- [Collecting buyer details](#collecting-buyer-details)
- [Model reference](#model-reference)
- [Advanced: build your own UI](#advanced-build-your-own-ui)
- [Theming](#theming)
- [Test it without writing a backend](#test-it-without-writing-a-backend)
- [Troubleshooting](#troubleshooting)
- [Checklist before shipping](#checklist-before-shipping)

---

## Requirements

| Requirement | Value |
|---|---|
| Platform | **iOS 17+** (the checkout UI is UIKit-gated) |
| Swift | 5.9+ (Xcode 15+) |
| UI framework | SwiftUI |
| Backend | Any server that can call [`POST /intents`](https://zuuppa.com/docs/03-api-reference#post-intents) |

> The package also declares macOS 14 so its model/decoding tests can run on a dev
> machine (`swift test`). The **checkout screen itself is iOS-only**: on macOS
> the models, `ZuuppaAPI`, and `CheckoutModel` compile, but `.zuuppaCheckout` does
> not exist.

---

## Install

The SDK is a Swift package:

```
https://github.com/Zuuppa-Inc/Zuuppa_Swift_SDK.git
```

### In Xcode

1. **File → Add Package Dependencies…**
2. Paste the URL above into the search field.
3. **Dependency Rule → Branch → `main`**, then **Add Package**.
4. Add the **`Zuuppa_Swift_SDK`** library product to your app target.

### In a `Package.swift`

```swift
dependencies: [
    .package(url: "https://github.com/Zuuppa-Inc/Zuuppa_Swift_SDK.git", branch: "main"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "Zuuppa_Swift_SDK", package: "Zuuppa_Swift_SDK"),
        ]
    ),
]
```

> **Versioning.** The SDK is pre-1.0 and has no release tag yet, so track `main`.
> Once a version is tagged you can pin it the usual way
> (`from: "0.1.0"`). The bundled build reports itself as
> `ZuuppaSwift.version`, which is `"0.1.0"` today.

Then, in any file that uses it:

```swift
import Zuuppa_Swift_SDK
```

No plist keys, no URL schemes, no capabilities are required by the SDK itself.
(If *your* wallet callback opens another app, that app's URL scheme goes in
`LSApplicationQueriesSchemes`, which is your integration, not ours.)

---

## How the pieces fit

The SDK is the **client half** of the flow described in the
[Integration guide](https://zuuppa.com/docs/04-integration-guide). Nothing changes
on the server side.

```
Your app          Your backend                 Zuuppa
   │                   │                          │
   │── start checkout ─▶                          │
   │                   │── POST /intents ────────▶│  (Authorization: sk_live_…)
   │                   │◀── intent JSON ──────────│  incl. client_secret (cs_…)
   │◀── that JSON ─────│                          │
   │                                              │
   │  ZuuppaIntent → .zuuppaCheckout(…)           │
   │──────── GET /intents/status?client_secret ───▶│  (every 3s, no key needed)
   │◀─────── pending → paid → swept ──────────────│
   │                                              │
   │                   │◀── intent.paid webhook ──│  ← fulfill HERE, not in the app
```

**The secret key is never in the app.** `POST /intents` needs
`Authorization: Bearer sk_live_…`, which must stay on your server. Your server
creates the intent and passes the response down; the app gets only the intent's
one-time `client_secret` (`cs_…`), which authorizes read/act on **that one
intent** and nothing else.

> **Fulfill from your backend**, on the `intent.paid` / `intent.swept`
> [webhook](https://zuuppa.com/docs/05-webhooks) (or by polling `GET /status` with
> your key). `onFinish` in the app is a UX signal only: a client can always be
> closed, killed, or lied to.

---

## Step 1: Your backend creates the intent

Anything that speaks HTTP works. Return the response body to the app **as-is**,
including `client_secret`.

```ts
// POST /api/checkout on YOUR server
app.post("/api/checkout", async (req, res) => {
  const r = await fetch("https://api.zuuppa.com/intents", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${process.env.ZUUPPA_SECRET_KEY!}`,
    },
    body: JSON.stringify({
      amount_usd_cents: 2500,
      accepted_tokens: [{ kind: "sol" }, { kind: "spl", mint: "EPjF…Dt1v" }],
      reference: "order-1001",           // optional: your own order id
    }),
  });
  res.status(r.status).send(await r.text());   // forward verbatim
});
```

Two things to get right:

1. **Forward `client_secret`.** Without it the sheet can't poll and shows
   *"This payment is missing its client_secret…"*. It is returned **only** on the
   first create. An idempotent retry with the same `reference` returns
   `client_secret: null`.
2. **Create it when the buyer is ready to pay.** Every intent has a fixed
   **10-minute** window; don't mint one on app launch.

---

## Step 2: Decode it into a `ZuuppaIntent`

`ZuuppaIntent` is `Codable` against the exact wire shape of the API, so a plain
`JSONDecoder` is all you need: no custom keys, no mapping layer.

```swift
import Zuuppa_Swift_SDK

func startCheckout() async throws -> ZuuppaIntent {
    var req = URLRequest(url: URL(string: "https://myapp.example/api/checkout")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (data, _) = try await URLSession.shared.data(for: req)
    return try JSONDecoder().decode(ZuuppaIntent.self, from: data)
}
```

If your API wraps the intent in an envelope, decode your own type and pull the
intent out, or build one by hand with `ZuuppaIntent(id:address:clientSecret:…)`.

---

## Step 3: Present the sheet

One modifier. This is a complete, working screen:

```swift
import SwiftUI
import Zuuppa_Swift_SDK

struct CheckoutButton: View {
    @State private var intent: ZuuppaIntent?
    @State private var showCheckout = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 12) {
            Button("Pay $25.00") {
                Task {
                    loading = true
                    defer { loading = false }
                    do {
                        intent = try await startCheckout()   // Step 2
                        showCheckout = true
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .disabled(loading)

            if let error { Text(error).foregroundStyle(.red) }
        }
        // The modifier takes a non-optional intent, so attach it to an inert view
        // that only exists once we have one.
        .overlay {
            if let intent {
                Color.clear
                    .allowsHitTesting(false)
                    .zuuppaCheckout(
                        isPresented: $showCheckout,
                        intent: intent,
                        onFinish: { result in
                            switch result {
                            case .settled:   print("paid; confirm from your backend")
                            case .cancelled: print("buyer closed the sheet")
                            case .expired:   print("the 10-minute window closed")
                            case .refunded:  print("funds went back to the buyer")
                            }
                            self.intent = nil   // an intent is single-use
                        }
                    )
            }
        }
    }
}
```

An intent is **single-use**: clear it when you're done and create a fresh one for
the next attempt. Don't hold one across app launches; it expires in 10 minutes.

That's the whole integration. Everything below is optional configuration and the
per-component reference.

---

## Step 4: React to the result

`onFinish` fires **exactly once**, and **after the sheet has closed**, so it's
always safe to tear down state or present your own follow-up UI from it.

```swift
public enum ZuuppaCheckoutResult: Sendable, Equatable {
    case settled(ZuuppaSettlement?)   // payment received (settlement may still be nil)
    case expired                      // window closed unpaid
    case refunded                     // funds returned to the buyer
    case cancelled                    // buyer dismissed before a terminal state
}
```

- `.settled` is reported as soon as the payment is **detected**, without waiting
  for the on-chain sweep. Once funds are received the server guarantees they
  reach you. So `ZuuppaSettlement` (the exact delivered amounts) is often `nil`
  here; read it from the `intent.swept`
  [webhook](https://zuuppa.com/docs/05-webhooks) instead.
- `.cancelled` also means the SDK called
  [`POST /intents/cancel`](https://zuuppa.com/docs/03-api-reference#post-intentscancel)
  for you: a partial payment is refunded, otherwise the intent is marked
  `cancelled` immediately rather than waiting out the 10 minutes.

---

## What the sheet actually does

Steps appear only when they apply, in this order:

| Step | Shown when | What happens |
|---|---|---|
| **Choose how to pay** | The intent is USD-priced and its amount isn't locked yet (`accepted_tokens` present, `expected_lamports: null`) | Lists the tokens you accept with names + logos. Tapping one calls [`POST /intents/select-token`](https://zuuppa.com/docs/03-api-reference#post-intentsselect-token), which converts USD → base units at spot and **locks** the amount. |
| **Your details** | `config.fields` collects anything | Name / email / address form with per-country address formats and validation. Submits to [`POST /intents/details`](https://zuuppa.com/docs/03-api-reference#post-intentsdetails). |
| **Pay** | Always | Amount, a QR of the deposit address, the address as tappable text (tap either to copy), a live status line, and the optional wallet button. |
| **Confirmation** | A terminal state is reached | Success/expired/refunded summary, then the sheet **auto-dismisses after ~2s** on success. |

Behaviour worth knowing:

- The QR encodes the **bare deposit address** (not a `solana:` URI), so any wallet
  scanner works.
- Polling is `GET /intents/status?client_secret=…` every `pollInterval`
  (3s default) and stops at a terminal state. Transient network errors are shown
  softly and polling continues.
- However the payment arrives (the wallet button, a scanned QR, a copy-paste from
  a desktop wallet), the same poll loop drives the UI. There is no "wrong" path.
- Back navigation is offered where it's safe (details → token choice; pay → its
  previous step) and disappears once funds are in flight.
- The SDK owns dismissal. Don't flip `isPresented` yourself to close it; let the
  buyer's X / swipe or the auto-dismiss do it, and use `onFinish`.

---

## `zuuppaCheckout`: the one entry point

```swift
public extension View {
    func zuuppaCheckout(
        isPresented: Binding<Bool>,
        intent: ZuuppaIntent,
        config: ZuuppaConfig = .default,
        onPayWithWallet: (@Sendable (ZuuppaIntent) async throws -> Void)? = nil,
        onFinish: ((ZuuppaCheckoutResult) -> Void)? = nil
    ) -> some View
}
```

| Parameter | Meaning |
|---|---|
| `isPresented` | Set it `true` to present. The SDK sets it back to `false` itself. |
| `intent` | The intent from your server, with its `client_secret`. |
| `config` | Presentation, polling, and field config. See [`ZuuppaConfig`](#zuuppaconfig). |
| `onPayWithWallet` | Your wallet code. Omit for a QR-only sheet. |
| `onFinish` | Called once, after the sheet closes, with the outcome. |

The screen behind it (`ZuuppaCheckoutScreen`) is intentionally **internal**. This
modifier is the supported way to present checkout.

### The wallet button

Provide `onPayWithWallet` and the sheet shows a primary button (default title
"Pay with wallet"). Your closure does whatever your app does: Phantom deeplink,
Apple Pay onramp, an embedded wallet, a `WKWebView`:

```swift
.zuuppaCheckout(
    isPresented: $showCheckout,
    intent: intent,
    onPayWithWallet: { intent in
        // `intent.address`, `intent.expectedLamports`, `intent.mint` are all here.
        try await myWallet.send(
            to: intent.address,
            baseUnits: intent.expectedLamports ?? 0,
            mint: intent.mint
        )
    },
    onFinish: { result in … }
)
```

While it runs the sheet shows a processing screen instead of the QR, then waits
for the payment to be detected on-chain.

- **Throw `CancellationError`** if the buyer backs out of your wallet flow: the
  sheet silently returns to the QR screen so they can pay another way.
- **Throw anything else** to show `localizedDescription` as an inline error and
  return to the QR screen.
- **Return normally** once the transaction is submitted. Don't wait for
  confirmation, because the poll loop does that.
- Hide the button entirely with `config.showPayWithWallet = false` (or by omitting
  the closure).

---

## `ZuuppaConfig`

Every option, with its default:

```swift
public struct ZuuppaConfig: Sendable {
    public var apiBaseURL: URL          // https://api.zuuppa.com
    public var pollInterval: TimeInterval  // 3.0 seconds
    public var showPayWithWallet: Bool  // true
    public var payWithWalletTitle: String  // "Pay with wallet"
    public var fields: ZuuppaCheckoutFields  // .none: collect nothing
    public var resolveTokenNames: Bool  // true: look up names/logos
    public static let `default`: ZuuppaConfig
}
```

| Property | Notes |
|---|---|
| `apiBaseURL` | Point at a local server for development, e.g. `URL(string: "http://localhost:8080")!`. The simulator reaches your Mac's `localhost`; a device needs your Mac's LAN IP. |
| `pollInterval` | Seconds between status polls. Lower feels snappier and costs more requests. |
| `showPayWithWallet` | `false` gives a QR-only sheet even if you passed a callback. |
| `payWithWalletTitle` | Button label, e.g. `"Pay with Phantom"`. |
| `fields` | Which buyer details to collect. See below. |
| `resolveTokenNames` | Resolves token name/ticker/logo from Jupiter's public, key-less directory so the sheet reads "USD Coin · USDC" instead of `EPjF…Dt1v`. Purely cosmetic; amounts always come from Zuuppa. Set `false` to avoid the third-party lookup. |

```swift
var config = ZuuppaConfig.default
config.pollInterval = 2
config.payWithWalletTitle = "Pay with Phantom"
config.fields.email = .required
```

---

## Collecting buyer details

Off by default, so the sheet goes straight to payment. Opt in per field:

```swift
public enum ZuuppaFieldRequirement: String { case off, optional, required }

public struct ZuuppaCheckoutFields: Sendable, Equatable {
    public var name: ZuuppaFieldRequirement      // first + last
    public var email: ZuuppaFieldRequirement
    public var address: ZuuppaFieldRequirement   // international, country-aware
    public static let none: ZuuppaCheckoutFields
}
```

```swift
var config = ZuuppaConfig.default
config.fields.name = .required
config.fields.email = .required
config.fields.address = .optional
```

- `.optional` shows the field and lets the buyer continue blank; if every field is
  optional the step can be skipped outright.
- `.required` blocks Continue until it's filled, with messages like *"Please enter
  your email."* Address requirements follow the selected country's own format
  (some countries have no postal code; only some collect a state/region).
- Values are submitted to
  [`POST /intents/details`](https://zuuppa.com/docs/03-api-reference#post-intentsdetails)
  and then appear as `customer_details` on the intent: in the dashboard, in
  `GET /status`, and in your webhook payloads.
- The step is skipped if the intent has no `client_secret` (nothing could be
  submitted), rather than blocking the payment.

Related types, if you want to prefill or read them: `ZuuppaCustomerDetails`
(`firstName`, `lastName`, `email`, `address`), `ZuuppaAddress` (`country` as ISO
3166-1 alpha-2, `line1`, `line2`, `city`, `state`, `postalCode`), and
`ZuuppaCountries.all` / `.country(for:)` / `.current` for the localized country
list the picker uses (each `ZuuppaCountry` has `code`, `name`, `flag`).

---

## Model reference

Everything below is `Codable` (against the API's snake_case wire format),
`Sendable`, and `Equatable`.

### `ZuuppaIntent`

What you decode from your server and hand to the sheet.

| Property | Type | Notes |
|---|---|---|
| `id` | `String` | Globally-unique intent id. |
| `address` | `String` | Deposit address (the QR payload). |
| `clientSecret` | `String?` | `cs_…`. **Required for polling.** Only on the fresh create response. |
| `mint` | `String?` | SPL mint, `nil` for native SOL. |
| `mintDecimals` | `Int?` | Decimals of `mint` (`nil` for SOL, which is 9). |
| `expectedLamports` | `Int64?` | Amount in base units, or `nil` if not locked yet. |
| `status` | `String` | `pending`, `underpaid`, `paid`, `swept`, … |
| `receivedLamports` | `Int64` | Received so far, in base units. |
| `reference` | `String?` | Your own order id, if you set one. |
| `mode` | `String?` | `"custom"` or `"order"`. |
| `priceUsdCents` | `Int64?` | Set for a USD-denominated intent. |
| `acceptedTokens` | `[ZuuppaAcceptedToken]?` | Pay-in choices, until the asset is pinned. |
| `lineItems` | `[ZuuppaLineItem]` | Cart snapshot for order-mode intents; empty otherwise. |

Convenience: `isSOL`, `decimals`, `assetLabel`, `isUsdPriced`,
`needsTokenSelection`.

### `ZuuppaStatus`

What the SDK polls. Flattens the intent, plus:

| Property | Notes |
|---|---|
| `action` | `waiting`, `underpaid`, `paid`, `overpaid`, `refunding`, `refunded`, `swept`, `expired`, `refund_failed`. |
| `message` | A human string that's safe to show the payer. |
| `shortfallLamports` | For an underpayment: how much more is needed. |
| `tokenRefunds` | `[ZuuppaTokenRefund]`. Wrong-token payments being auto-returned. |
| `settlement` | `ZuuppaSettlement?`, populated once swept. |

### `ZuuppaPhase`

The sheet's high-level state, derived from `action` so your code doesn't have to
track server strings:

```swift
case awaitingPayment
case underpaid(shortfall: Int64?)
case settling
case settled
case expired
case refunding
case refunded
case refundFailed
case cancelled

public var isTerminal: Bool
public static func from(action: String, shortfall: Int64?) -> ZuuppaPhase
```

### Supporting types

| Type | What it is |
|---|---|
| `ZuuppaAcceptedToken` | A pay-in choice: `kind` (`"sol"` / `"spl"`), `mint`, `decimals`, `symbol`, plus `isSOL` and `displayLabel`. |
| `ZuuppaLineItem` | One cart line as charged: `itemId`, `name`, `unitPriceUsdCents`, `quantity`, `lineTotalUsdCents`. |
| `ZuuppaSettlement` | Exact settled amounts: `asset`, `decimals`, `destinationAmount`/`destinationUi`, `platformFeeAmount`/`platformFeeUi`, `signatures`. |
| `ZuuppaTokenRefund` | A wrong-token payment being returned: `mint`, `status`. |
| `ZuuppaQuote` / `ZuuppaQuoteLine` | Preview of what each accepted token would cost right now (`priceUsdCents`, `expiresInSeconds`, per-token `expectedLamports`). Preview only; selecting is what locks. |
| `ZuuppaError` | `.missingClientSecret`, `.server(status:message:)`, `.transport(String)`. Conforms to `LocalizedError`. |

### `ZuuppaAmount`

Base units are integers (lamports / token base units). Format them with:

```swift
ZuuppaAmount.ui(500_000_000, decimals: 9)                   // 0.5
ZuuppaAmount.numberString(500_000_000, decimals: 9)         // "0.5"
ZuuppaAmount.format(500_000_000, decimals: 9, symbol: "SOL") // "0.5 SOL"
ZuuppaAmount.format(500_000_000, for: intent)                // "0.5 SOL"
```

---

## Advanced: build your own UI

The sheet is the easy path, not the only one. Two public layers sit under it.

### `ZuuppaAPI`: the client-secret endpoints

A thin, `Sendable` URLSession wrapper over the five public endpoints. It never
holds your secret key.

```swift
let api = ZuuppaAPI(config: .default)

let status  = try await api.status(clientSecret: cs)                  // GET  /intents/status
let quote   = try await api.quote(clientSecret: cs)                   // GET  /intents/quote
let locked  = try await api.selectToken(clientSecret: cs, mint: nil)  // POST /intents/select-token (nil = SOL)
let updated = try await api.submitDetails(clientSecret: cs, details: d) // POST /intents/details
let cancel  = try await api.cancel(clientSecret: cs)                  // POST /intents/cancel
```

Each throws `ZuuppaError`, and each rejects a secret that isn't `cs_`-prefixed
before it hits the network. Pass a custom `URLSession` for tests:
`ZuuppaAPI(config: config, session: mySession)`.

### `CheckoutModel`: the state machine

`@MainActor @Observable`. Own it directly and render whatever you like; this is
exactly what the built-in sheet does.

```swift
let model = CheckoutModel(intent: intent, config: config, onPayWithWallet: pay)
model.start()   // begins polling + token-name resolution
```

| Member | Purpose |
|---|---|
| `status`, `phase`, `errorMessage` | Latest polled state, derived phase, soft error text. |
| `isFinished`, `result` | Whether to show a confirmation, and the `ZuuppaCheckoutResult` to report. |
| `start()` / `stop()` | Start and stop the poll loop. |
| `cancel()` | Fire-and-forget cancel; no-op once finished. Call it if the buyer walks away. |
| `payWithWallet()`, `walletFlow`, `isPayingWithWallet`, `showsWalletButton` | Runs your callback and exposes the `.idle`/`.confirming`/`.submitted` stages. |
| `details`, `needsDetails`, `validateDetails()`, `submitDetails(onDone:)`, `skipDetails()`, `detailsAreSkippable`, `isSubmittingDetails` | The details step. |
| `needsTokenSelection`, `acceptedTokens`, `selectToken(mint:onDone:)`, `isSelectingToken`, `loadQuotes()`, `quotes`, `quoteLine(for:)` | The token step. The bundled sheet doesn't show per-token previews; `loadQuotes()` is there if yours should. |
| `payExpectedLamports`, `payAssetLabel`, `payAssetName`, `payDecimals` | What to render on a pay screen, reflecting a locked token selection. |
| `tokenMeta`, `resolveTokenNames()`, `meta(for:)`, `displayName(for:)`, `ticker(for:)` | Resolved names / tickers / logos per token. |
| `canGoBackToTokenSelection`, `backToTokenSelection()`, `canGoBackFromPay`, `backFromPay()` | Safe back navigation. |

`isFinished` deliberately includes `.settling`: once funds are received the
payment is committed, so the buyer can be shown success without waiting for the
sweep.

### `ZuuppaTokenDirectory`

The cosmetic name/ticker/logo lookup, if you want it outside the sheet:

```swift
let meta = await ZuuppaTokenDirectory.shared.metadata(forMint: "EPjF…Dt1v")
// ZuuppaTokenMeta(mint:name:symbol:iconURL:): "USD Coin", "USDC", a logo URL
```

An `actor` with an in-process cache; `mint: nil` resolves native SOL. Every lookup
fails soft to `nil`, and IPFS logo URLs are rewritten to a fast gateway.

---

## Theming

Colors come from `ZuuppaColor`, backed by a bundled asset catalog with light and
dark appearances:

```swift
ZuuppaColor.background   ZuuppaColor.surface     ZuuppaColor.border
ZuuppaColor.textPrimary  ZuuppaColor.textSecondary  ZuuppaColor.textTertiary
ZuuppaColor.accent       ZuuppaColor.accentText
ZuuppaColor.success      ZuuppaColor.warning     ZuuppaColor.danger
```

They're `public` so you can match your own screens to the sheet. The sheet reads
these values from the package bundle, so re-theming it means editing the package's
`Sources/Zuuppa_Swift_SDK/Resources/ZuuppaColors.xcassets` (i.e. a fork). There
is no runtime theme override yet.

---

## Test it without writing a backend

Two `#if DEBUG` helpers ship in the package and are compiled out of release
builds.

**`ZuuppaPreviewHarness`** is a full interactive harness: enter a base URL, an
`sk_` test key, and an amount; it creates the intent and opens the real checkout
sheet, so you can drive create → QR → pay → settle end to end.

```swift
#if DEBUG
ZuuppaPreviewHarness()                       // or ZuuppaPreviewHarness(baseURL: "http://localhost:8080")
#endif
```

**`ZuuppaDebugClient`** is just the create call, if you're building your own
harness:

```swift
#if DEBUG
let client = ZuuppaDebugClient(baseURL: URL(string: "http://localhost:8080")!, apiKey: "sk_test_…")
let intent = try await client.createIntent(
    mode: "custom",
    amountUsdCents: 100,
    acceptedTokens: [["kind": "sol"]]
)
#endif
```

> **The `sk_` key is your server's job.** These exist so you can exercise the flow
> before your backend endpoint exists. Never ship a secret key in an app, and
> point them at a **test** account.

For local development also set `config.apiBaseURL` to your server, and allow
plain HTTP if it isn't TLS (`NSAllowsLocalNetworking` in your dev target's ATS
settings; do not ship that).

The package's own tests are platform-independent (models, decoding, formatting)
and run on a Mac:

```sh
swift test
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| *"This payment is missing its client_secret…"* | Your backend didn't forward `client_secret`, or you reused a `reference` (an idempotent retry returns `null`). | Forward the field; use a fresh `reference` per checkout. |
| Sheet opens on "Choose how to pay" unexpectedly | The intent is USD-priced with `expected_lamports: null`, so the amount isn't locked until a token is picked. | Expected. With one accepted token the buyer confirms a single row. |
| The details step never appears | `config.fields` is `.none`, or the intent has no `client_secret`. | Set `config.fields`; check the secret. |
| Status never advances | Wrong `apiBaseURL`, or the device can't reach it. | On a device use your Mac's LAN IP, not `localhost`. |
| Wallet button missing | No `onPayWithWallet`, or `showPayWithWallet == false`, or the checkout is already finished. | Pass the callback; check the flag. |
| `onFinish` gives `.settled(nil)` | Reported at payment detection, before the sweep records amounts. | Read exact amounts from the `intent.swept` [webhook](https://zuuppa.com/docs/05-webhooks). |
| Token names show as raw mints | The directory lookup failed or is disabled. | Cosmetic only. Check `resolveTokenNames`. |
| Sheet won't close / reopens | You're driving `isPresented` yourself. | Let the SDK own dismissal; act in `onFinish`. |
| `.zuuppaCheckout` is unresolved | You're building for macOS. | The checkout UI is iOS-only; the models and `ZuuppaAPI` are not. |

---

## Checklist before shipping

- [ ] No `sk_` key anywhere in the app target (search the binary, not just the source).
- [ ] `client_secret` forwarded by your backend on every create.
- [ ] Intents created at the moment of checkout (10-minute window).
- [ ] Fulfillment driven by the [`intent.paid` / `intent.swept` webhook](https://zuuppa.com/docs/05-webhooks), **not** by `onFinish`.
- [ ] `apiBaseURL` left at the production default (or pointed at the right environment).
- [ ] Tried a real payment against a test account end to end.

---

## Docs

- [Getting started](https://zuuppa.com/docs/01-getting-started): account, sweep destination, API key
- [Concepts](https://zuuppa.com/docs/02-concepts): intents, assets, base units, statuses
- [API reference](https://zuuppa.com/docs/03-api-reference): every endpoint behind this SDK
- [Integration guide](https://zuuppa.com/docs/04-integration-guide): the server side of checkout
- [Webhooks](https://zuuppa.com/docs/05-webhooks): how to fulfill orders
- [Swift SDK](https://zuuppa.com/docs/06-swift-sdk): this page, hosted
