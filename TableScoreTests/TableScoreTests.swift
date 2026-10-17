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

    @Test("Aucune permission (clé *UsageDescription) ni service Bonjour n'est déclaré")
    func noUsageDescriptionOrBonjour() {
        let keys = Bundle.main.infoDictionary?.keys.map { $0 } ?? []
        let usageKeys = keys.filter { $0.hasSuffix("UsageDescription") }
        #expect(usageKeys.isEmpty)
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") == nil)
    }

    @Test("L'hôte de navigation et l'écran d'accueil se construisent")
    @MainActor
    func homeViewBuilds() {
        _ = RootView()
        _ = HomeView()
    }
}
