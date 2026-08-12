#if canImport(UIKit)
import SwiftUI

/// The buyer-details step shown before payment when `config.fields` collects
/// anything. Renders only the enabled fields (name / email / address), marks
/// required ones, and drives `model.submitDetails` on continue. International
/// address entry uses a searchable country picker.
struct ZuuppaDetailsView: View {
    @Bindable var model: CheckoutModel
    /// Called once details are accepted (submitted or skipped) to advance to pay.
    let onContinue: () -> Void

    private var fields: ZuuppaCheckoutFields { model.config.fields }

    /// The country's address format (which fields exist, their labels, and which
    /// are required) — re-derived when the buyer changes country.
    private var addressFormat: ZuuppaAddressFormat {
        ZuuppaAddressFormat.resolve(for: model.details.address?.country)
    }

    /// Natural (unclamped) height of the scrollable fields, and of the footer, so
    /// the sheet can size to content — small for just a name, taller for a full
    /// address — instead of always filling the screen. When the sum exceeds the
    /// sheet's max the detent clamps and the fields scroll.
    @State private var fieldsHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    /// Whether to show the "Saving…" spinner. Gated behind a short delay so a fast
    /// submit (the common case) goes straight Continue → pay with no flash; the
    /// spinner only appears if the request is actually slow.
    @State private var showSaving = false
    /// How long a submit must be in flight before we reveal the spinner.
    private let savingSpinnerDelay: Duration = .milliseconds(400)

    var body: some View {
        // Scrollable fields above a Continue button pinned to the bottom.
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    if fields.name.isShown { nameFields }
                    if fields.email.isShown { emailField }
                    if fields.address.isShown { addressFields }
                }
                // Top spacing under the header + spacing above the pinned footer.
                // Kept inside the measured content so the sheet's detent is exact.
                .padding(.top, 20)
                .padding(.bottom, 16)
                // Measure the fields' natural height (ScrollView content size).
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: FieldsHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)

            footer
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: FooterHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .onPreferenceChange(FieldsHeightKey.self) { fieldsHeight = $0 }
        .onPreferenceChange(FooterHeightKey.self) { footerHeight = $0 }
        // Report the combined natural height so the sheet sizes to fit this step.
        .background(
            Color.clear.preference(key: ContentHeightKey.self, value: fieldsHeight + footerHeight)
        )
    }

    // MARK: - Name

    private var nameFields: some View {
        HStack(alignment: .top, spacing: 10) {
            field("First name", required: fields.name.isRequired, placeholder: "First name", text: bind(\.firstName))
                .textContentType(.givenName)
            field("Last name", required: fields.name.isRequired, placeholder: "Last name", text: bind(\.lastName))
                .textContentType(.familyName)
        }
    }

    // MARK: - Email

    private var emailField: some View {
        field("Email", required: fields.email.isRequired, placeholder: "you@example.com", text: bind(\.email))
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    // MARK: - Address

    /// The address fields, adapting to the selected country: the state field only
    /// appears for countries that collect one (with its local label), and the
    /// postal field is hidden for countries without a postal-code system.
    private var addressFields: some View {
        let fmt = addressFormat
        return VStack(spacing: 12) {
            ZuuppaCountryPicker(
                selectedCode: bindAddress(\.country),
                required: fields.address.isRequired
            )
            // A single "Street" label over two stacked lines: the street/PO box and
            // the (optional) apartment/suite.
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Street", required: fields.address.isRequired)
                filledField("Street address or P.O. Box", text: bindAddress(\.line1))
                    .textContentType(.fullStreetAddress)
                filledField("Apartment, suite, etc. (optional)", text: bindAddress(\.line2))
            }
            if fmt.showState {
                HStack(alignment: .top, spacing: 10) {
                    field(fmt.cityLabel, required: fields.address.isRequired, placeholder: fmt.cityLabel, text: bindAddress(\.city))
                        .textContentType(.addressCity)
                    field(fmt.stateLabel, required: fields.address.isRequired && fmt.stateRequired, placeholder: fmt.stateLabel, text: bindAddress(\.state))
                        .textContentType(.addressState)
                }
            } else {
                field(fmt.cityLabel, required: fields.address.isRequired, placeholder: fmt.cityLabel, text: bindAddress(\.city))
                    .textContentType(.addressCity)
            }
            if fmt.showPostal {
                field(fmt.postalLabel, required: fields.address.isRequired, placeholder: fmt.postalLabel, text: bindAddress(\.postalCode))
                    .textContentType(.postalCode)
            }
        }
    }

    // MARK: - Footer

    /// The pinned bottom bar: the validation error (if any), the Continue button,
    /// and an optional Skip link. Stays fixed while the fields above scroll.
    private var footer: some View {
        VStack(spacing: 10) {
            if let err = model.errorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(ZuuppaColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: { model.submitDetails(onDone: onContinue) }) {
                HStack {
                    if showSaving { ProgressView().tint(ZuuppaColor.accentText) }
                    Text(showSaving ? "Saving…" : "Continue")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(ZuuppaColor.accent)
                .foregroundStyle(ZuuppaColor.accentText)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(model.isSubmittingDetails)
            // Reveal "Saving…" only after the submit has been in flight past a short
            // delay — a fast submit finishes first, so the button stays "Continue"
            // and the step swaps to pay with no spinner flash. The switch itself is
            // unanimated so it never cross-fades into the step transition.
            .animation(nil, value: showSaving)
            .task(id: model.isSubmittingDetails) {
                guard model.isSubmittingDetails else { showSaving = false; return }
                try? await Task.sleep(for: savingSpinnerDelay)
                guard !Task.isCancelled else { return }
                showSaving = true
            }

            if model.detailsAreSkippable {
                Button("Skip") {
                    model.skipDetails()
                    onContinue()
                }
                .font(.subheadline)
                .foregroundStyle(ZuuppaColor.textSecondary)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(ZuuppaColor.background)
    }

    // MARK: - Field helpers

    /// A labelled input: a label (with a red `*` when required) over a filled,
    /// borderless field. Fonts match the token-name style on the payment screen.
    private func field(_ label: String, required: Bool, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label, required: required)
            filledField(placeholder, text: text)
        }
    }

    /// A field label (matching the token-name weight) with an optional red marker.
    private func fieldLabel(_ label: String, required: Bool) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.body.weight(.semibold))
                .foregroundStyle(ZuuppaColor.textPrimary)
            if required {
                Text("*").font(.body.weight(.semibold)).foregroundStyle(ZuuppaColor.danger)
            }
        }
    }

    /// A filled, borderless text field with placeholder text: light-gray fill,
    /// rounded corners, compact height.
    private func filledField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(ZuuppaColor.textPrimary)
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(ZuuppaColor.surface))
    }

    /// Bind a top-level optional String field of the model's details to a
    /// non-optional String the TextField wants (nil <-> "").
    private func bind(_ key: WritableKeyPath<ZuuppaCustomerDetails, String?>) -> Binding<String> {
        Binding(
            get: { model.details[keyPath: key] ?? "" },
            set: { model.details[keyPath: key] = $0.isEmpty ? nil : $0 }
        )
    }

    /// Same, for a field nested on the address (creating the address on demand).
    private func bindAddress(_ key: WritableKeyPath<ZuuppaAddress, String?>) -> Binding<String> {
        Binding(
            get: { model.details.address?[keyPath: key] ?? "" },
            set: {
                var addr = model.details.address ?? ZuuppaAddress()
                addr[keyPath: key] = $0.isEmpty ? nil : $0
                model.details.address = addr
            }
        )
    }
}

