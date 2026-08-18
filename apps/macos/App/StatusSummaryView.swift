import SwiftUI

struct StatusSummaryView: View {
    @ObservedObject var model: ProviderManagerViewModel
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localization.string("status.title")).font(.headline)
            HStack(spacing: 32) {
                status("status.history", historyText, "clock.arrow.circlepath")
                status("status.extensions", extensionText, "puzzlepiece.extension")
                status("status.backup", backupText, "externaldrive")
            }
            SelectableLabel(
                text: localization.status(model.statusMessage),
                font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                textColor: .secondaryLabelColor
            )
        }
        .padding(.top, 8)
    }

    private var historyText: String {
        guard let activity = model.diagnostics?.activity else { return localization.string("status.extensions_none") }
        if let threads = activity.threadCount {
            return localization.string("status.history_summary", threads, activity.sessionFileCount)
        }
        let issueKey: String
        switch activity.historyIssue {
        case .stateDatabaseMissing: issueKey = "status.history_database_missing"
        case .stateDatabaseUnreadable: issueKey = "status.history_database_unreadable"
        case .threadsUnavailable: issueKey = "status.history_threads_unavailable"
        case nil: issueKey = "status.extensions_none"
        }
        return localization.string("status.history_unavailable", localization.string(issueKey), activity.sessionFileCount)
    }

    private var extensionText: String {
        guard let activity = model.diagnostics?.activity else { return localization.string("status.extensions_none") }
        return localization.string("status.extensions_summary", activity.skillCount, activity.pluginCount, activity.mcpServerCount, activity.mcpFileCount)
    }
    private var backupText: String {
        guard let date = model.diagnostics?.latestBackupDate else { return localization.string("status.backup_none") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    private func status(_ key: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.string(key)).font(.caption).foregroundStyle(.secondary)
                SelectableLabel(
                    text: value,
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                    textColor: .labelColor
                )
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
