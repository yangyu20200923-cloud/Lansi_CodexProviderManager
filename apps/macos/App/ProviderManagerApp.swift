import SwiftUI

@main
struct ProviderManagerApp: App {
    @StateObject private var localization = LocalizationController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 660)
                .environment(\.locale, localization.locale)
                .environmentObject(localization)
        }
        .windowResizability(.contentMinSize)
    }
}
