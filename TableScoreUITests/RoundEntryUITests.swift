import XCTest

/// Saisie d'une manche (Lot 2, T4) : aperçu de pénalité, négatifs et zéro, bouton bloqué tant que
/// la saisie est incomplète, protection contre le double tap.
///
/// Jeux de données (`UITestSeed`) :
/// - `nearEnd` : Alice 88, Bob 60, Chloé 23 après 3 manches (exemple 10/24/10 du cahier) ;
/// - `withHistory` : partie active de 4 joueurs après 4 manches.
final class RoundEntryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Scénarios

    @MainActor
    func testAddRoundWithPenaltyPreview() throws {
        let robot = RoundEntryRobot(app: XCUIApplication())
        robot.openRoundEntry(seed: .nearEnd, expectedTitle: "Manche 4")

        robot.typeScore("10", position: 0)
        robot.typeScore("24", position: 1)
        robot.typeScore("10", position: 2)
        robot.tapRevealing(robot.app.buttons["round.closer.0"])
        XCTAssertTrue(robot.app.buttons["round.closer.0"].isSelected, "Alice doit être la clôturante.")

        let preview = robot.element("round.preview.0")
        robot.reveal(preview)
        // Libellé VoiceOver de la ligne visible « 10 → 20 (score doublé : égalité avec Chloé) ».
        XCTAssertTrue(preview.label.contains("10, doublé à 20"), "Aperçu reçu : \(preview.label)")
        XCTAssertTrue(preview.label.contains("égalité avec Chloé"), "Aperçu reçu : \(preview.label)")
        XCTAssertTrue(preview.label.contains("108"), "Le cumul à venir doit apparaître : \(preview.label)")
        XCTAssertTrue(robot.app.buttons["round.save"].isEnabled)
        XCTAssertFalse(robot.element("round.blockingReasons").exists)
    }

    @MainActor
    func testNegativeAndZeroEntry() throws {
        let robot = RoundEntryRobot(app: XCUIApplication())
        robot.openRoundEntry(seed: .nearEnd, expectedTitle: "Manche 4")

        robot.typeScore("5", position: 0)
        let sign = robot.app.buttons["round.sign.0"]
        XCTAssertEqual(sign.label, "Rendre négatif le score d'Alice")
        sign.tap()
        XCTAssertEqual(sign.label, "Rendre positif le score d'Alice", "Le score d'Alice doit être devenu négatif.")
        robot.typeScore("0", position: 1)
        robot.typeScore("3", position: 2)
        robot.tapRevealing(robot.app.buttons["round.closer.1"])

        let bob = robot.element("round.preview.1")
        robot.reveal(bob)
        XCTAssertTrue(bob.label.contains("jamais doublé"), "Aperçu reçu : \(bob.label)")
        let alice = robot.element("round.preview.0")
        robot.reveal(alice)
        XCTAssertTrue(alice.label.contains("moins 5"), "Aperçu reçu : \(alice.label)")

        let save = robot.app.buttons["round.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(robot.waitForDisappearance(of: save), "La feuille doit se fermer après l'enregistrement.")

        let aliceRow = robot.element("game.player.0")
        XCTAssertTrue(aliceRow.waitForExistence(timeout: 5))
        XCTAssertTrue(aliceRow.label.contains("83"), "Total attendu 88 − 5 = 83 : \(aliceRow.label)")
    }

    @MainActor
    func testSaveDisabledUntilComplete() throws {
        let robot = RoundEntryRobot(app: XCUIApplication())
        robot.openRoundEntry(seed: .nearEnd, expectedTitle: "Manche 4")

        let save = robot.app.buttons["round.save"]
        XCTAssertFalse(save.isEnabled, "Rien n'est saisi : enregistrement impossible.")
        XCTAssertTrue(robot.element("round.blockingReasons").exists)

        robot.typeScore("12", position: 0)
        robot.typeScore("0", position: 1)
        XCTAssertFalse(save.isEnabled, "Un score manque.")

        // « − » seul n'est pas un score.
        robot.tapRevealing(robot.app.buttons["round.sign.2"])
        robot.tapRevealing(robot.app.buttons["round.closer.2"])
        XCTAssertFalse(save.isEnabled, "« − » seul ne doit pas être accepté.")
        XCTAssertTrue(robot.element("round.blockingReasons").exists)

        robot.tapRevealing(robot.app.buttons["round.sign.2"]) // retire le signe : champ vide
        robot.typeScore("4", position: 2)
        XCTAssertTrue(save.isEnabled, "Saisie complète : enregistrement possible.")
        XCTAssertFalse(robot.element("round.blockingReasons").exists)
    }

    @MainActor
    func testDoubleTapSavesOnce() throws {
        let robot = RoundEntryRobot(app: XCUIApplication())
        robot.openRoundEntry(seed: .withHistory, expectedTitle: "Manche 5")

        robot.typeScore("1", position: 0)
        robot.typeScore("2", position: 1)
        robot.typeScore("3", position: 2)
        robot.typeScore("4", position: 3)
        robot.tapRevealing(robot.app.buttons["round.closer.0"])

        let save = robot.app.buttons["round.save"]
        XCTAssertTrue(save.isEnabled)
        save.doubleTap()
        XCTAssertTrue(robot.waitForDisappearance(of: save), "La feuille doit se fermer après l'enregistrement.")

        // Une seule manche ajoutée : la prochaine saisie est la manche 6 (et non 7).
        let addRound = robot.app.buttons["game.addRound"]
        XCTAssertTrue(addRound.waitForExistence(timeout: 5))
        addRound.tap()
        XCTAssertTrue(robot.app.buttons["round.save"].waitForExistence(timeout: 5))
        XCTAssertTrue(robot.app.navigationBars["Manche 6"].exists)
        XCTAssertFalse(robot.app.navigationBars["Manche 7"].exists)
        robot.app.buttons["round.cancel"].tap()
    }
}

/// Actions communes de la feuille de saisie (identifiants `AccessibilityID.Round.*` en littéral).
///
/// Touchers et défilement via `FormDriver` : la zone d'action fixe (résumé + « Enregistrer ») et
/// le clavier recouvrent le bas du formulaire, et `isHittable` ne le détecte pas.
@MainActor
private struct RoundEntryRobot {
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

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Saisie dans le champ du joueur `position`, après obtention vérifiée du focus clavier.
    func typeScore(_ text: String, position: Int, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields["round.score.\(position)"]
        form.type(text, into: field, file: file, line: line)
    }

    /// Rend l'élément touchable (clavier fermé, défilement) puis le touche.
    func tapRevealing(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        reveal(target, file: file, line: line)
        target.tap()
    }

    /// Ferme le clavier puis fait défiler jusqu'à ce que l'élément (éventuellement pas encore créé
    /// par la liste paresseuse, comme les lignes d'aperçu) soit entièrement visible et touchable.
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
