import SwiftUI
import ProviderCore

struct ProviderSidebar: View {
    @ObservedObject var model: ProviderManagerViewModel
    @EnvironmentObject private var localization: LocalizationController
    var onImport: () -> Void = {}
    var onExport: (ProviderProfile) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localization.string("app.title")).font(.headline)
                SelectableLabel(
                    text: localization.string(model.isIsolatedAcceptance ? "shared.temporary_codex_home" : "shared.codex_home"),
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                    textColor: .secondaryLabelColor,
                    maximumNumberOfLines: 1,
                    lineBreakMode: .byTruncatingTail
                )
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)

            VStack(spacing: 5) {
                ForEach(model.profileSet.profiles, id: \.id) { profile in
                    Button { model.select(profile.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon(for: profile.id)).frame(width: 20)
                            Text(profile.displayName).lineLimit(1)
                            Spacer()
                            if !profile.enabled {
                                Text(localization.string("status.disabled"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if model.profileSet.activeProvider == profile.id {
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                            }
                        }
                        .padding(.horizontal, 12).frame(height: 42)
                        .background(model.selectedID == profile.id ? Color.accentColor.opacity(0.14) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !profile.isBuiltIn {
                            Button(localization.string("button.copy_to_clipboard")) {
                                model.select(profile.id)
                                model.copySelectedProfileToClipboard()
                            }
                            Button(localization.string("button.copy_provider")) {
                                model.select(profile.id)
                                model.duplicateSelectedProfile()
                            }
                            Button(localization.string("button.export_provider")) {
                                model.select(profile.id)
                                onExport(profile)
                            }
                        }
                        Button(localization.string("button.paste_provider")) {
                            model.pasteProfileFromClipboard()
                        }
                    }
                }
            }
            .padding(.horizontal, 8)

            Button { model.createCustomProvider() } label: {
                Label(localization.string("button.add_provider"), systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
            }
            .buttonStyle(.bordered)
            .contextMenu {
                Button(localization.string("button.import_provider")) {
                    onImport()
                }
                Button(localization.string("button.paste_provider")) {
                    model.pasteProfileFromClipboard()
                }
            }
            .padding(.horizontal, 18)
            .disabled(model.isBusy)
            Spacer()
            Picker("", selection: $localization.language) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(localization.string(language.displayKey)).tag(language)
                }
            }
            .labelsHidden()
            .padding(.horizontal, 18)
            SelectableLabel(
                text: localization.string(model.isIsolatedAcceptance ? "security.isolated_note" : "security.keychain_note"),
                font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                textColor: .secondaryLabelColor,
                maximumNumberOfLines: 0
            )
            .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func icon(for id: ProviderID) -> String {
        if id == .openAI { return "person.crop.circle.badge.checkmark" }
        return "network"
    }
}
