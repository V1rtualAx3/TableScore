import Foundation
import Testing
@testable import TableScore

/// Tests de fondation (Lot 0) exécutés dans l'app hôte.
///
/// Les règles de score sont testées dans le package TableScoreKit ; ici on
/// vérifie la configuration de l'application elle-même.
struct AppConfigurationTests {
    @Test("La langue de développement est le français")
    func developmentLanguageIsFrench() {
        #expect(Bundle.main.developmentLocalization == "fr")
    }

    @Test("Le nom affiché est « TableScore »")
    func displayName() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        #expect(name == "TableScore")
    }

    @Test("Aucune exception ATS ni mode d'arrière-plan n'est déclaré")
    func noNetworkExceptionsOrBackgroundModes() {
        let hasATSException = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") != nil
        let hasBackgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") != nil
        #expect(!hasATSException)
        #expect(!hasBackgroundModes)
    }

    @Test("L'écran d'accueil se construit")
    @MainActor
    func homeViewBuilds() {
        _ = HomeView()
    }
}