/// A searchable, global country selector. Shows the selected country's flag +
/// name; tapping opens a searchable list of every ISO country (localized).
struct ZuuppaCountryPicker: View {
    @Binding var selectedCode: String
    let required: Bool

    @State private var showList = false

    private var selected: ZuuppaCountry? { ZuuppaCountries.country(for: selectedCode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                Text("Country")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ZuuppaColor.textPrimary)
                if required {
                    Text("*").font(.body.weight(.semibold)).foregroundStyle(ZuuppaColor.danger)
                }
            }
            Button { showList = true } label: {
                HStack(spacing: 8) {
                    if let c = selected {
                        Text(c.flag)
                        Text(c.name)
                            .font(.body)
                            .foregroundStyle(ZuuppaColor.textPrimary)
                    } else {
                        Text("Select country")
                            .font(.body)
                            .foregroundStyle(ZuuppaColor.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.subheadline)
                        .foregroundStyle(ZuuppaColor.textSecondary)
                }
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(ZuuppaColor.surface))
            }
        }
        .sheet(isPresented: $showList) {
            ZuuppaCountryList(selectedCode: $selectedCode)
        }
    }
}

/// The searchable country list presented by the picker.
private struct ZuuppaCountryList: View {
    @Binding var selectedCode: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [ZuuppaCountry] {
        let all = ZuuppaCountries.all
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
                        Text(country.name).foregroundStyle(ZuuppaColor.textPrimary)
                        Spacer()
                        if country.code == selectedCode.uppercased() {
                            Image(systemName: "checkmark").foregroundStyle(ZuuppaColor.accent)
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

/// Natural height of the scrollable fields, used (with the footer) to size the
/// details sheet to its content.
private struct FieldsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Natural height of the pinned footer (error + Continue + optional Skip).
private struct FooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
