#if DEBUG && canImport(UIKit)
import SwiftUI

/// **DEBUG-ONLY interactive harness** for exercising the full checkout flow
/// against a running server (e.g. your local `cargo run`), end to end:
///
///   enter local URL + sk_ key + amount → Create intent → the real
///   `ZuuppaCheckoutScreen` opens (QR + Pay-with-wallet + live polling) → pay
///   from a wallet (or simulate on-chain) → watch it settle.
///
/// It stands in for the piece that is normally your backend (creating the intent
/// with the secret key), so no server code of your own is needed to try it.
///
/// Use it from your app during development:
/// ```swift
/// #if DEBUG
/// ZuuppaPreviewHarness()
/// #endif
/// ```
/// or just open the `#Preview`s at the bottom of this file in Xcode.
/// The intent shapes the harness can create.
private enum HarnessMode: String, CaseIterable, Identifiable {
    /// custom + USD amount (buyer picks a token to lock it).
    case customUSD = "Custom · USD"
    /// order (cart priced server-side from catalog items).
    case order = "Order"
    var id: String { rawValue }
}

/// One editable cart row for order mode.
private struct HarnessCartLine: Identifiable {
    let id = UUID()
    var itemID: String = "1d22e848-3fc7-4341-b05d-96f0dd9bb032"
    var quantity: String = "1"
}

/// USDC (mainnet) mint — offered as a preset accepted token in USD/order modes.
private let harnessUSDCMint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

public struct ZuuppaPreviewHarness: View {
    // Simulator reaches the host Mac's localhost directly; a device needs the
    // Mac's LAN IP here instead.
    @State private var baseURL: String
    @State private var apiKey: String
    @State private var reference: String = ""

    // Pricing mode + USD/order fields.
    @State private var mode: HarnessMode = .customUSD
    @State private var amountUSD: String = "1.00"
    // Accepted pay-in tokens (USD/order modes). The buyer picks among these.
    @State private var acceptSOL = true
    @State private var acceptUSDC = false
    @State private var customTokenMint = "FeR8VBqNRSUD5NtXAj2n3j1dAHkZHfyDktKuLXD4pump"
    // Order-mode cart: item id + quantity rows.
    @State private var cart: [HarnessCartLine] = [HarnessCartLine()]

    // Which buyer details to collect, so the details step is testable end to end.
    @State private var nameReq: ZuuppaFieldRequirement = .off
    @State private var emailReq: ZuuppaFieldRequirement = .off
    @State private var addressReq: ZuuppaFieldRequirement = .off

    @State private var creating = false
    @State private var error: String?
    @State private var intent: ZuuppaIntent?
    @State private var showCheckout = false
    @State private var lastResult: ZuuppaCheckoutResult?

    /// Optional wallet callback. Defaults to a stub that just waits, so the
    /// button is exercisable even without a real wallet — the buyer can pay by
    /// scanning the QR and polling will still settle it.
    private let onPayWithWallet: (@Sendable (ZuuppaIntent) async throws -> Void)?

