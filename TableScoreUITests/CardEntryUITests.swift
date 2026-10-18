import XCTest

/// Saisie par cartes dans la feuille de manche (Lot 3, cahier §3.3, §4.4 « Points | Cartes »).
///
/// Identifiants (en littéral, cf. `AccessibilityID`) : sélecteur `round.inputMethod.<position>`
/// (segments « Points » / « Cartes »), information `round.cardsNotice.<position>` ; composant de
/// grille : `cards.cell.<position>.<col>.<row>`, `cards.removeColumn.<position>.<col>`,
/// `cards.total.<position>`, `cards.valuePicker.<valeur>`.
///
/// Jeux de données : `nearEnd` (Alice 88, Bob 60, Chloé 23 ; manche 4) ; `withCards` (1 manche
/// où Alice est saisie en cartes, total 6). Consultation : `history.viewCards.<index>`.
final class CardEntryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Grille d'Alice, colonne 0 retirée : colonnes 1/2/3 (6), −2/−2/−2 (triplet non compté),
    /// 0/1/0 (1) ⇒ 7. Valeurs dans l'ordre de saisie du composant : rangée par rangée, de gauche
    /// à droite, colonne retirée ignorée, à partir de la case (colonne 1, rangée 0).
    private static let aliceValuesInReadingOrder = [1, -2, 0, 2, -2, 1, 3, -2, 0]

    @MainActor
    private func enterAliceGrid(_ robot: CardEntryRobot) {
        robot.tapRevealing(robot.app.buttons["cards.removeColumn.0.0"])
        robot.fillCards(Self.aliceValuesInReadingOrder, position: 0, startColumn: 1, startRow: 0, closesWhenComplete: true)
    }

    // MARK: Scénarios

    @MainActor
    func testCardGridWithRemovedColumnIsSaved() throws {
        let robot = CardEntryRobot(app: XCUIApplication())
        robot.openRoundEntry(seed: .nearEnd, expectedTitle: "Manche 4")

        robot.selectInputMethod("Cartes", position: 0)
        enterAliceGrid(robot)
        let total = robot.element("cards.total.0")
        robot.reveal(total)
        XCTAssertTrue(total.label.contains("total brut 7 points"), "Total de la grille attendu 7 : \(total.label)")

        robot.typeScore("10", position: 1)
        robot.typeScore("5", position: 2)
        robot.tapRevealing(robot.app.buttons["round.closer.1"])

        // Aperçu calculé par le moteur à partir du total de la grille : 88 + 7 = 95.
        let alice = robot.element("round.preview.0")
        robot.reveal(alice)
        XCTAssertTrue(alice.label.contains("95"), "Aperçu reçu : \(alice.label)")

        let save = robot.app.buttons["round.save"]
        XCTAssertTrue(save.isEnabled, "Grille complète et clôturant choisi : enregistrement possible.")
        save.tap()
        XCTAssertTrue(robot.waitForDisappearance(of: save), "La feuille doit se fermer après l'enregistrement.")

        let aliceRow = robot.element("game.player.0")
        XCTAssertTrue(aliceRow.waitForExistence(timeout: 5))
        XCTAssertTrue(aliceRow.label.contains("95"), "Total attendu 88 + 7 = 95 : \(aliceRow.label)")
    }

    @MainActor
    func testCardsToPointsIsPrefilled() throws {
        let robot = CardEntryRobot(app: XCUIApplication())
        robot.openRoundEntry(seed: .nearEnd, expectedTitle: "Manche 4")

        robot.selectInputMethod("Cartes", position: 0)
        let save = robot.app.buttons["round.save"]
        enterAliceGrid(robot)

        robot.selectInputMethod("Points", position: 0)
        let field = robot.app.textFields["round.score.0"]
        robot.reveal(field)
        XCTAssertEqual(field.value as? String, "7", "Le score doit être pré-rempli avec le total de la grille.")
        XCTAssertFalse(robot.element("round.cardsNotice.0").exists, "Grille complète : aucune information.")
        XCTAssertFalse(save.isEnabled, "Bob, Chloé et le clôturant manquent encore.")
    }

    @MainActor
    func testIncompleteGridWarnsWithoutErasing() throws {
        let robot = CardEntryRobot(app: XCUIApplication())
        robot.openRoundEntry(seed: .nearEnd, expectedTitle: "Manche 4")

        robot.selectInputMethod("Cartes", position: 0)
        robot.fillCards([5], position: 0, startColumn: 0, startRow: 0, closesWhenComplete: false)
        robot.selectInputMethod("Points", position: 0)

        let notice = robot.element("round.cardsNotice.0")
        robot.reveal(notice)
        XCTAssertTrue(notice.label.contains("La grille est incomplète"), "Information reçue : \(notice.label)")

        // Retour en cartes : la carte saisie est toujours là, l'information disparaît.
        robot.selectInputMethod("Cartes", position: 0)
        XCTAssertFalse(robot.element("round.cardsNotice.0").exists)
        let total = robot.element("cards.total.0")
        robot.reveal(total)
        XCTAssertTrue(total.label.contains("total brut 5 points, provisoire"), "Total partiel attendu 5 : \(total.label)")
    }

    @MainActor
    func testCorrectionReloadsCardGrid() throws {
        let robot = CardEntryRobot(app: XCUIApplication())
        robot.app.launch(seed: .withCards)
        robot.openHistory()

        let round = robot.app.buttons["history.round.1"]
        XCTAssertTrue(round.waitForExistence(timeout: 10))
        XCTAssertTrue(round.label.contains("Alice 6, saisi en cartes"), "Historique : \(round.label)")

        // Consultation en lecture seule.
        let viewCards = robot.app.buttons["history.viewCards.1"]
        XCTAssertTrue(viewCards.waitForExistence(timeout: 5))
        XCTAssertEqual(viewCards.label, "Voir les cartes de la manche 1")
        viewCards.tap()
        let cardsSheet = robot.app.navigationBars["Cartes · manche 1"]
        XCTAssertTrue(cardsSheet.waitForExistence(timeout: 5))
        let readOnlyTotal = robot.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Alice, total brut 6 points")).firstMatch
        XCTAssertTrue(readOnlyTotal.exists, "Total de la grille enregistrée attendu.")
        cardsSheet.buttons["OK"].tap()
        XCTAssertTrue(robot.waitForDisappearance(of: cardsSheet), "La consultation doit se fermer.")

        // Correction : la grille est rechargée en mode Cartes.
        round.tap()
        XCTAssertTrue(robot.app.buttons["round.save"].waitForExistence(timeout: 10))
        let cardsSegment = robot.app.segmentedControls["round.inputMethod.0"].buttons["Cartes"]
        XCTAssertTrue(cardsSegment.waitForExistence(timeout: 5))
        XCTAssertTrue(cardsSegment.isSelected, "La manche d'Alice a été saisie en cartes.")
        let total = robot.element("cards.total.0")
        robot.reveal(total)
        XCTAssertTrue(total.label.contains("total brut 6 points"), "Total rechargé attendu 6 : \(total.label)")
        robot.app.buttons["round.cancel"].tap()
    }
}

