import SwiftUI
import AppKit
import ProviderCore
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: ProviderManagerViewModel
    @EnvironmentObject private var localization: LocalizationController
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportDocument: ProfileTransferDocument?
    @State private var pendingDeletion: ProviderProfile?
    @State private var showingRestoreConfirmation = false
    @State private var showingBackupManagement = false

    var body: some View {
        HStack(spacing: 0) {
            ProviderSidebar(
                model: model,
                onImport: { isImporting = true },
                onExport: { profile in
                    guard let data = model.exportSelectedProfile() else { return }
                    exportDocument = ProfileTransferDocument(data: data)
                    isExporting = true
                }
            )
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
        .onAppear { MainWindowSizer.ensureContentVisible() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                model.importProfile(from: url)
            case .failure(let error):
                model.reportImportSelectionFailure(error)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: model.selectedProfile.displayName
        ) { result in
            model.completeExport(result)
        }
        .alert(
            localization.string("alert.delete_provider_title"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { profile in
            Button(localization.string("button.cancel"), role: .cancel) { pendingDeletion = nil }
            Button(localization.string("button.delete"), role: .destructive) {
                model.deleteCustomProvider(id: profile.id)
                pendingDeletion = nil
            }
        } message: { profile in
            Text(localization.string("alert.delete_provider_message", profile.displayName))
        }
        .alert(localization.string("alert.restore_backup_title"), isPresented: $showingRestoreConfirmation) {
            Button(localization.string("button.cancel"), role: .cancel) {}
            Button(localization.string("button.restore_latest"), role: .destructive) {
                Task { await model.restoreLatestBackup() }
            }
        } message: {
            Text(localization.string("alert.restore_backup_message"))
        }
        .sheet(isPresented: $showingBackupManagement) {
            BackupManagementView(model: model)
                .environmentObject(localization)
        }
    }

    private var actionBar: some View {
        FlowLayout(spacing: 10, alignment: .trailing) {
            Button { model.saveProfile() } label: {
                Label(localization.string("button.save_provider"), systemImage: "square.and.arrow.down")
            }
            .disabled(model.isBusy || !model.validationIssues.isEmpty)

            Button { model.refreshDiagnostics() } label: {
                Label(localization.string("button.refresh_status"), systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy || model.isRefreshingDiagnostics)

            Button {
                model.refreshBackupSummaries()
                showingBackupManagement = true
            } label: {
                Label(localization.string("button.manage_backups"), systemImage: "externaldrive.badge.clock")
            }
            .disabled(model.isBusy)

            Button { showingRestoreConfirmation = true } label: {
                Label(localization.string("button.restore_latest"), systemImage: "arrow.uturn.backward.circle")
            }
            .disabled(model.isBusy || !model.hasLatestBackup)

            if model.selectedID.isBuiltIn {
                Button { model.restoreDefaults() } label: {
                    Label(localization.string("button.restore_defaults"), systemImage: "arrow.counterclockwise")
                }
                .disabled(model.isBusy)
            } else {
                Button { model.toggleSelectedProfileEnabled() } label: {
                    Label(
                        localization.string(model.selectedProfile.enabled ? "button.disable_provider" : "button.enable_provider"),
                        systemImage: model.selectedProfile.enabled ? "pause.circle" : "play.circle"
                    )
                }
                .disabled(model.isBusy || (model.selectedProfile.enabled && model.profileSet.activeProvider == model.selectedID))

                Button { pendingDeletion = model.selectedProfile } label: {
                    Label(localization.string("button.delete"), systemImage: "trash")
                }
                .foregroundStyle(.red)
                .disabled(model.isBusy || model.profileSet.activeProvider == model.selectedID)
            }

            ProgressView()
                .controlSize(.small)
                .opacity((model.isBusy || model.isRefreshingDiagnostics) ? 1 : 0)

            Button { Task { await model.apply() } } label: {
                Label(localization.string("button.apply_restart"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || !model.selectedProfile.enabled || !model.validationIssues.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// macOS restores the last window frame across launches and SwiftUI's
/// `.defaultSize` only applies on the very first launch. If the remembered
/// frame is smaller than the content that must be fully visible (the form
/// grid is about 1050 points wide), the window opens with clipped content.
/// `onAppear` runs after the window exists, so the window is grown there
/// directly through `NSApp`; frames the user enlarged manually stay as they
/// are.
private enum MainWindowSizer {
    static let minimumContentSize = NSSize(width: 1120, height: 740)

    static func ensureContentVisible() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let window = NSApp.windows.first(where: { $0.isVisible })
                ?? NSApp.windows.first
            else { return }
            var frame = window.frame
            if frame.size.width < minimumContentSize.width || frame.size.height < minimumContentSize.height {
                frame.size.width = max(frame.size.width, minimumContentSize.width)
                frame.size.height = max(frame.size.height, minimumContentSize.height)
                window.setFrame(frame, display: true)
            }
        }
    }
}

private struct ProfileTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