    public init(
        baseURL: String = "http://localhost:8080",
        apiKey: String = "",
        onPayWithWallet: (@Sendable (ZuuppaIntent) async throws -> Void)? = nil
    ) {
        _baseURL = State(initialValue: baseURL)
        _apiKey = State(initialValue: apiKey)
        self.onPayWithWallet = onPayWithWallet
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Server (DEBUG only)") {
                    LabeledField(label: "Base URL", text: $baseURL, mono: true)
                    LabeledField(label: "Secret key (sk_)", text: $apiKey, mono: true, secure: true)
                    Text("The sk_ key is your SERVER's job in production — it's used here only to create a test intent locally. Never ship it in an app.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("Mode") {
                    Picker("Mode", selection: $mode) {
                        ForEach(HarnessMode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.segmented)
                }

                switch mode {
                case .customUSD:
                    Section("Intent (USD-priced)") {
                        LabeledField(label: "Amount (USD)", text: $amountUSD, mono: true)
                        LabeledField(label: "Reference (optional)", text: $reference)
                    }
                    acceptedTokensSection
                case .order:
                    Section("Cart (item id + quantity)") {
                        ForEach($cart) { $line in
                            HStack(spacing: 8) {
                                LabeledField(label: "Item id", text: $line.itemID, mono: true)
                                LabeledField(label: "Qty", text: $line.quantity, mono: true)
                                    .frame(width: 64)
                            }
                        }
                        Button("Add line") { cart.append(HarnessCartLine()) }
                            .font(.footnote)
                        if cart.count > 1 {
                            Button("Remove last", role: .destructive) { cart.removeLast() }
                                .font(.footnote)
                        }
                        LabeledField(label: "Reference (optional)", text: $reference)
                    }
                    acceptedTokensSection
                }

                Section("Collect buyer details") {
                    requirementPicker("Name", selection: $nameReq)
                    requirementPicker("Email", selection: $emailReq)
                    requirementPicker("Address", selection: $addressReq)
                }

                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        HStack {
                            if creating { ProgressView() }
                            Text(creating ? "Creating…" : "Create intent & open checkout")
                        }
                    }
                    .disabled(creating || apiKey.isEmpty || baseURL.isEmpty)
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                if let lastResult {
                    Section("Last result") {
                        Text(describe(lastResult)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Zuuppa Test Harness")
        }
        .zuuppaCheckout(
            isPresented: $showCheckout,
            intent: intent ?? .previewPending,
            config: harnessConfig,
            onPayWithWallet: onPayWithWallet ?? { _ in
                // Stub: no real wallet. Wait briefly, then let QR-scan + polling
                // drive settlement. Replace via the initializer to test yours.
                try await Task.sleep(nanoseconds: 800_000_000)
            },
            onFinish: { result in lastResult = result }
        )
    }

    /// Accepted pay-in tokens the buyer chooses among (USD/order modes).
    private var acceptedTokensSection: some View {
        Section("Accepted tokens (buyer picks one)") {
            Toggle("SOL", isOn: $acceptSOL)
            Toggle("USDC", isOn: $acceptUSDC)
            LabeledField(label: "Custom SPL mint (optional)", text: $customTokenMint, mono: true)
        }
    }

    /// Build the `accepted_tokens` array for the current toggles.
    private func buildAcceptedTokens() -> [[String: Any]] {
        var out: [[String: Any]] = []
        if acceptSOL { out.append(["kind": "sol"]) }
        if acceptUSDC { out.append(["kind": "spl", "mint": harnessUSDCMint]) }
        let custom = customTokenMint.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { out.append(["kind": "spl", "mint": custom]) }
        return out
    }

    private var harnessConfig: ZuuppaConfig {
        var c = ZuuppaConfig.default
        if let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)) {
            c.apiBaseURL = url
        }
        c.pollInterval = 2.0
        c.fields = ZuuppaCheckoutFields(name: nameReq, email: emailReq, address: addressReq)
        return c
    }

    private func requirementPicker(
        _ label: String,
        selection: Binding<ZuuppaFieldRequirement>
    ) -> some View {
        Picker(label, selection: selection) {
            Text("Off").tag(ZuuppaFieldRequirement.off)
            Text("Optional").tag(ZuuppaFieldRequirement.optional)
            Text("Required").tag(ZuuppaFieldRequirement.required)
        }
        .pickerStyle(.menu)
    }

