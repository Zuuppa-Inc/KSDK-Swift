#if canImport(UIKit)
import SwiftUI

/// The buyer-details step shown before payment when `config.fields` collects
/// anything. Renders only the enabled fields (name / email / address), marks
/// required ones, and drives `model.submitDetails` on continue. International
/// address entry uses a searchable country picker.
struct KaanjuDetailsView: View {
    @Bindable var model: CheckoutModel
    /// Called once details are accepted (submitted or skipped) to advance to pay.
    let onContinue: () -> Void

    private var fields: KaanjuCheckoutFields { model.config.fields }

    var body: some View {
        VStack(spacing: 20) {
            Text("Your details")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 16) {
                if fields.name.isShown { nameFields }
                if fields.email.isShown { emailField }
                if fields.address.isShown { addressFields }
            }

            if let err = model.errorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(KaanjuColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            continueButton

            if model.detailsAreSkippable {
                Button("Skip") {
                    model.skipDetails()
                    onContinue()
                }
                .font(.subheadline)
                .foregroundStyle(KaanjuColor.textSecondary)
            }
        }
    }

    // MARK: - Name

    private var nameFields: some View {
        HStack(spacing: 12) {
            field("First name", required: fields.name.isRequired, text: bind(\.firstName))
                .textContentType(.givenName)
            field("Last name", required: fields.name.isRequired, text: bind(\.lastName))
                .textContentType(.familyName)
        }
    }

    // MARK: - Email

    private var emailField: some View {
        field("Email", required: fields.email.isRequired, text: bind(\.email))
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    // MARK: - Address

    private var addressFields: some View {
        VStack(spacing: 12) {
            KaanjuCountryPicker(
                selectedCode: bindAddress(\.country),
                required: fields.address.isRequired
            )
            field("Address line 1", required: fields.address.isRequired, text: bindAddress(\.line1))
                .textContentType(.fullStreetAddress)
            field("Address line 2 (optional)", required: false, text: bindAddress(\.line2))
            HStack(spacing: 12) {
                field("City", required: fields.address.isRequired, text: bindAddress(\.city))
                    .textContentType(.addressCity)
                field("State / region", required: false, text: bindAddress(\.state))
                    .textContentType(.addressState)
            }
            field("Postal code", required: fields.address.isRequired, text: bindAddress(\.postalCode))
                .textContentType(.postalCode)
        }
    }

    // MARK: - Continue

    private var continueButton: some View {
        Button(action: { model.submitDetails(onDone: onContinue) }) {
            HStack {
                if model.isSubmittingDetails { ProgressView().tint(KaanjuColor.accentText) }
                Text(model.isSubmittingDetails ? "Saving…" : "Continue")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(KaanjuColor.accent)
            .foregroundStyle(KaanjuColor.accentText)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(model.isSubmittingDetails)
    }

    // MARK: - Field helpers

    private func field(_ label: String, required: Bool, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text(label).font(.caption).foregroundStyle(KaanjuColor.textSecondary)
                if required { Text("*").font(.caption).foregroundStyle(KaanjuColor.danger) }
            }
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Bind a top-level optional String field of the model's details to a
    /// non-optional String the TextField wants (nil <-> "").
    private func bind(_ key: WritableKeyPath<KaanjuCustomerDetails, String?>) -> Binding<String> {
        Binding(
            get: { model.details[keyPath: key] ?? "" },
            set: { model.details[keyPath: key] = $0.isEmpty ? nil : $0 }
        )
    }

    /// Same, for a field nested on the address (creating the address on demand).
    private func bindAddress(_ key: WritableKeyPath<KaanjuAddress, String?>) -> Binding<String> {
        Binding(
            get: { model.details.address?[keyPath: key] ?? "" },
            set: {
                var addr = model.details.address ?? KaanjuAddress()
                addr[keyPath: key] = $0.isEmpty ? nil : $0
                model.details.address = addr
            }
        )
    }
}

/// A searchable, global country selector. Shows the selected country's flag +
/// name; tapping opens a searchable list of every ISO country (localized).
struct KaanjuCountryPicker: View {
    @Binding var selectedCode: String
    let required: Bool

    @State private var showList = false

    private var selected: KaanjuCountry? { KaanjuCountries.country(for: selectedCode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text("Country").font(.caption).foregroundStyle(KaanjuColor.textSecondary)
                if required { Text("*").font(.caption).foregroundStyle(KaanjuColor.danger) }
            }
            Button { showList = true } label: {
                HStack {
                    if let c = selected {
                        Text(c.flag)
                        Text(c.name).foregroundStyle(KaanjuColor.textPrimary)
                    } else {
                        Text("Select country").foregroundStyle(KaanjuColor.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(KaanjuColor.textSecondary)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 8).stroke(KaanjuColor.border))
            }
        }
        .sheet(isPresented: $showList) {
            KaanjuCountryList(selectedCode: $selectedCode)
        }
    }
}

/// The searchable country list presented by the picker.
private struct KaanjuCountryList: View {
    @Binding var selectedCode: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [KaanjuCountry] {
        let all = KaanjuCountries.all
        let q = query.trimmed
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.code.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List(results) { country in
                Button {
                    selectedCode = country.code
                    dismiss()
                } label: {
                    HStack {
                        Text(country.flag)
                        Text(country.name).foregroundStyle(KaanjuColor.textPrimary)
                        Spacer()
                        if country.code == selectedCode.uppercased() {
                            Image(systemName: "checkmark").foregroundStyle(KaanjuColor.accent)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search countries")
            .navigationTitle("Country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
#endif
