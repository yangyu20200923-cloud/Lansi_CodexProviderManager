import SwiftUI

struct StatusSummaryView: View {
    @ObservedObject var model: ProviderManagerViewModel
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localization.string("status.title")).font(.headline)
            HStack(spacing: 32) {
                status("status.history", model.diagnostics?.history.map { localization.string("status.history_count", $0.totalThreads) } ?? localization.string("status.extensions_none"), "clock.arrow.circlepath")
                status("status.extensions", extensionText, "puzzlepiece.extension")
                status("status.backup", backupText, "externaldrive")
            }
            Text(localization.status(model.statusMessage)).font(.callout).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(.top, 8)
    }

    private var extensionText: String {
        guard let paths = model.diagnostics?.history?.extensionPaths else { return localization.string("status.extensions_none") }
        return paths.isEmpty ? localization.string("status.extensions_none") : paths.sorted().joined(separator: ", ")
    }
    private var backupText: String {
        guard let date = model.diagnostics?.latestBackupDate else { return localization.string("status.backup_none") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    private func status(_ key: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) { Text(localization.string(key)).font(.caption).foregroundStyle(.secondary); Text(value).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