/// Actions de la feuille de saisie en mode cartes (défilement et touchers via `FormDriver`).
///
/// Composant de grille (`CardGridEditor`) : toucher une case ouvre une feuille de valeurs ; chaque
/// valeur choisie passe à la case vide suivante (rangée par rangée, colonnes retirées ignorées) ;
/// la feuille se ferme d'elle-même quand la grille est complète, sinon par « OK ».
@MainActor
private struct CardEntryRobot {
    let app: XCUIApplication

    private var form: FormDriver {
        FormDriver(
            app: app,
            actionButton: app.buttons["round.save"],
            actionAreaElements: [
                app.descendants(matching: .any)["round.blockingReasons"].firstMatch,
                app.descendants(matching: .any)["round.closerPreview"].firstMatch,
            ],
            keyboardDoneButton: app.buttons["round.keyboardDone"]
        )
    }

    func openRoundEntry(seed: SeedScenario, expectedTitle: String) {
        app.launch(seed: seed)
        let resume = app.buttons["home.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 15), "La partie active doit pouvoir être reprise.")
        resume.tap()
        let addRound = app.buttons["game.addRound"]
        XCTAssertTrue(addRound.waitForExistence(timeout: 10))
        addRound.tap()
        XCTAssertTrue(app.buttons["round.save"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars[expectedTitle].exists, "Titre attendu : \(expectedTitle)")
    }

    /// Accueil → « Reprendre la partie » → lien « Historique ».
    func openHistory() {
        let resume = app.buttons["home.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 15), "« Reprendre la partie » attendu sur l'accueil.")
        resume.tap()
        XCTAssertTrue(app.buttons["game.addRound"].waitForExistence(timeout: 10), "Tableau des scores attendu.")
        let link = app.buttons["game.historyLink"]
        for _ in 0..<6 where !(link.exists && link.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(link.waitForExistence(timeout: 10), "Lien vers l'historique attendu sur le tableau.")
        link.tap()
        XCTAssertTrue(app.navigationBars["Historique"].waitForExistence(timeout: 10))
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Segment « Points » ou « Cartes » du sélecteur du joueur `position`.
    func selectInputMethod(_ title: String, position: Int, file: StaticString = #filePath, line: UInt = #line) {
        let segment = app.segmentedControls["round.inputMethod.\(position)"].buttons[title]
        tapRevealing(segment, file: file, line: line)
        XCTAssertTrue(segment.isSelected, "Segment « \(title) » attendu sélectionné.", file: file, line: line)
    }

    /// Touche la case de départ puis les valeurs dans l'ordre de saisie du composant. Grille
    /// complétée : la feuille doit se fermer seule ; sinon elle est fermée par « OK ».
    func fillCards(
        _ values: [Int],
        position: Int,
        startColumn: Int,
        startRow: Int,
        closesWhenComplete: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        tapRevealing(app.buttons["cards.cell.\(position).\(startColumn).\(startRow)"], file: file, line: line)
        let done = app.buttons["cards.valuePicker.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Sélecteur de valeur attendu.", file: file, line: line)
        for value in values {
            let valueButton = app.buttons["cards.valuePicker.\(value)"]
            XCTAssertTrue(valueButton.waitForExistence(timeout: 5), "Valeur \(value) attendue.", file: file, line: line)
            if !valueButton.isHittable {
                // Feuille à mi-hauteur trop petite (grande police) : l'agrandir.
                app.swipeUp()
            }
            valueButton.tap()
        }
        if closesWhenComplete {
            XCTAssertTrue(
                waitForDisappearance(of: done),
                "Grille complète : le sélecteur doit se fermer.",
                file: file,
                line: line
            )
        } else {
            done.tap()
            XCTAssertTrue(waitForDisappearance(of: done), "Le sélecteur doit se fermer.", file: file, line: line)
        }
    }

    func typeScore(_ text: String, position: Int, file: StaticString = #filePath, line: UInt = #line) {
        form.type(text, into: app.textFields["round.score.\(position)"], file: file, line: line)
    }

    func tapRevealing(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        reveal(target, file: file, line: line)
        target.tap()
    }

    func reveal(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        form.dismissKeyboard(file: file, line: line)
        form.bringIntoView(target, file: file, line: line)
    }

    func waitForDisappearance(of target: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: target
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
