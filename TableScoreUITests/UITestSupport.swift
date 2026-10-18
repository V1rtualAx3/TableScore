import UIKit
import XCTest

/// Jeux de données de l'app (`UITestSeed`, builds Debug). Les noms doivent rester identiques
/// aux cas de `UITestSeed` côté application.
enum SeedScenario: String, CaseIterable {
    case eightPlayers
    case nearEnd
    case tieEnd
    case withHistory
    case withCards
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

/// Pilotage fiable d'un formulaire dont l'action principale est fixée en bas de l'écran
/// (`primaryActionInset` : fond `.bar`, au-dessus du clavier) — saisie de manche, création de partie.
///
/// Pourquoi ne pas se fier à `isHittable` : il repose sur le test de toucher **d'accessibilité**,
/// qui ignore le fond de la zone d'action. Un élément situé sous cette zone (ou sous le clavier)
/// peut être déclaré « touchable » alors que le toucher réel atterrit sur la barre (constaté en
/// CI : champ jamais focalisé, bouton « Ajouter un joueur » non touché). On vérifie donc la
/// **géométrie** : l'élément doit être entièrement dans la bande utile, sous les barres de
/// navigation et au-dessus de la zone d'action. Le défilement se fait par glissements courts et
/// freinés (aucun lancer qui dépasse la cible), depuis la marge gauche du formulaire (aucune
/// commande touchée). Les cellules paresseuses non encore créées sont cherchées vers le bas puis
/// vers le haut.
@MainActor
struct FormDriver {
    let app: XCUIApplication
    /// Bouton de la zone d'action fixe (`round.save`, `setup.start`).
    let actionButton: XCUIElement
    /// Autres éléments de la zone d'action fixe (résumé, aperçu du clôturant, raison du blocage),
    /// mesurés lorsqu'ils sont affichés : le haut réel de la zone est le plus haut d'entre eux.
    var actionAreaElements: [XCUIElement] = []
    /// Bouton « OK » de la barre du clavier (identifiant dédié, ex. `round.keyboardDone`).
    var keyboardDoneButton: XCUIElement?

    private static let margin: CGFloat = 8
    /// Marge intérieure verticale de `primaryActionInset` (`Theme.Spacing.m`) : le fond `.bar`
    /// commence à cette distance au-dessus de son premier élément.
    private static let actionAreaPadding: CGFloat = 12
    /// Repli **seulement** si aucun élément de la zone d'action n'est mesurable.
    private static let estimatedActionAreaHeight: CGFloat = 160
    /// Abscisse des glissements : marge du formulaire groupé, hors de toute cellule.
    private static let dragX: CGFloat = 10
    /// En dessous, un glissement n'est pas reconnu comme un défilement.
    private static let minimumDrag: CGFloat = 32
    /// Barre d'outils du clavier (« Suivant », « OK »), hors du cadre `app.keyboards`.
    private static let keyboardToolbarHeight: CGFloat = 44

    // MARK: Géométrie

    /// Bande verticale (coordonnées écran) où un toucher atteint vraiment le contenu défilant.
    func usableBand() -> ClosedRange<CGFloat> {
        let window = app.windows.firstMatch.frame
        var top = window.minY
        for bar in app.navigationBars.allElementsBoundByIndex where bar.exists {
            top = max(top, bar.frame.maxY)
        }
        var bottom = window.maxY
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            bottom = min(bottom, keyboard.frame.minY - Self.keyboardToolbarHeight)
        }
        // Haut réel de la zone d'action : le contenu défilant s'arrête au-dessus (safe area).
        let measuredTops = ([actionButton] + actionAreaElements)
            .filter { $0.exists }
            .map { $0.frame }
            .filter { !$0.isEmpty }
            .map { $0.minY }
        if let actionAreaTop = measuredTops.min() {
            bottom = min(bottom, actionAreaTop - Self.actionAreaPadding - 2)
        } else {
            // Zone d'action (au-dessus du clavier s'il est affiché) non mesurable : estimation.
            bottom -= Self.estimatedActionAreaHeight
        }
        top += Self.margin
        return top...max(top + 1, bottom)
    }

    /// L'élément est entièrement dans la bande utile (son centre, s'il est plus haut que la bande).
    func isInUsableBand(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard !frame.isEmpty else { return false }
        let band = usableBand()
        if frame.height >= band.upperBound - band.lowerBound {
            return band.contains(frame.midY)
        }
        return frame.minY >= band.lowerBound && frame.maxY <= band.upperBound
    }

    // MARK: Défilement