    private func create() async {
        error = nil
        creating = true
        defer { creating = false }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)) else {
            error = "Invalid base URL"; return
        }
        let client = ZuuppaDebugClient(baseURL: url, apiKey: apiKey.trimmingCharacters(in: .whitespaces))
        let ref = reference.isEmpty ? nil : reference
        do {
            let created: ZuuppaIntent
            switch mode {
            case .customUSD:
                let tokens = buildAcceptedTokens()
                guard !tokens.isEmpty else { error = "Select at least one accepted token."; return }
                guard let cents = parsedUSDCents() else { error = "Invalid USD amount."; return }
                created = try await client.createIntent(
                    reference: ref,
                    mode: "custom",
                    amountUsdCents: cents,
                    acceptedTokens: tokens
                )
            case .order:
                let tokens = buildAcceptedTokens()
                guard !tokens.isEmpty else { error = "Select at least one accepted token."; return }
                let lines = buildCart()
                guard !lines.isEmpty else { error = "Add at least one cart line (item id + qty)."; return }
                created = try await client.createIntent(
                    reference: ref,
                    mode: "order",
                    acceptedTokens: tokens,
                    cart: lines
                )
            }
            guard created.clientSecret != nil else {
                error = "Server returned no client_secret. (Reusing a reference returns the existing intent without one — change the reference.)"
                return
            }
            intent = created
            showCheckout = true
        } catch {
            self.error = (error as? ZuuppaError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// USD dollars → integer cents (for custom+USD mode).
    private func parsedUSDCents() -> Int64? {
        let raw = amountUSD.trimmingCharacters(in: .whitespaces)
        guard let usd = Double(raw), usd > 0 else { return nil }
        return Int64((usd * 100).rounded())
    }

    /// Build the order-mode cart payload from the editable rows, dropping blanks.
    private func buildCart() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for line in cart {
            let id = line.itemID.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, let qty = Int(line.quantity.trimmingCharacters(in: .whitespaces)), qty > 0 else {
                continue
            }
            out.append(["item_id": id, "quantity": qty])
        }
        return out
    }

    private func describe(_ r: ZuuppaCheckoutResult) -> String {
        switch r {
        case .settled(let s): return "Settled" + (s.map { " — \($0.destinationUi) \($0.asset)" } ?? "")
        case .expired: return "Expired"
        case .refunded: return "Refunded"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Small labeled text field used by the harness form.
private struct LabeledField: View {
    let label: String
    @Binding var text: String
    var mono: Bool = false
    var secure: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Group {
                if secure {
                    SecureField(label, text: $text)
                } else {
                    TextField(label, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(mono ? .system(.body, design: .monospaced) : .body)
        }
    }
}

// MARK: - Fixtures for offline (no-server) previews

extension ZuuppaIntent {
    /// A pending SOL intent with a fake client_secret — for the static previews
    /// below and as the harness's placeholder before creation.
    static let previewPending = ZuuppaIntent(
        id: "11111111-1111-1111-1111-111111111111",
        address: "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU",
        clientSecret: "cs_preview_only",
        mint: nil,
        mintDecimals: nil,
        expectedLamports: 10_000_000,
        status: "pending",
        receivedLamports: 0,
        reference: "preview-order"
    )

    /// A pending USD-priced intent ($12.50) with two accepted tokens and no locked
    /// asset yet — drives the token-select step preview.
    static let previewUsdUnlocked = ZuuppaIntent(
        id: "33333333-3333-3333-3333-333333333333",
        address: "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU",
        clientSecret: "cs_preview_only",
        mint: nil,
        mintDecimals: nil,
        expectedLamports: nil,
        status: "pending",
        receivedLamports: 0,
        reference: "preview-usd",
        mode: "custom",
        priceUsdCents: 1250,
        acceptedTokens: [
            ZuuppaAcceptedToken(kind: "sol"),
            ZuuppaAcceptedToken(kind: "spl", mint: harnessUSDCMint, decimals: 6, symbol: "USDC"),
        ]
    )
}

extension ZuuppaStatus {
    /// Build a fixture status for previewing a specific phase offline.
    static func preview(action: String, message: String, settlement: ZuuppaSettlement? = nil) -> ZuuppaStatus {
        let json: [String: Any] = [
            "id": "22222222-2222-2222-2222-222222222222",
            "address": "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU",
            "status": action == "swept" ? "swept" : "pending",
            "received_lamports": 0,
            "action": action,
            "message": message,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(ZuuppaStatus.self, from: data)
    }
}

// MARK: - Previews

// Interactive: point it at your local server and run the whole flow. Requires
// the server running (`cargo run` in zuuppa/server) and a valid sk_ key.
#Preview("Harness (live server)") {
    ZuuppaPreviewHarness(baseURL: "http://localhost:8080", apiKey: "")
}

// Static: the checkout screen itself, waiting for payment. No server needed —
// polling will just fail softly against the fake client_secret; the layout
// renders. Good for iterating on UI.
#Preview("Checkout — awaiting (offline)") {
    ZuuppaCheckoutScreen(intent: .previewPending)
}

// Static: the token-select step for a USD-priced intent. No server needed — the
// per-token quote amounts stay blank (the quote call fails softly against the fake
// client_secret); the token rows + USD total render.
#Preview("Checkout — token select (offline)") {
    ZuuppaCheckoutScreen(intent: .previewUsdUnlocked)
}

// Static: QR-only variant (no wallet button).
#Preview("Checkout — QR only (offline)") {
    var cfg = ZuuppaConfig.default
    cfg.showPayWithWallet = false
    return ZuuppaCheckoutScreen(intent: .previewPending, config: cfg)
}

// Static: the buyer-details step (name required, email required, address
// optional). No server needed — the layout renders; Continue would attempt a
// submit against the fake client_secret.
#Preview("Checkout — details step (offline)") {
    var cfg = ZuuppaConfig.default
    cfg.fields = ZuuppaCheckoutFields(name: .required, email: .required, address: .optional)
    return ZuuppaCheckoutScreen(intent: .previewPending, config: cfg)
}
#endif
