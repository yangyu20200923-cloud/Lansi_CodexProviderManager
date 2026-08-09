import SwiftUI
import ProviderCore

struct ProviderFormView: View {
    @ObservedObject var model: ProviderManagerViewModel
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                fields
                if !model.validationIssues.isEmpty { validation }
                StatusSummaryView(model: model)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.selectedProfile.displayName).font(.title2).fontWeight(.semibold)
                Text(localization.string(model.selectedID == .openAI ? "provider.openai.subtitle" : "provider.api.subtitle"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.profileSet.activeProvider == model.selectedID {
                Label(localization.string("status.active"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
            GridRow { label("field.display_name"); TextField(localization.string("placeholder.name"), text: binding(\.displayName)); defaultText(ProviderDefaults.profile(for: model.selectedID).displayName) }
            GridRow { label("field.base_url"); TextField(localization.string("placeholder.https"), text: optionalBinding(\.baseURL)).disabled(model.selectedProfile.isBuiltIn); defaultText(ProviderDefaults.profile(for: model.selectedID).baseURL ?? localization.string("default.managed_chatgpt")) }
            GridRow { label("field.api_type"); apiTypeControl; defaultText(ProviderDefaults.profile(for: model.selectedID).wireAPI ?? localization.string("default.built_in")) }
            GridRow { label("field.model"); TextField(localization.string("placeholder.model"), text: optionalBinding(\.model)).disabled(true); defaultText(ProviderDefaults.profile(for: model.selectedID).model ?? localization.string("default.chatgpt")) }
            GridRow {
                label("field.api_key")
                SecureField(localization.string(model.selectedProfile.hasStoredKey ? "key.saved_placeholder" : "key.enter_placeholder"), text: $model.apiKeyDraft).disabled(model.selectedProfile.isBuiltIn)
                HStack {
                    Text(localization.string(model.selectedProfile.isBuiltIn ? "key.chatgpt_login" : (model.selectedProfile.hasStoredKey ? "key.saved" : "key.not_saved")))
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.selectedProfile.isBuiltIn, EnvironmentKeyImporter().candidate(for: model.selectedID) != nil {
                        Button(localization.string("button.import")) { model.importEnvironmentKey() }.controlSize(.small)
                    }
                }
            }
            GridRow {
                Color.clear.frame(width: 110, height: 1)
                Button { Task { await model.testConnection() } } label: { Label(localization.string("button.test_connection"), systemImage: "network") }
                    .disabled(model.isBusy || model.selectedProfile.isBuiltIn)
                Color.clear.frame(width: 180, height: 1)
            }
        }
        .gridColumnAlignment(.leading)
        .textFieldStyle(.roundedBorder)
    }

    private var validation: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(model.validationIssues.enumerated()), id: \.offset) { _, issue in
                Label(localization.validation(issue.message), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
        }
    }

    private var apiTypeControl: some View {
        HStack(spacing: 8) {
            Picker("", selection: apiTypeSelection) {
                Text(localization.string("api.responses")).tag("responses")
                Text(localization.string("api.chat_completions")).tag("chat_completions")
                Text(localization.string("api.custom")).tag("custom")
            }
            .labelsHidden()
            .frame(width: 155)
            .disabled(model.selectedProfile.isBuiltIn)
            if apiTypeSelection.wrappedValue == "custom" {
                TextField(localization.string("api.custom_placeholder"), text: optionalBinding(\.wireAPI))
            }
        }
    }

    private var apiTypeSelection: Binding<String> {
        Binding(
            get: {
                let value = model.selectedProfile.wireAPI ?? ""
                return ["responses", "chat_completions"].contains(value) ? value : "custom"
            },
            set: { value in model.selectedProfile.wireAPI = value == "custom" ? "" : value }
        )
    }

    private func label(_ key: String) -> some View { Text(localization.string(key)).frame(width: 110, alignment: .trailing) }
    private func defaultText(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.secondary).frame(width: 180, alignment: .leading) }

    private func binding(_ keyPath: WritableKeyPath<ProviderProfile, String>) -> Binding<String> {
        Binding(get: { model.selectedProfile[keyPath: keyPath] }, set: { model.selectedProfile[keyPath: keyPath] = $0 })
    }
    private func optionalBinding(_ keyPath: WritableKeyPath<ProviderProfile, String?>) -> Binding<String> {
        Binding(get: { model.selectedProfile[keyPath: keyPath] ?? "" }, set: { model.selectedProfile[keyPath: keyPath] = $0 })
    }

}
