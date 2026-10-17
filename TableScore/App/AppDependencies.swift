import Foundation
import Observation

/// Dépendances partagées, injectées une fois dans l'environnement SwiftUI :
/// `@Environment(AppDependencies.self) private var dependencies`.
///
/// Le dépôt est la **source de vérité unique** des parties ; les view models le reçoivent par
/// leur initialiseur (`Model(…, repository: dependencies.repository)`) et ne lisent jamais
/// SwiftData directement. Classe `@Observable` uniquement pour l'injection par type.
@Observable
@MainActor
final class AppDependencies {
    let repository: any GameRepository

    init(repository: any GameRepository) {
        self.repository = repository
    }
}

/// Clés des préférences locales (`UserDefaults` standard, jamais synchronisées).
enum AppPreferenceKey {
    /// `@AppStorage(AppPreferenceKey.hapticsEnabled) private var hapticsEnabled = true`
    static let hapticsEnabled = "settings.hapticsEnabled"
}