    /// Fait défiler jusqu'à ce que l'élément soit dans la bande utile ; échec explicite sinon.
    @discardableResult
    func bringIntoView(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        var stepsDownWhileMissing = 0
        var previousFrame: CGRect?
        for _ in 0..<16 {
            if isInUsableBand(element) { return true }
            let band = usableBand()
            let height = band.upperBound - band.lowerBound
            let frame = element.exists ? element.frame : .zero
            let delta: CGFloat
            if !frame.isEmpty {
                if let previousFrame, previousFrame == frame {
                    // Le glissement précédent n'a rien déplacé : plus de défilement possible dans ce
                    // sens. Accepté seulement si le point touché (centre) est dans la zone utile ;
                    // sinon échec immédiat plutôt que des glissements inutiles.
                    if band.contains(frame.midY) { return true }
                    break
                }
                previousFrame = frame
                if frame.height >= height {
                    delta = frame.midY - (band.lowerBound + band.upperBound) / 2
                } else if frame.maxY > band.upperBound {
                    delta = frame.maxY - band.upperBound + 16
                } else {
                    delta = frame.minY - band.lowerBound - 16
                }
            } else if stepsDownWhileMissing < 6 {
                // Cellule pas encore créée (liste paresseuse) : d'abord plus bas dans le formulaire.
                stepsDownWhileMissing += 1
                delta = height
            } else {
                delta = -height
            }
            scrollContent(by: delta, within: band)
        }
        let found = isInUsableBand(element)
        let frame = element.exists ? element.frame : .zero
        XCTAssertTrue(
            found,
            "Élément hors de la zone touchable après défilement : \(element) ; cadre \(frame), "
                + "zone utile \(usableBand()), clavier affiché : \(app.keyboards.firstMatch.exists)",
            file: file,
            line: line
        )
        return found
    }

