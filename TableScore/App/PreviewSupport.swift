#if DEBUG
import SwiftUI

extension View {
    /// Environnement complet pour les previews : `InMemoryGameRepository` (jamais de disque),
    /// éventuellement rempli par un jeu de données `UITestSeed`, et un `AppRouter` neuf.
    ///
    /// Debug uniquement : entourer les `#Preview` qui l'utilisent de `#if DEBUG … #endif`.
    @MainActor
    func previewEnvironment(_ seed: UITestSeed? = nil) -> some View {
        let repository = InMemoryGameRepository()
        if let seed {
            // Données statiques valides (vérifiées par les tests unitaires) ; une erreur ne
            // ferait qu'afficher une preview vide.
            _ = try? seed.apply(to: repository)
        }
        return self
            .environment(AppDependencies(repository: repository))
            .environment(AppRouter())
    }
}
#endif
