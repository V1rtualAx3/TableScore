import XCTest

/// Audit d'accessibilité automatique d'Apple (`performAccessibilityAudit`, iOS 17+) appliqué à
/// chaque écran principal, en thème clair puis sombre (cahier des charges §10 n° 16–17 : contraste,
/// taille des zones touchables, texte tronqué, descriptions VoiceOver, Dynamic Type).
///
/// L'audit est exécuté **pendant le parcours des captures** (`ScreenshotTests`) : un seul parcours par
/// thème, donc un seul lot de lancements de l'app au lieu de deux.
///
/// Politique : audit **complet et sans exclusion** (`.all`). Un problème détecté est un vrai défaut
/// à corriger, pas à masquer. Toute exclusion future (faux positif système avéré : élément hors de
/// l'app, contraste du texte d'espace réservé natif d'un champ) devra être décidée dans le
/// gestionnaire de problèmes ci-dessous avec, pour CHAQUE exclusion, un commentaire précis (type de
/// problème, élément, raison, référence) — jamais de filtre global par type.
///
/// Message d'échec : chaque problème devient un `XCTFail` au format
/// « [écran] type d'audit — résumé — élément : … — détail », puis le gestionnaire renvoie `true`
/// (« traité ») pour éviter un second échec générique en double : rien n'est ignoré.
enum AccessibilityAudit {
    /// Audite l'écran affiché ; une capture « audit-… » est jointe (conservée seulement si le test
    /// échoue) pour situer les problèmes dans le rapport.
    @MainActor
    static func run(on app: XCUIApplication, screen name: String, in test: XCTestCase) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "audit-\(name)"
        screenshot.lifetime = .deleteOnSuccess
        test.add(screenshot)
        do {
            try app.performAccessibilityAudit { issue in
                XCTFail(
                    "[\(name)] \(typeName(issue.auditType)) — \(issue.compactDescription) — "
                        + "élément : \(String(describing: issue.element)) — \(issue.detailedDescription)"
                )
                return true
            }
        } catch {
            XCTFail("[\(name)] audit d'accessibilité interrompu : \(error)")
        }
    }

    private static func typeName(_ type: XCUIAccessibilityAuditType) -> String {
        let names: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contraste"),
            (.elementDetection, "détection d'élément"),
            (.hitRegion, "zone touchable"),
            (.sufficientElementDescription, "description insuffisante"),
            (.dynamicType, "Dynamic Type"),
            (.textClipped, "texte tronqué"),
            (.trait, "traits d'accessibilité"),
        ]
        let matches = names.filter { type.contains($0.0) }.map(\.1)
        return matches.isEmpty ? "type \(type.rawValue)" : matches.joined(separator: " + ")
    }
}
