import SwiftUI
import ProviderCore

struct BackupManagementView: View {
    @ObservedObject var model: ProviderManagerViewModel
    @EnvironmentObject private var localization: LocalizationController
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: BackupSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(localization.string("backup.manage")).font(.title3).fontWeight(.semibold)
                Spacer()
                Button(localization.string("backup.done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if model.backupSummaries.isEmpty {
                Text(localization.string("backup.none")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.backupSummaries, id: \.backupID) { summary in
                    row(summary)
                }
            }
            HStack {
                Text(localization.string("backup.count", model.backupSummaries.count, formattedBytes(model.backupTotalBytes)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(localization.string("backup.cleanup_old")) { model.pruneOldBackups() }
                Button(localization.string("backup.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580, height: 440)
        .alert(
            localization.string("backup.confirm_delete_title"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { summary in
            Button(localization.string("button.cancel"), role: .cancel) { pendingDelete = nil }
            Button(localization.string("backup.delete"), role: .destructive) {
                model.deleteBackup(id: summary.backupID)
                pendingDelete = nil
            }
        } message: { _ in
            Text(localization.string("backup.confirm_delete_message"))
        }
    }

    private func row(_ summary: BackupSummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: summary.isPinned ? "lock.fill" : "lock.open")
                .foregroundStyle(summary.isPinned ? .orange : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.createdAt.formatted(date: .abbreviated, time: .standard))
                Text(summary.backupID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(summary.logicalBytes > 0 ? formattedBytes(summary.logicalBytes) : localization.string("backup.legacy_size"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(localization.string(summary.isPinned ? "backup.unpin" : "backup.pin")) {
                model.setBackupPinned(id: summary.backupID, pinned: !summary.isPinned)
            }
            .controlSize(.small)
            Button(localization.string("backup.delete"), role: .destructive) {
                pendingDelete = summary
            }
            .controlSize(.small)
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
