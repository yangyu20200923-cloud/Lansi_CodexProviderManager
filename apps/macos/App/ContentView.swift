import SwiftUI
import ProviderCore

struct ContentView: View {
    @StateObject private var model = ProviderManagerViewModel()
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        HStack(spacing: 0) {
            ProviderSidebar(model: model)
                .frame(width: 240)
            Divider()
            VStack(spacing: 0) {
                ProviderFormView(model: model)
                Divider()
                actionBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button { model.restoreDefaults() } label: { Label(localization.string("button.restore_defaults"), systemImage: "arrow.counterclockwise") }
                .disabled(model.isBusy)
            Spacer()
            ProgressView().controlSize(.small).opacity(model.isBusy ? 1 : 0)
            Button { Task { await model.apply() } } label: { Label(localization.string("button.apply_restart"), systemImage: "arrow.clockwise") }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || !model.validationIssues.isEmpty)
        }
        .padding(.horizontal, 28)
        .frame(height: 68)
    }
}
