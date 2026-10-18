import SwiftUI
#if DEBUG
import UIKit
#endif

/// Point d'entrée de l'application TableScore.
///
/// L'application fonctionne entièrement hors ligne : aucune requête réseau,
/// aucun compte, aucune télémétrie. Les données restent sur l'appareil.
///
/// Le stockage local est ouvert de façon synchrone au lancement (`AppBootstrap`) ; en cas
/// d'échec, un écran d'erreur lisible remplace l'application (jamais de `fatalError`).
@main
struct TableScoreApp: App {
    @State private var bootstrap = AppBootstrap()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            content.modifier(UITestAppearanceModifier())
            #else
            content
            #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        switch bootstrap.state {
        case .ready(let dependencies):
            RootView()
                .environment(dependencies)
        case .failed(let message):
            StorageErrorView(message: message) {
                bootstrap.retry()
            }
        }
    }
}

#if DEBUG
/// Apparence imposée par les tests UI (**builds Debug uniquement**, jamais en Release).
///
/// Lancement : `-uiTesting -uiTestingAppearance dark|light`. Sans `-uiTesting`, ou avec une valeur
/// inconnue, l'argument est ignoré (apparence du système). Pourquoi pas `-AppleInterfaceStyle` :
/// cet argument de `UserDefaults` n'est pas pris en compte pour le style d'interface sur iOS.
/// Deux mécanismes complémentaires : `preferredColorScheme` à la racine (écrans SwiftUI) et
/// `overrideUserInterfaceStyle` sur les fenêtres des scènes (feuilles, alertes, dialogues, présentés
/// hors de la hiérarchie SwiftUI de la racine).
enum UITestAppearanceOverride: String, Sendable {
    case dark
    case light

    static let launchArgument = "-uiTestingAppearance"

    static func requested(in arguments: [String]) -> UITestAppearanceOverride? {
        guard arguments.contains(PersistenceController.uiTestingLaunchArgument),
              let flagIndex = arguments.firstIndex(of: launchArgument) else { return nil }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return UITestAppearanceOverride(rawValue: arguments[valueIndex])
    }

    var colorScheme: ColorScheme {
        switch self {
        case .dark: .dark
        case .light: .light
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .dark: .dark
        case .light: .light
        }
    }

    @MainActor
    func applyToWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = interfaceStyle
            }
        }
    }
}

@MainActor
private struct UITestAppearanceModifier: ViewModifier {
    private let override = UITestAppearanceOverride.requested(in: ProcessInfo.processInfo.arguments)

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(override?.colorScheme)
            .onAppear { override?.applyToWindows() }
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { _ in
                override?.applyToWindows()
            }
    }
}
#endif
