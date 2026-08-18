import SwiftUI
import ProviderCore

@main
struct ProviderManagerApp: App {
    @StateObject private var localization = LocalizationController()
    @StateObject private var model: ProviderManagerViewModel

    init() {
        let configuration = ProviderManagerLaunchConfiguration(arguments: CommandLine.arguments)
        let keychain: any ProviderCredentialStoring
        let runtimeController: any ProviderRuntimeControlling
        if configuration.isolatedAcceptance {
            keychain = ProviderCredentialStores.isolatedAcceptance()
            runtimeController = ProviderRuntimeControllers.isolatedAcceptance()
        } else {
            keychain = ProviderCredentialStores.production()
            runtimeController = ProviderRuntimeControllers.production()
        }
        _model = StateObject(
            wrappedValue: ProviderManagerViewModel(
                codexHome: configuration.codexHome,
                profileStoreURL: configuration.profileStoreURL,
                keychain: keychain,
                runtimeController: runtimeController,
                isIsolatedAcceptance: configuration.isolatedAcceptance
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 660)
                .environment(\.locale, localization.locale)
                .environmentObject(localization)
        }
        .defaultSize(width: 1120, height: 740)
        .windowResizability(.contentMinSize)
    }
}

private struct ProviderManagerLaunchConfiguration {
    let codexHome: URL
    let profileStoreURL: URL?
    let isolatedAcceptance: Bool

    init(arguments: [String]) {
        let requestedHome = Self.fileURL(for: "--codex-home", in: arguments)
        let requestedStore = Self.fileURL(for: "--profile-store", in: arguments)
        isolatedAcceptance = arguments.contains("--isolated-acceptance")
        if isolatedAcceptance {
            guard let requestedHome, let requestedStore else {
                fatalError("Isolated acceptance requires --codex-home and --profile-store in the system temporary directory.")
            }
            do {
                let configuration = try IsolatedAcceptanceConfiguration(
                    codexHome: requestedHome,
                    profileStoreURL: requestedStore
                )
                codexHome = configuration.codexHome
                profileStoreURL = configuration.profileStoreURL
            } catch {
                fatalError("Isolated acceptance paths must be in the system temporary directory.")
            }
        } else {
            codexHome = requestedHome ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            profileStoreURL = requestedStore
        }
    }

    private static func fileURL(for option: String, in arguments: [String]) -> URL? {
        guard let optionIndex = arguments.firstIndex(of: option),
              arguments.indices.contains(optionIndex + 1) else { return nil }
        return URL(fileURLWithPath: arguments[optionIndex + 1])
    }
}
