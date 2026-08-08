#if DEBUG && canImport(UIKit)
import SwiftUI

/// **DEBUG-ONLY interactive harness** for exercising the full checkout flow
/// against a running server (e.g. your local `cargo run`), end to end:
///
///   enter local URL + sk_ key + amount → Create intent → the real
///   `KaanjuCheckoutScreen` opens (QR + Pay-with-wallet + live polling) → pay
///   from a wallet (or simulate on-chain) → watch it settle.
///
/// It stands in for the piece that is normally your backend (creating the intent
/// with the secret key), so no server code of your own is needed to try it.
///
/// Use it from your app during development:
/// ```swift
/// #if DEBUG
/// KaanjuPreviewHarness()
/// #endif
/// ```
/// or just open the `#Preview`s at the bottom of this file in Xcode.
public struct KaanjuPreviewHarness: View {
    // Simulator reaches the host Mac's localhost directly; a device needs the
    // Mac's LAN IP here instead.
    @State private var baseURL: String
    @State private var apiKey: String
    @State private var amountSOL: String = "0.01"
    @State private var mint: String = ""
    @State private var reference: String = ""

    // Which buyer details to collect, so the details step is testable end to end.
    @State private var nameReq: KaanjuFieldRequirement = .off
    @State private var emailReq: KaanjuFieldRequirement = .off
    @State private var addressReq: KaanjuFieldRequirement = .off

    @State private var creating = false
    @State private var error: String?
    @State private var intent: KaanjuIntent?
    @State private var showCheckout = false
    @State private var lastResult: KaanjuCheckoutResult?

    /// Optional wallet callback. Defaults to a stub that just waits, so the
    /// button is exercisable even without a real wallet — the buyer can pay by
    /// scanning the QR and polling will still settle it.
    private let onPayWithWallet: (@Sendable (KaanjuIntent) async throws -> Void)?

    public init(
        baseURL: String = "http://localhost:8080",
        apiKey: String = "sk_live_4A4zgjuXxCiwqkEy16jb2AghGEfuHBH5L",
        onPayWithWallet: (@Sendable (KaanjuIntent) async throws -> Void)? = nil
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

                Section("Intent") {
                    LabeledField(label: mint.isEmpty ? "Amount (SOL)" : "Amount (base units)", text: $amountSOL, mono: true)
                    LabeledField(label: "SPL mint (blank = SOL)", text: $mint, mono: true)
                    LabeledField(label: "Reference (optional)", text: $reference)
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
            .navigationTitle("Kaanju Test Harness")
        }
        .kaanjuCheckout(
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

    private var harnessConfig: KaanjuConfig {
        var c = KaanjuConfig.default
        if let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)) {
            c.apiBaseURL = url
        }
        c.pollInterval = 2.0
        c.fields = KaanjuCheckoutFields(name: nameReq, email: emailReq, address: addressReq)
        return c
    }

    private func requirementPicker(
        _ label: String,
        selection: Binding<KaanjuFieldRequirement>
    ) -> some View {
        Picker(label, selection: selection) {
            Text("Off").tag(KaanjuFieldRequirement.off)
            Text("Optional").tag(KaanjuFieldRequirement.optional)
            Text("Required").tag(KaanjuFieldRequirement.required)
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
        let client = KaanjuDebugClient(baseURL: url, apiKey: apiKey.trimmingCharacters(in: .whitespaces))
        let expected = parsedExpected()
        do {
            let created = try await client.createIntent(
                expectedLamports: expected,
                mint: mint.isEmpty ? nil : mint,
                reference: reference.isEmpty ? nil : reference
            )
            guard created.clientSecret != nil else {
                error = "Server returned no client_secret. (Reusing a reference returns the existing intent without one — change the reference.)"
                return
            }
            intent = created
            showCheckout = true
        } catch {
            self.error = (error as? KaanjuError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// SOL amount → lamports, or raw base units when a mint is set.
    private func parsedExpected() -> Int64? {
        let raw = amountSOL.trimmingCharacters(in: .whitespaces)
        if mint.isEmpty {
            guard let sol = Double(raw), sol > 0 else { return nil }
            return Int64((sol * 1_000_000_000).rounded())
        } else {
            return Int64(raw)
        }
    }

    private func describe(_ r: KaanjuCheckoutResult) -> String {
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

extension KaanjuIntent {
    /// A pending SOL intent with a fake client_secret — for the static previews
    /// below and as the harness's placeholder before creation.
    static let previewPending = KaanjuIntent(
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
}

extension KaanjuStatus {
    /// Build a fixture status for previewing a specific phase offline.
    static func preview(action: String, message: String, settlement: KaanjuSettlement? = nil) -> KaanjuStatus {
        let json: [String: Any] = [
            "id": "22222222-2222-2222-2222-222222222222",
            "address": "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU",
            "status": action == "swept" ? "swept" : "pending",
            "received_lamports": 0,
            "action": action,
            "message": message,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(KaanjuStatus.self, from: data)
    }
}

// MARK: - Previews

// Interactive: point it at your local server and run the whole flow. Requires
// the server running (`cargo run` in kaanju/server) and a valid sk_ key.
#Preview("Harness (live server)") {
    KaanjuPreviewHarness(baseURL: "http://localhost:8080", apiKey: "sk_live_4A4zgjuXxCiwqkEy16jb2AghGEfuHBH5L")
}

// Static: the checkout screen itself, waiting for payment. No server needed —
// polling will just fail softly against the fake client_secret; the layout
// renders. Good for iterating on UI.
#Preview("Checkout — awaiting (offline)") {
    KaanjuCheckoutScreen(intent: .previewPending)
}

// Static: QR-only variant (no wallet button).
#Preview("Checkout — QR only (offline)") {
    var cfg = KaanjuConfig.default
    cfg.showPayWithWallet = false
    return KaanjuCheckoutScreen(intent: .previewPending, config: cfg)
}

// Static: the buyer-details step (name required, email required, address
// optional). No server needed — the layout renders; Continue would attempt a
// submit against the fake client_secret.
#Preview("Checkout — details step (offline)") {
    var cfg = KaanjuConfig.default
    cfg.fields = KaanjuCheckoutFields(name: .required, email: .required, address: .optional)
    return KaanjuCheckoutScreen(intent: .previewPending, config: cfg)
}
#endif