    /// Fait monter (`delta > 0`) ou descendre le contenu d'environ `delta` points, sans lancer.
    private func scrollContent(by delta: CGFloat, within band: ClosedRange<CGFloat>) {
        let maximum = (band.upperBound - band.lowerBound) * 0.7
        let magnitude = min(max(abs(delta), Self.minimumDrag), maximum)
        let startY = delta > 0 ? band.upperBound - 4 : band.lowerBound + 4
        let endY = delta > 0 ? startY - magnitude : startY + magnitude
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let start = origin.withOffset(CGVector(dx: Self.dragX, dy: startY))
        let end = origin.withOffset(CGVector(dx: Self.dragX, dy: endY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    // MARK: Touchers et saisie

    /// Rend l'élément touchable puis le touche.
    func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        bringIntoView(element, file: file, line: line)
        element.tap()
    }

    func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        element.exists && ((element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false)
    }

    func waitForKeyboardFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND hasKeyboardFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Donne le focus clavier au champ : défilement dans la bande utile, toucher au centre (dans
    /// le champ texte quel que soit son cadre d'accessibilité), attente du focus **réel** ; au plus
    /// trois essais. `typeText` exige ce focus.
    func focus(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        if hasKeyboardFocus(field) { return }
        for _ in 0..<3 {
            bringIntoView(field, file: file, line: line)
            field.tap()
            if waitForKeyboardFocus(field, timeout: 3) { return }
        }
        XCTFail("Le champ n'a pas reçu le focus clavier : \(field)", file: file, line: line)
    }

    /// Saisie dans un champ, focus vérifié au préalable.
    func type(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        focus(field, file: file, line: line)
        field.typeText(text)
    }

    /// Remplace le contenu d'un champ aligné à droite. L'effacement ne porte que sur ce qui précède
    /// le curseur : le champ est touché près de son bord droit (focus donné par le cadre du champ,
    /// curseur en fin de texte), l'effacement est **vérifié** (`emptyValue` : valeur
    /// d'accessibilité d'un champ vide), avec nouvel essai à un autre point si besoin.
    func replaceText(
        in field: XCUIElement,
        with text: String,
        emptyValue: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        dismissKeyboard(file: file, line: line)
        bringIntoView(field, file: file, line: line)
        let rightEdge = field.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
        let points = [
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
            rightEdge.withOffset(CGVector(dx: -12, dy: 0)),
            rightEdge.withOffset(CGVector(dx: -6, dy: 0)),
        ]
        for point in points where value(of: field) != emptyValue {
            point.tap()
            guard waitForKeyboardFocus(field, timeout: 3) else { continue }
            let deletions = String(repeating: XCUIKeyboardKey.delete.rawValue, count: value(of: field).count + 2)
            field.typeText(deletions)
        }
        XCTAssertEqual(value(of: field), emptyValue, "Le champ doit être vide avant la nouvelle saisie.", file: file, line: line)
        type(text, into: field, file: file, line: line)
    }

    /// Ferme le clavier et **vérifie** qu'il est fermé : bouton « OK » de sa barre (identifiant
    /// dédié, sinon libellé dans une barre d'outils), à défaut fermeture interactive par
    /// glissement vers le clavier (`.scrollDismissesKeyboard(.interactively)`). Sans fermeture
    /// effective, la zone utile reste réduite au-dessus du clavier.
    func dismissKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = app.keyboards.firstMatch
        let candidates = [keyboardDoneButton, app.toolbars.buttons["OK"]].compactMap { $0 }
        if let done = candidates.first(where: { $0.exists && $0.isHittable }) {
            done.tap()
        } else if keyboard.exists {
            let band = usableBand()
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            let start = origin.withOffset(CGVector(dx: Self.dragX, dy: band.upperBound - 4))
            let end = origin.withOffset(CGVector(dx: Self.dragX, dy: keyboard.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.1)
        } else {
            return
        }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        _ = XCTWaiter().wait(for: [gone], timeout: 3)
        XCTAssertFalse(keyboard.exists, "Le clavier doit être fermé avant de toucher hors des champs.", file: file, line: line)
    }

    private func value(of field: XCUIElement) -> String {
        (field.value as? String) ?? ""
    }
}

// MARK: - Apparence, taille de texte et parcours d'écrans (Lot 4 : captures et audits)

/// Apparence imposée au **lancement** de l'app (et non au simulateur entier : aucun état résiduel
/// d'un test à l'autre).
///
/// Sombre : argument `-AppleInterfaceStyle Dark` (domaine d'arguments de `UserDefaults`, lu par
/// UIKit/SwiftUI pour le style d'interface). `XCUIDevice.shared.appearance` n'est volontairement pas
/// utilisé : sa disponibilité dans le SDK de la CI n'est pas vérifiable sans Xcode, et il modifie le
/// simulateur pour les tests suivants. `ScreenTour` vérifie la luminosité réelle de la première
/// capture : un thème non appliqué fait **échouer** le test au lieu de produire de fausses captures.
enum UITestAppearance: CaseIterable, Sendable {
    case light
    case dark

    var launchArguments: [String] {
        switch self {
        case .light: []
        case .dark: ["-AppleInterfaceStyle", "Dark"]
        }
    }

    /// Suffixe des noms de captures (« 01-accueil-vide-clair »).
    var label: String {
        switch self {
        case .light: "clair"
        case .dark: "sombre"
        }
    }
}

/// Tailles de texte du système imposées au lancement (`extraArguments` de `launch(seed:)`).
enum UITestTextSize {
    /// Dynamic Type « Accessibilité 3 » (AX3, `accessibilityExtraExtraExtraLarge`), la plus grande taille.
    static let accessibilityXXXL = [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
}

/// Parcours des écrans principaux de l'app, partagé par les captures (`ScreenshotTests`) et les
/// audits d'accessibilité (`AccessibilityAuditUITests`) : une seule navigation à maintenir.
///
/// À chaque écran atteint, `onScreen` reçoit son nom (« 08-saisie-manche-penalite-sombre ») ; le
/// parcours n'impose aucune assertion sur le contenu, mais **échoue** (`TourError`) dès qu'un écran
/// ou un contrôle attendu n'apparaît pas. Les données viennent de `UITestSeed` : le stockage est en
/// mémoire, chaque jeu de données impose donc un nouveau lancement (6 lancements par parcours complet).
@MainActor
final class ScreenTour {
    struct TourError: Error, CustomStringConvertible {
        let description: String
    }

    /// Pause avant chaque capture : fin des transitions (push, feuilles) et des animations de liste.
    private static let settleDelay: TimeInterval = 0.6

    private let app: XCUIApplication
    private let appearance: UITestAppearance
    private let extraArguments: [String]
    private let label: String
    private let onScreen: (String) -> Void
    private var appearanceChecked = false

    /// - Parameters:
    ///   - label: suffixe des noms (par défaut celui de l'apparence ; « ax3 » pour la passe Dynamic Type).
    init(
        app: XCUIApplication,
        appearance: UITestAppearance,
        extraArguments: [String] = [],
        label: String? = nil,
        onScreen: @escaping (String) -> Void
    ) {
        self.app = app
        self.appearance = appearance
        self.extraArguments = extraArguments
        self.label = label ?? appearance.label
        self.onScreen = onScreen
    }

    // MARK: Parcours

    /// 14 écrans, 6 lancements : accueil vide, création, règles, paramètres ; accueil avec reprise,
    /// tableau 8 joueurs (haut puis bas) ; saisie avec aperçu de pénalité ; historique, parties
    /// terminées ; fin de partie à co-vainqueurs ; consultation des cartes, saisie par cartes, sélecteur.
    func runFullTour() throws {
        // Lancement 1 : stockage vide.
        launch(nil)
        try require(element("home.newGame"), "accueil (« Nouvelle partie »)")
        stop(1, "accueil-vide")
        try tap("home.newGame", "« Nouvelle partie »")
        try require(app.textFields["setup.player.1"], "formulaire de création (prénom du joueur 1)")
        stop(2, "creation-partie")
        try tap("setup.cancel", "« Annuler » de la création")
        try require(element("home.rules"), "retour à l'accueil")
        try tap("home.rules", "accès aux règles")
        try require(app.navigationBars["Règles de comptage"], "écran des règles")
        stop(3, "regles")
        try goBack()
        try tap("home.settings", "accès aux paramètres")
        try require(element("settings.haptics"), "écran des paramètres")
        stop(4, "parametres")

        // Lancement 2 : 8 joueurs, 2 manches.
        launch(.eightPlayers)
        try require(element("home.resume"), "accueil avec « Reprendre la partie »")
        stop(5, "accueil-reprise")
        try tap("home.resume", "« Reprendre la partie »")
        try require(element("game.addRound"), "tableau des scores à 8 joueurs")
        stop(6, "tableau-8-joueurs")
        app.swipeUp()
        stop(7, "tableau-8-joueurs-suite")

        // Lancement 3 : saisie d'une manche avec aperçu de la pénalité (10 / 24 / 10, Alice clôture :
        // égalité avec Chloé, donc score doublé à 20).
        launch(.nearEnd)
        try openRoundEntry()
        let form = roundForm
        form.type("10", into: app.textFields["round.score.0"])
        form.type("24", into: app.textFields["round.score.1"])
        form.type("10", into: app.textFields["round.score.2"])
        form.tap(app.buttons["round.closer.0"])
        form.dismissKeyboard()
        form.bringIntoView(element("round.preview.0"))
        stop(8, "saisie-manche-penalite")

        // Lancement 4 : partie active de 4 joueurs et deux parties closes.
        launch(.withHistory)
        try tap("home.resume", "« Reprendre la partie »", waiting: "accueil avec reprise")
        try require(element("game.addRound"), "tableau des scores")
        try openHistoryFromBoard()
        stop(9, "historique")
        try goBack()
        try require(element("game.addRound"), "retour au tableau")
        try goBack()
        try tap("home.finishedGames", "accès aux parties terminées")
        try require(element("finishedGames.game.0"), "liste des parties terminées")
        stop(10, "parties-terminees")

        // Lancement 5 : fin de partie, co-vainqueurs Bob et Chloé.
        launch(.tieEnd)
        try tap("home.resume", "« Reprendre la partie »", waiting: "accueil avec reprise")
        try require(element("gameOver.winners"), "écran de fin de partie (vainqueurs)")
        stop(11, "fin-de-partie-co-vainqueurs")

        // Lancement 6 : manche saisie en cartes (Alice, total 6).
        launch(.withCards)
        try tap("home.resume", "« Reprendre la partie »", waiting: "accueil avec reprise")
        try require(element("game.addRound"), "tableau des scores")
        try openHistoryFromBoard()
        try tap("history.viewCards.1", "« Voir les cartes de la manche 1 »")
        let cardsSheet = app.navigationBars["Cartes · manche 1"]
        try require(cardsSheet, "consultation des cartes de la manche 1")
        stop(12, "cartes-consultation")
        cardsSheet.buttons["OK"].tap()
        guard cardsSheet.waitForNonExistence(timeout: 5) else {
            throw TourError(description: "La consultation des cartes ne s'est pas fermée.")
        }
        try tap("history.round.1", "ligne de la manche 1 (correction)")
        try require(app.buttons["round.save"], "feuille de correction de la manche 1")
        stop(13, "saisie-par-cartes")
        roundForm.tap(app.buttons["cards.cell.0.0.0"])
        try require(app.buttons["cards.valuePicker.0"], "sélecteur de valeur des cartes")
        stop(14, "selecteur-valeur-cartes")
    }

    /// Passe Dynamic Type (à lancer avec `UITestTextSize.accessibilityXXXL`) : création, tableau
    /// à 8 joueurs et saisie de manche, les écrans où les actions principales risquent d'être tronquées.
    func runLargeTextTour() throws {
        launch(nil)
        try require(element("home.newGame"), "accueil (« Nouvelle partie »)")
        stop(1, "accueil-vide")
        try tap("home.newGame", "« Nouvelle partie »")
        try require(app.textFields["setup.player.1"], "formulaire de création (prénom du joueur 1)")
        stop(2, "creation-partie")

        launch(.eightPlayers)
        try tap("home.resume", "« Reprendre la partie »", waiting: "accueil avec reprise")
        try require(element("game.addRound"), "tableau des scores à 8 joueurs")
        stop(3, "tableau-8-joueurs")

        launch(.nearEnd)
        try openRoundEntry()
        stop(4, "saisie-manche")
    }

    // MARK: Navigation

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Relance l'app (terminée si besoin) avec l'apparence, la taille de texte et le jeu de données.
    private func launch(_ seed: SeedScenario?) {
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch(seed: seed, extraArguments: appearance.launchArguments + extraArguments)
    }

    @discardableResult
    private func require(
        _ target: XCUIElement,
        _ description: String,
        timeout: TimeInterval = 15
    ) throws -> XCUIElement {
        guard target.waitForExistence(timeout: timeout) else {
            throw TourError(description: "Écran ou contrôle attendu absent : \(description).")
        }
        return target
    }

    /// Touche l'élément d'identifiant donné ; `waiting` : attend d'abord un élément précis (accueil).
    private func tap(_ identifier: String, _ description: String, waiting: String? = nil) throws {
        try require(element(identifier), waiting ?? description).tap()
    }

    private func goBack() throws {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        try require(back, "bouton de retour de la barre de navigation", timeout: 5)
        back.tap()
    }

    private func openRoundEntry() throws {
        try tap("home.resume", "« Reprendre la partie »", waiting: "accueil avec reprise")
        try tap("game.addRound", "« Ajouter une manche »")
        try require(app.buttons["round.save"], "feuille de saisie de manche (« Enregistrer »)")
    }

    /// Tableau → lien « Historique » (au bas de la liste) → écran « Historique ».
    private func openHistoryFromBoard() throws {
        let link = app.buttons["game.historyLink"]
        for _ in 0..<6 where !(link.exists && link.isHittable) {
            app.swipeUp()
        }
        try require(link, "lien vers l'historique", timeout: 10).tap()
        try require(app.navigationBars["Historique"], "écran « Historique »")
    }

    private var roundForm: FormDriver {
        FormDriver(
            app: app,
            actionButton: app.buttons["round.save"],
            actionAreaElements: [
                element("round.blockingReasons"),
                element("round.closerPreview"),
            ],
            keyboardDoneButton: app.buttons["round.keyboardDone"]
        )
    }

    // MARK: Étapes

    private func stop(_ number: Int, _ slug: String) {
        Thread.sleep(forTimeInterval: Self.settleDelay)
        let name = String(format: "%02d", number) + "-\(slug)-\(label)"
        if !appearanceChecked {
            appearanceChecked = true
            checkAppearanceIsApplied(on: name)
        }
        onScreen(name)
    }

    /// Luminance moyenne de l'écran : sombre < 0,45 ; clair > 0,55. Garde-fou contre un thème non
    /// appliqué (captures « sombres » en réalité claires, audit de contraste sur le mauvais thème).
    private func checkAppearanceIsApplied(on name: String) {
        guard let cgImage = app.screenshot().image.cgImage,
              let luminance = Self.meanLuminance(of: cgImage) else {
            XCTFail("Capture illisible : apparence non vérifiable (\(name)).")
            return
        }
        switch appearance {
        case .dark:
            XCTAssertLessThan(
                luminance, 0.45,
                "Thème sombre non appliqué (luminance moyenne \(luminance)) ; vérifier -AppleInterfaceStyle Dark."
            )
        case .light:
            XCTAssertGreaterThan(
                luminance, 0.55,
                "Thème clair non appliqué (luminance moyenne \(luminance))."
            )
        }
    }

    /// Luminance relative moyenne (0 noir, 1 blanc) sur une réduction 16 × 16.
    private static func meanLuminance(of image: CGImage) -> Double? {
        let side = 16
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * side)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var total = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[offset])
            let green = Double(pixels[offset + 1])
            let blue = Double(pixels[offset + 2])
            total += (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
        }
        return total / Double(side * side)
    }
}
