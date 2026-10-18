import XCTest

/// Audit d'accessibilité automatique d'Apple (`performAccessibilityAudit`, iOS 17+) sur chaque
/// écran principal, en thème clair puis sombre (cahier des charges §10 n° 16–17 : contraste,
/// taille des zones touchables, texte tronqué, descriptions VoiceOver, Dynamic Type).
///
/// Politique : l'audit est **complet et sans exclusion** (`.all`, aucun filtre). Un problème détecté
/// est un vrai défaut à corriger, pas à masquer. Toute exclusion future (faux positif système avéré :
/// élément hors de l'app, contraste du texte d'espace réservé natif d'un champ) devra passer par le
/// gestionnaire de problèmes de `performAccessibilityAudit` avec, pour CHAQUE exclusion, un commentaire
/// précis (type de problème, élément, raison, référence) — jamais de filtre global par type.
///
/// Les écrans sont ceux de `ScreenTour` (mêmes parcours que les captures). Un défaut sur un écran
/// n'interrompt pas l'audit des suivants : tous les problèmes sont rapportés en un seul passage.
/// Chaque écran est joint (capture « audit-… », conservée seulement si le test échoue) pour situer les
/// problèmes dans le rapport.
final class AccessibilityAuditUITests: XCTestCase {
    override func setUpWithError() throws {
        // Les échecs d'audit (écrans suivants encore audités) ne doivent pas arrêter le test ; une
        // navigation impossible lève en revanche une erreur (`ScreenTour.TourError`) qui l'arrête.
        continueAfterFailure = true
    }

    @MainActor
    private func auditAllScreens(appearance: UITestAppearance) throws {
        let app = XCUIApplication()
        let tour = ScreenTour(app: app, appearance: appearance) { [self] name in
            audit(app, screen: name)
        }
        try tour.runFullTour()
    }

    @MainActor
    private func audit(_ app: XCUIApplication, screen name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "audit-\(name)"
        screenshot.lifetime = .deleteOnSuccess
        add(screenshot)
        do {
            // Audit complet par défaut, sans gestionnaire d'exclusion.
            try app.performAccessibilityAudit()
        } catch {
            XCTFail("Audit d'accessibilité en échec sur « \(name) » : \(error)")
        }
    }

    @MainActor
    func testAccessibilityAuditLightTheme() throws {
        try auditAllScreens(appearance: .light)
    }

    @MainActor
    func testAccessibilityAuditDarkTheme() throws {
        try auditAllScreens(appearance: .dark)
    }
}
