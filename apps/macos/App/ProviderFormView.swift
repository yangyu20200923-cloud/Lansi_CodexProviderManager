import SwiftUI
import ProviderCore

struct ProviderFormView: View {
    @ObservedObject var model: ProviderManagerViewModel
    @EnvironmentObject private var localization: LocalizationController
    @State private var showingClearCatalogConfirmation = false

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
        .alert(
            localization.string("model_list.clear_confirm_title"),
            isPresented: $showingClearCatalogConfirmation
        ) {
            Button(localization.string("button.cancel"), role: .cancel) {}
            Button(localization.string("model_list.clear"), role: .destructive) { model.clearModelCatalog() }
        } message: {
            Text(localization.string("model_list.clear_confirm_message"))
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
            if !model.selectedProfile.enabled {
                Label(localization.string("status.disabled"), systemImage: "pause.circle.fill").foregroundStyle(.orange)
            }
        }
    }

    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
            GridRow { label("field.display_name"); TextField(localization.string("placeholder.name"), text: binding(\.displayName)); defaultText(ProviderDefaults.profile(for: model.selectedID).displayName) }
            GridRow { label("field.enabled"); Toggle("", isOn: binding(\.enabled)).labelsHidden().disabled(model.selectedProfile.isBuiltIn); Color.clear.frame(minWidth: 0, idealWidth: 180, maxWidth: 180).frame(height: 1) }
            GridRow { label("field.auth_mode"); authModeControl; defaultText(localization.string(model.selectedProfile.requiresAPIKey ? "auth.api_key" : "auth.chatgpt_login")) }
            GridRow { label("field.base_url"); TextField(localization.string("placeholder.https"), text: optionalBinding(\.baseURL)).disabled(model.selectedProfile.isBuiltIn || !model.selectedProfile.requiresAPIKey); defaultText(ProviderDefaults.profile(for: model.selectedID).baseURL ?? localization.string("default.managed_chatgpt")) }
            GridRow { label("field.api_type"); apiTypeControl; defaultText(ProviderDefaults.profile(for: model.selectedID).wireAPI ?? localization.string("default.built_in")) }
            GridRow { label("field.api_key_environment"); TextField("EXAMPLE_PROVIDER_API_KEY", text: optionalBinding(\.apiKeyEnvironment)).disabled(model.selectedProfile.isBuiltIn || !model.selectedProfile.requiresAPIKey); Color.clear.frame(minWidth: 0, idealWidth: 180, maxWidth: 180).frame(height: 1) }
            GridRow { label("field.model"); modelControl; defaultText(ProviderDefaults.profile(for: model.selectedID).model ?? localization.string("default.chatgpt")) }
            GridRow {
                label("field.model_list")
                modelCatalogControl
                SelectableLabel(
                    text: localization.string("model_list.help"),
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                    textColor: .secondaryLabelColor,
                    maximumNumberOfLines: 2
                )
                .frame(minWidth: 0, idealWidth: 180, maxWidth: 180, alignment: .leading)
            }
            GridRow { label("field.reasoning_effort"); reasoningEffortControl; Color.clear.frame(minWidth: 0, idealWidth: 180, maxWidth: 180).frame(height: 1) }
            GridRow { label("field.review_model"); TextField(localization.string("placeholder.review_model"), text: optionalBinding(\.reviewModel)).disabled(model.selectedProfile.isBuiltIn); Color.clear.frame(minWidth: 0, idealWidth: 180, maxWidth: 180).frame(height: 1) }
            GridRow { label("field.config_overrides"); Text(localization.string("config_overrides.none")).foregroundStyle(.secondary); Color.clear.frame(minWidth: 0, idealWidth: 180, maxWidth: 180).frame(height: 1) }
            GridRow {
                label("field.api_key")
                SecureField(
                    localization.string(
                        model.selectedProfile.hasStoredKey
                            ? (model.isIsolatedAcceptance ? "key.saved_isolated_placeholder" : "key.saved_placeholder")
                            : "key.enter_placeholder"
                    ),
                    text: $model.apiKeyDraft
                )
                .disabled(model.selectedProfile.isBuiltIn || !model.selectedProfile.requiresAPIKey)
                HStack {
                    Text(localization.string(
                        !model.selectedProfile.requiresAPIKey
                            ? "key.chatgpt_login"
                            : (model.selectedProfile.hasStoredKey
                                ? (model.isIsolatedAcceptance ? "key.saved_isolated" : "key.saved")
                                : "key.not_saved")
                    ))
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.selectedProfile.isBuiltIn,
                       model.selectedProfile.requiresAPIKey,
                       !model.isIsolatedAcceptance,
                       EnvironmentKeyImporter().candidate(for: model.selectedProfile.apiKeyEnvironment, provider: model.selectedID) != nil {
                        Button(localization.string("button.import")) { model.importEnvironmentKey() }.controlSize(.small)
                    }
                }
            }
            GridRow {
                Color.clear.frame(width: 110, height: 1)
                Button { Task { await model.testConnection() } } label: { Label(localization.string("button.test_connection"), systemImage: "network") }
                    .disabled(model.isBusy || model.isIsolatedAcceptance || model.selectedProfile.isBuiltIn || !model.selectedProfile.requiresAPIKey || !model.selectedProfile.enabled)
                Color.clear.frame(minWidth: 0, idealWidth: 180, maxWidth: 180).frame(height: 1)
            }
        }
        .gridColumnAlignment(.leading)
        .textFieldStyle(.roundedBorder)
    }

    private var validation: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(model.validationIssues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    SelectableLabel(
                        text: localization.validation(issue.message),
                        font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                        textColor: .systemRed,
                        maximumNumberOfLines: 3
                    )
                }
            }
        }
    }

    private var apiTypeControl: some View {
        HStack(spacing: 8) {
            Text(localization.string("api.responses"))
                .frame(width: 155, alignment: .leading)
            if !model.selectedProfile.isBuiltIn,
               model.selectedProfile.wireAPI?.trimmingCharacters(in: .whitespacesAndNewlines) != "responses" {
                Button(localization.string("button.use_responses")) {
                    model.selectedProfile.wireAPI = "responses"
                    model.profileDidChange()
                }
                .controlSize(.small)
            }
            Text(localization.string("api.responses_requirement"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelControl: some View {
        HStack(spacing: 8) {
            TextField(localization.string("placeholder.model"), text: optionalBinding(\.model))
                .disabled(model.selectedProfile.isBuiltIn)
            if !model.selectedProfile.models.isEmpty {
                Picker("", selection: optionalBinding(\.model)) {
                    ForEach(model.selectedProfile.models, id: \.self) { value in
                        Text(value).tag(Optional(value))
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }
        }
    }

    private var modelCatalogControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            managedSection
            Divider()
            upstreamSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var managedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(localization.string("model_list.managed_title")).font(.headline)
                Spacer()
                Text(localization.string("model_list.count", model.selectedProfile.models.count, "\(ProviderManagerViewModel.maxCatalogModels)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(localization.string("model_list.managed_help"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(localization.string("model_list.add_placeholder"), text: $model.modelCatalogDraft)
                    .textFieldStyle(.roundedBorder)
                Button(localization.string("model_list.add")) {
                    let names = model.modelCatalogDraft
                        .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    guard !names.isEmpty else { return }
                    model.addModelsToCatalog(names)
                    model.modelCatalogDraft = ""
                }
                .controlSize(.small)
                .disabled(model.selectedProfile.isBuiltIn)
            }
            HStack(spacing: 8) {
                TextField(localization.string("placeholder.search_models"), text: $model.modelSearchQuery)
                if let current = model.selectedProfile.model {
                    Text(localization.string("model_list.current_model", current))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if model.filteredManagedModels.isEmpty {
                Text(localization.string("model_list.managed_empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.filteredManagedModels, id: \.self) { value in
                            modelRow(value)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                HStack(spacing: 8) {
                    Button(localization.string("model_list.select_all")) { model.selectAllManaged() }
                        .controlSize(.small)
                    Button(localization.string("model_list.remove_selected")) {
                        model.removeModelsFromCatalog(Array(model.managedModelSelection))
                    }
                    .controlSize(.small)
                    .disabled(model.managedModelSelection.isEmpty)
                    Spacer()
                    Button(localization.string("model_list.clear"), role: .destructive) { showingClearCatalogConfirmation = true }
                        .controlSize(.small)
                        .disabled(model.selectedProfile.models.isEmpty)
                }
            }
        }
    }

    private func modelRow(_ value: String) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { model.managedModelSelection.contains(value) },
                set: { _ in model.toggleManagedSelection(value) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            Button {
                model.selectModel(value)
            } label: {
                HStack {
                    Text(value).lineLimit(1)
                    Spacer()
                    if model.selectedProfile.model == value {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(model.selectedProfile.model == value ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Button {
                model.removeModelFromCatalog(value)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(localization.string("model_list.remove"))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
    }

    private var upstreamSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(localization.string("model_list.upstream_title")).font(.headline)
                Spacer()
                Button {
                    Task { await model.fetchModelsFromUpstream() }
                } label: {
                    Label(localization.string("button.fetch_models"), systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
                .disabled(model.isBusy || model.isFetchingModels || model.isIsolatedAcceptance || model.selectedProfile.isBuiltIn || !model.selectedProfile.requiresAPIKey)
                if model.isFetchingModels {
                    Button(localization.string("model_list.cancel_fetch")) { model.cancelModelFetch() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    ProgressView().controlSize(.small)
                }
            }
            Text(localization.string("model_list.upstream_help"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !model.upstreamModels.isEmpty {
                HStack(spacing: 8) {
                    Label(
                        localization.string("model_list.fetched_not_written", model.upstreamModels.count),
                        systemImage: "tray.and.arrow.down"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(localization.string("model_list.adopt_all")) { model.adoptAllUpstreamModels() }
                        .controlSize(.small)
                        .disabled(model.isUpstreamFullyAdopted || model.isFetchingModels)
                    Button(localization.string("model_list.ignore")) { model.ignoreUpstreamModels() }
                        .controlSize(.small)
                }
                if model.filteredUpstreamModels.isEmpty {
                    Text(localization.string("model_list.upstream_none"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.filteredUpstreamModels, id: \.self) { value in
                                upstreamRow(value)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    HStack(spacing: 8) {
                        Button(localization.string("model_list.select_all")) { model.selectAllUpstream() }
                            .controlSize(.small)
                        Button(localization.string("model_list.add_selected")) {
                            model.addModelsToCatalog(Array(model.upstreamModelSelection))
                        }
                        .controlSize(.small)
                        .disabled(model.upstreamModelSelection.isEmpty)
                    }
                }
            } else if !model.isFetchingModels {
                Text(localization.string("model_list.upstream_empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func upstreamRow(_ value: String) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { model.upstreamModelSelection.contains(value) },
                set: { _ in model.toggleUpstreamSelection(value) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            Text(value).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if model.selectedProfile.models.contains(value) {
                Label(localization.string("model_list.already_added"), systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(localization.string("model_list.add_to_list")) { model.addModelToCatalog(value) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
    }

    private var reasoningEffortControl: some View {
        Picker("", selection: Binding<String?>(
            get: { model.selectedProfile.reasoningEffort },
            set: {
                model.selectedProfile.reasoningEffort = $0
                model.profileDidChange()
            }
        )) {
            Text(localization.string("model.reasoning_default")).tag(String?.none)
            ForEach(Self.reasoningEffortOptions, id: \.self) { option in
                Text(option).tag(Optional(option))
            }
        }
        .labelsHidden()
        .frame(width: 180)
        .disabled(model.selectedProfile.isBuiltIn)
    }

    private static let reasoningEffortOptions = ["low", "medium", "high", "xhigh", "max", "ultra"]

    private var authModeControl: some View {
        Picker("", selection: binding(\.authMode)) {
            Text(localization.string("auth.chatgpt_login")).tag(ProviderAuthMode.chatGPTLogin)
            Text(localization.string("auth.api_key")).tag(ProviderAuthMode.apiKey)
        }
        .labelsHidden()
        .frame(width: 180)
        .disabled(model.selectedProfile.isBuiltIn)
    }

    private func label(_ key: String) -> some View { Text(localization.string(key)).frame(width: 110, alignment: .trailing) }
    private func defaultText(_ text: String) -> some View {
        SelectableLabel(
            text: text,
            font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            textColor: .secondaryLabelColor,
            maximumNumberOfLines: 2,
            lineBreakMode: .byTruncatingTail
        )
        .frame(minWidth: 0, idealWidth: 180, maxWidth: 180, alignment: .leading)
    }

    private func binding(_ keyPath: WritableKeyPath<ProviderProfile, String>) -> Binding<String> {
        Binding(get: { model.selectedProfile[keyPath: keyPath] }, set: {
            model.selectedProfile[keyPath: keyPath] = $0
            model.profileDidChange()
        })
    }
    private func binding(_ keyPath: WritableKeyPath<ProviderProfile, Bool>) -> Binding<Bool> {
        Binding(get: { model.selectedProfile[keyPath: keyPath] }, set: {
            model.selectedProfile[keyPath: keyPath] = $0
            model.profileDidChange()
        })
    }
    private func binding(_ keyPath: WritableKeyPath<ProviderProfile, ProviderAuthMode>) -> Binding<ProviderAuthMode> {
        Binding(get: { model.selectedProfile[keyPath: keyPath] }, set: {
            model.selectedProfile[keyPath: keyPath] = $0
            model.profileDidChange()
        })
    }
    private func optionalBinding(_ keyPath: WritableKeyPath<ProviderProfile, String?>) -> Binding<String> {
        Binding(get: { model.selectedProfile[keyPath: keyPath] ?? "" }, set: {
            model.selectedProfile[keyPath: keyPath] = $0
            model.profileDidChange()
        })
    }

}
