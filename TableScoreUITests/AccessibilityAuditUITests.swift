import XCTest

/// Audit d'accessibilité automatique d'Apple (`performAccessibilityAudit`, iOS 17+) appliqué à
/// chaque écran principal, en thème clair puis sombre (cahier des charges §10 n° 16–17 : contraste,
/// taille des zones touchables, texte tronqué, descriptions VoiceOver, Dynamic Type).
///
/// L'audit est exécuté **pendant le parcours des captures** (`ScreenshotTests`) : un seul parcours par
/// thème, donc un seul lot de lancements de l'app au lieu de deux.
///
/// Politique : audit **complet** (`.all`), sans filtre global par type. Un problème détecté est un
/// vrai défaut à corriger, pas à masquer. Seule exception admise : un faux positif **démontré**,
/// déclaré dans `exemptions` (écran + type d'audit + identifiant ou libellé exact de l'élément +
/// preuve vérifiée à l'exécution + justification) et listé dans docs/captures/README.md. Un
/// problème toléré n'échoue pas, mais reste compté et affiché dans le résumé.
///
/// Rapport :
/// - chaque problème devient un `XCTFail` d'**une seule ligne** :
///   « [écran] type d'audit — résumé — élément (type, identifiant, libellé, cadre) — détail » ;
///   le gestionnaire renvoie `true` (« traité ») pour éviter un second échec générique en double ;
/// - à la fin du parcours, `Report.finish(in:)` imprime un **résumé dédoublonné et borné**
///   (≤ 150 lignes : totaux par écran, puis détail par élément avec compteur), visible à la fin du
///   journal de la CI (GitHub n'en affiche que les 5 000 dernières lignes), et le joint en entier
///   au résultat de tests (pièce jointe « resume-audit-<thème> », conservée, ignorée par l'export
///   des captures).
enum AccessibilityAudit {
    /// Audite l'écran affiché ; une capture « audit-… » est jointe (conservée seulement si le test
    /// échoue) pour situer les problèmes dans le rapport. `report` collecte les problèmes pour le
    /// résumé de fin de test.
    @MainActor
    static func run(on app: XCUIApplication, screen name: String, in test: XCTestCase, report: Report) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "audit-\(name)"
        screenshot.lifetime = .deleteOnSuccess
        test.add(screenshot)
        do {
            try app.performAccessibilityAudit { issue in
                let finding = Finding(
                    screen: name,
                    type: typeName(issue.auditType),
                    summary: singleLine(issue.compactDescription),
                    element: describe(issue.element)
                )
                if let match = exemption(for: issue, screen: name, in: app) {
                    report.record(finding, exemptedBecause: match.reason)
                } else {
                    report.record(finding, exemptedBecause: nil)
                    XCTFail("\(finding.line) — \(singleLine(issue.detailedDescription))")
                }
                return true
            }
        } catch {
            XCTFail("[\(name)] audit d'accessibilité interrompu : \(error)")
        }
    }

    // MARK: Exceptions (faux positifs démontrés uniquement)

    /// Faux positif démontré : **un** écran, **un** type d'audit, **un** élément précis, et une
    /// **preuve vérifiée à l'instant du problème** (`Proof`), jamais supposée. Sans élément
    /// identifiable (« élément non fourni ») ou preuve non vérifiée, le problème reste un échec.
    struct Exemption {
        /// Début du nom d'écran, sans le thème (« 13-saisie-par-cartes ») : vaut pour les deux thèmes.
        let screenPrefix: String
        let type: XCUIAccessibilityAuditType
        /// Identifiant d'accessibilité exact de l'élément (prioritaire) ; à défaut, libellé exact.
        let elementIdentifier: String?
        let elementLabel: String?
        let proof: Proof
        /// Pourquoi ce n'est pas un défaut (affiché dans le résumé ; aussi dans docs/captures/README.md).
        let reason: String
    }

    /// Condition vérifiée sur l'élément signalé, au moment où l'audit le signale.
    enum Proof {
        /// L'élément est un élément d'une barre de navigation UIKit : un élément de même type, même
        /// identifiant (ou libellé) et **même cadre** existe dans `app.navigationBars`.
        case inNavigationBar
        /// La commande est désactivée (`isEnabled == false`).
        case disabled
    }

    private static let navigationBarReason = "bouton de barre de navigation (UIKit) : taille de texte "
        + "plafonnée par le système, Grand contenu à l'appui long ; non modifiable par l'app"
    private static let disabledReason = "commande désactivée (formulaire incomplet) : WCAG 1.4.3 exempte "
        + "les composants inactifs ; la raison du blocage est affichée au-dessus en texte contrasté"

    /// Faux positifs démontrés (résumé de la CI du 2026-10-18, 6653ff6) ; chaque entrée est reportée
    /// dans docs/captures/README.md.
    @MainActor
    static let exemptions: [Exemption] = [
        Exemption(
            screenPrefix: "02-creation-partie", type: .dynamicType,
            elementIdentifier: "setup.cancel", elementLabel: nil,
            proof: .inNavigationBar, reason: navigationBarReason
        ),
        // `EditButton` système, sans identifiant propre : libellé exact.
        Exemption(
            screenPrefix: "02-creation-partie", type: .dynamicType,
            elementIdentifier: nil, elementLabel: "Modifier",
            proof: .inNavigationBar, reason: navigationBarReason
        ),
        Exemption(
            screenPrefix: "08-saisie-manche-penalite", type: .dynamicType,
            elementIdentifier: "round.cancel", elementLabel: nil,
            proof: .inNavigationBar, reason: navigationBarReason
        ),
        Exemption(
            screenPrefix: "13-saisie-par-cartes", type: .dynamicType,
            elementIdentifier: "round.cancel", elementLabel: nil,
            proof: .inNavigationBar, reason: navigationBarReason
        ),
        // « OK » de la feuille de consultation des cartes (sans identifiant, piloté par libellé).
        Exemption(
            screenPrefix: "12-cartes-consultation", type: .dynamicType,
            elementIdentifier: nil, elementLabel: "OK",
            proof: .inNavigationBar, reason: navigationBarReason
        ),
        // « Commencer » sur le formulaire vide (écran 02 capturé à l'ouverture).
        Exemption(
            screenPrefix: "02-creation-partie", type: .contrast,
            elementIdentifier: "setup.start", elementLabel: nil,
            proof: .disabled, reason: disabledReason
        ),
    ]

    @MainActor
    private static func exemption(
        for issue: XCUIAccessibilityAuditIssue,
        screen: String,
        in app: XCUIApplication
    ) -> Exemption? {
        guard !exemptions.isEmpty, let snapshot = try? issue.element?.snapshot() else { return nil }
        return exemptions.first { exemption in
            guard screen.hasPrefix(exemption.screenPrefix), issue.auditType == exemption.type else {
                return false
            }
            if let identifier = exemption.elementIdentifier {
                guard snapshot.identifier == identifier else { return false }
            } else if let label = exemption.elementLabel {
                guard snapshot.label == label else { return false }
            } else {
                return false
            }
            return isProven(exemption, for: snapshot, in: app)
        }
    }

    /// Vérifie la preuve de l'exception sur l'élément signalé (état réel, pas supposé).
    @MainActor
    private static func isProven(
        _ exemption: Exemption,
        for snapshot: any XCUIElementSnapshot,
        in app: XCUIApplication
    ) -> Bool {
        switch exemption.proof {
        case .disabled:
            return !snapshot.isEnabled
        case .inNavigationBar:
            let candidates = app.navigationBars.descendants(matching: snapshot.elementType)
            let match: XCUIElement
            if let identifier = exemption.elementIdentifier {
                match = candidates.matching(identifier: identifier).firstMatch
            } else if let label = exemption.elementLabel {
                match = candidates.matching(NSPredicate(format: "label == %@", label)).firstMatch
            } else {
                return false
            }
            guard let inBar = try? match.snapshot() else { return false }
            return isSameFrame(inBar.frame, snapshot.frame)
        }
    }

    /// Cadres identiques à moins d'un point près (même élément vu par deux requêtes).
    private static func isSameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1 && abs(lhs.minY - rhs.minY) < 1
            && abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }

    // MARK: Résumé de fin de test

    /// Problème tel qu'il est dédoublonné dans le résumé.
    struct Finding: Hashable, Sendable {
        let screen: String
        let type: String
        let summary: String
        let element: String

        var line: String { "[\(screen)] \(type) — \(summary) — \(element)" }
    }

    /// Collecte des problèmes d'un parcours (un test) et résumé compact imprimé à la fin.
    @MainActor
    final class Report {
        /// Nombre maximal de lignes imprimées (le résumé complet est en pièce jointe).
        static let maxPrintedLines = 150

        private let title: String
        private var counts: [Finding: Int] = [:]
        /// Ordre d'apparition (écran par écran).
        private var order: [Finding] = []
        private var exemptionReasons: [Finding: String] = [:]
        private var total = 0

        init(title: String) {
            self.title = title
        }

        func record(_ finding: Finding, exemptedBecause reason: String?) {
            total += 1
            if counts[finding] == nil {
                order.append(finding)
            }
            counts[finding, default: 0] += 1
            if let reason {
                exemptionReasons[finding] = reason
            }
        }

        /// Imprime le résumé borné (fin du journal) et joint le résumé complet au test.
        func finish(in test: XCTestCase) {
            print(summaryLines(limit: Self.maxPrintedLines).joined(separator: "\n"))
            let attachment = XCTAttachment(string: summaryLines(limit: nil).joined(separator: "\n"))
            attachment.name = "resume-audit-\(title)"
            attachment.lifetime = .keepAlways
            test.add(attachment)
        }

        private func summaryLines(limit: Int?) -> [String] {
            let tolerated = order
                .filter { exemptionReasons[$0] != nil }
                .reduce(0) { $0 + (counts[$1] ?? 0) }
            var lines = [
                "===== RÉSUMÉ AUDIT ACCESSIBILITÉ (\(title)) : \(total) problème(s), "
                    + "\(order.count) distinct(s), \(tolerated) toléré(s) =====",
            ]
            guard !order.isEmpty else {
                lines.append("Aucun problème.")
                lines.append("===== FIN DU RÉSUMÉ (\(title)) =====")
                return lines
            }
            lines.append("-- Totaux par écran et par type --")
            lines += totalsByScreen()
            lines.append("-- Détail (écran | type | résumé | élément | ×occurrences) --")
            // Deux lignes réservées à la fin (reste éventuel + clôture).
            let used = lines.count
            let budget = limit.map { max(0, $0 - used - 2) } ?? order.count
            for finding in order.prefix(budget) {
                var line = "\(finding.screen) | \(finding.type) | \(finding.summary) | \(finding.element)"
                    + " | ×\(counts[finding] ?? 0)"
                if let reason = exemptionReasons[finding] {
                    line += " | TOLÉRÉ : \(reason)"
                }
                lines.append(line)
            }
            if order.count > budget {
                lines.append("… \(order.count - budget) entrée(s) de plus : pièce jointe « resume-audit-\(title) ».")
            }
            lines.append("===== FIN DU RÉSUMÉ (\(title)) =====")
            return lines
        }

        /// « 09-historique-clair : contraste 28, Dynamic Type 7 » (une ligne par écran).
        private func totalsByScreen() -> [String] {
            var screens: [String] = []
            var perScreen: [String: [(type: String, count: Int)]] = [:]
            for finding in order {
                let count = counts[finding] ?? 0
                var entries = perScreen[finding.screen] ?? []
                if entries.isEmpty {
                    screens.append(finding.screen)
                }
                if let index = entries.firstIndex(where: { $0.type == finding.type }) {
                    entries[index].count += count
                } else {
                    entries.append((type: finding.type, count: count))
                }
                perScreen[finding.screen] = entries
            }
            return screens.map { screen in
                let parts = (perScreen[screen] ?? []).map { "\($0.type) \($0.count)" }
                return "\(screen) : " + parts.joined(separator: ", ")
            }
        }
    }

    // MARK: Mise en forme

    /// « bouton id=history.round.2 « Manche 2, … » @16,240 361×88 », sans `Optional(Attributes…)`.
    /// Lecture par `snapshot()`, qui lève une erreur au lieu d'enregistrer un échec XCTest.
    @MainActor
    private static func describe(_ element: XCUIElement?) -> String {
        guard let element else { return "élément non fourni" }
        guard let snapshot = try? element.snapshot() else { return "élément introuvable" }
        var parts = [elementTypeName(snapshot.elementType)]
        if !snapshot.identifier.isEmpty {
            parts.append("id=\(snapshot.identifier)")
        }
        let label = singleLine(snapshot.label)
        if !label.isEmpty {
            let shortened = label.count > 70 ? String(label.prefix(70)) + "…" : label
            parts.append("« \(shortened) »")
        }
        let frame = snapshot.frame
        parts.append(String(
            format: "@%.0f,%.0f %.0fx%.0f",
            Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)
        ))
        return parts.joined(separator: " ")
    }

    private static func elementTypeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: "bouton"
        case .staticText: "texte"
        case .textField: "champ"
        case .image: "image"
        case .cell: "cellule"
        case .other: "autre"
        case .segmentedControl: "segments"
        case .navigationBar: "barre de navigation"
        case .scrollView: "défilement"
        case .collectionView: "collection"
        case .table: "table"
        case .toolbar: "barre d'outils"
        case .link: "lien"
        case .stepper: "stepper"
        default: "type \(type.rawValue)"
        }
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
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
