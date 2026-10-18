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

    /// Exception unique (prototype P2 « Scanner les cartes », décision utilisateur du 2026-10-18,
    /// cahier §2) : l'appareil photo. Aucune autre permission (photothèque, micro, localisation…).
    @Test("Seule la permission appareil photo est déclarée ; aucun service Bonjour")
    func onlyCameraUsageDescriptionAndNoBonjour() {
        let keys = Bundle.main.infoDictionary?.keys.map { $0 } ?? []
        let usageKeys = keys.filter { $0.hasSuffix("UsageDescription") }
        #expect(usageKeys == ["NSCameraUsageDescription"])
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") == nil)
    }

    @Test("Texte de la demande d'accès à l'appareil photo : français, non vide, ni conservation ni envoi")
    func cameraUsageDescriptionText() {
        let text = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
        let expected = "TableScore utilise l'appareil photo pour lire les cartes d'un joueur et pré-remplir son "
            + "décompte. L'image est analysée sur l'iPhone, puis effacée\u{00A0}: elle n'est ni conservée ni envoyée."
        #expect(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        #expect(text == expected)
    }

    @Test("L'hôte de navigation et l'écran d'accueil se construisent")
    @MainActor
    func homeViewBuilds() {
        _ = RootView()
        _ = HomeView()
    }
}

#if !DEBUG
/// Sentinelle : hors configuration Debug, les suites `#if DEBUG` (fixtures `UITestSeed`, modèles
/// testés via dépôt en mémoire) ne sont pas compilées. Ce test échoue volontairement pour que
/// le silence de ces suites ne passe pas pour un succès.
struct DebugOnlySuitesSentinelTests {
    @Test("Configuration non-Debug : les suites DEBUG-only sont ignorées")
    func debugOnlySuitesAreSkipped() {
        Issue.record("Build non-Debug : les suites de tests DEBUG-only ne sont pas exécutées. Lancer les tests en Debug.")
    }
}
#endif
