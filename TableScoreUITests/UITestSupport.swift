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
    /// Hauteur réservée au-dessus du bouton : résumé (≤ 3 lignes), espacement et marge intérieure
    /// de la zone d'action.
    var reservedAboveAction: CGFloat = 96
    /// Bouton « OK » de la barre du clavier (identifiant dédié, ex. `round.keyboardDone`).
    var keyboardDoneButton: XCUIElement?

    private static let margin: CGFloat = 8
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
        if actionButton.exists {
            bottom = min(bottom, actionButton.frame.minY - reservedAboveAction)
        }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            bottom = min(bottom, keyboard.frame.minY - Self.keyboardToolbarHeight)
        }
        top += Self.margin
        bottom -= Self.margin
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
