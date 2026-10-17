import XCTest

/// Jeux de données de l'app (`UITestSeed`, builds Debug). Les noms doivent rester identiques
/// aux cas de `UITestSeed` côté application.
enum SeedScenario: String, CaseIterable {
    case eightPlayers
    case nearEnd
    case tieEnd
    case withHistory
}

extension XCUIApplication {
    /// Lance l'app sur un stockage **en mémoire** (`-uiTesting`), vierge ou pré-rempli (`-seed`).
    ///
    /// Remplace `launchArguments` (relance déterministe, sans accumulation d'arguments).
    /// `extraArguments` : par ex. `["-UIPreferredContentSizeCategoryName",
    /// "UICTContentSizeCategoryAccessibilityXXL"]`.
    /// Attention : le stockage en mémoire est perdu à la relance de l'app.
    @MainActor
    func launch(seed: SeedScenario?, extraArguments: [String] = []) {
        var arguments = ["-uiTesting"]
        if let seed {
            arguments += ["-seed", seed.rawValue]
        }
        launchArguments = arguments + extraArguments
        launch()
    }
}
