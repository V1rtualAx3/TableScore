import XCTest

/// Prototype P2 « Scanner les cartes » (décision utilisateur du 2026-10-18).
///
/// Sur simulateur, aucun appareil photo : le bouton `scan.start.<position>` doit être **absent**
/// (saisie manuelle inchangée). Le parcours de vérification est testé avec un résultat de lecture
/// simulé (`-scanFixture <nom>`, builds Debug, exige `-uiTesting`) qui passe par la vraie logique
/// de reconnaissance, sans caméra ni demande d'autorisation :
/// - `complete` : 12 cartes, total brut 54 ;
/// - `partial` : 8 cartes + 1 case à vérifier (colonne 3, rangée 2), colonne 4 vide ; total
///   provisoire 19.
///
/// Identifiants (littéraux, cf. `AccessibilityID.Scan`) : `scan.start.<position>`, `scan.cancel`,
/// `scan.review.summary`, `scan.review.use`, `scan.review.confirmReplace`.
final class CardScanUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testScanOptionIsHiddenWithoutCamera() throws {
        #if targetEnvironment(simulator)
        let robot = CardScanRobot(app: XCUIApplication())
        robot.openCardsEntry(fixture: nil)
        let cell = robot.app.buttons["cards.cell.0.0.0"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "La grille de saisie manuelle doit rester disponible.")
        XCTAssertFalse(robot.app.buttons["scan.start.0"].exists, "Sans appareil photo, aucun bouton de scan.")
        #else
        throw XCTSkip("Simulateur uniquement : un iPhone réel dispose d'un appareil photo.")
        #endif
    }

    @MainActor
    func testUsingScannedGridPrefillsCards() throws {
        let robot = CardScanRobot(app: XCUIApplication())
        robot.openCardsEntry(fixture: "complete")
        robot.startScan()

        let summary = robot.element("scan.review.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "Écran de vérification attendu.")
        XCTAssertTrue(summary.label.contains("12\u{00A0}cartes lues sur 12"), "Bilan : \(summary.label)")

        let use = robot.app.buttons["scan.review.use"]
        XCTAssertTrue(use.isEnabled)
        use.tap()
        XCTAssertTrue(robot.waitForDisappearance(of: use), "La vérification doit se fermer après « Utiliser ».")

        let total = robot.element("cards.total.0")
        robot.reveal(total)
        XCTAssertTrue(total.label.contains("total brut 54 points"), "Grille pré-remplie attendue (54) : \(total.label)")
        XCTAssertFalse(total.label.contains("provisoire"), "Les 12 cartes doivent être renseignées : \(total.label)")
    }

    @MainActor
    func testUncertainCellsAndReplaceConfirmation() throws {
        let robot = CardScanRobot(app: XCUIApplication())
        robot.openCardsEntry(fixture: "partial")

        // Une carte déjà saisie à la main : le scan ne doit pas l'écraser sans confirmation.
        robot.tapRevealing(robot.app.buttons["cards.cell.0.0.0"])
        let five = robot.app.buttons["cards.valuePicker.5"]
        XCTAssertTrue(five.waitForExistence(timeout: 5))
        five.tap()
        let done = robot.app.buttons["cards.valuePicker.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(robot.waitForDisappearance(of: five), "Le sélecteur doit se fermer.")

        robot.startScan()
        let summary = robot.element("scan.review.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "Écran de vérification attendu.")
        XCTAssertTrue(summary.label.contains("8\u{00A0}cartes lues sur 12"), "Bilan : \(summary.label)")
        XCTAssertTrue(summary.label.contains("1\u{00A0}case à vérifier"), "Bilan : \(summary.label)")

        // Case incertaine signalée à VoiceOver (vide, « à vérifier »).
        let flagged = robot.app.buttons.matching(identifier: "cards.cell.0.2.1").allElementsBoundByIndex
        XCTAssertTrue(
            flagged.contains { (($0.value as? String) ?? "").contains("à vérifier") },
            "La case colonne 3, rangée 2 doit être signalée « à vérifier »."
        )

        let use = robot.app.buttons["scan.review.use"]
        use.tap()
        let replace = robot.app.buttons
            .matching(NSPredicate(format: "identifier == %@ OR label == %@", "scan.review.confirmReplace", "Remplacer"))
            .firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 5), "Confirmation « Remplacer les cartes saisies ? » attendue.")
        replace.tap()
        XCTAssertTrue(robot.waitForDisappearance(of: use), "La vérification doit se fermer après le remplacement.")

        let total = robot.element("cards.total.0")
        robot.reveal(total)
        XCTAssertTrue(
            total.label.contains("total brut 19 points, provisoire"),
            "Grille partielle attendue (19, provisoire) : \(total.label)"
        )
    }

    @MainActor
    func testCancelLeavesGridUntouched() throws {
        let robot = CardScanRobot(app: XCUIApplication())
        robot.openCardsEntry(fixture: "complete")
        robot.startScan()

        let cancel = robot.app.buttons["scan.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(robot.waitForDisappearance(of: cancel), "« Annuler » doit fermer le scan.")

        let total = robot.element("cards.total.0")
        robot.reveal(total)
        XCTAssertTrue(total.label.contains("total brut 0 point"), "Grille inchangée (vide) attendue : \(total.label)")
        XCTAssertTrue(total.label.contains("provisoire"), "Aucune carte ne doit avoir été ajoutée : \(total.label)")
    }
}

/// Feuille de manche (jeu `nearEnd`, manche 4), joueur 0 en mode « Cartes ».
@MainActor
private struct CardScanRobot {
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

    func openCardsEntry(fixture: String?) {
        app.launch(seed: .nearEnd, extraArguments: fixture.map { ["-scanFixture", $0] } ?? [])
        let resume = app.buttons["home.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 15), "La partie active doit pouvoir être reprise.")
        resume.tap()
        let addRound = app.buttons["game.addRound"]
        XCTAssertTrue(addRound.waitForExistence(timeout: 10))
        addRound.tap()
        XCTAssertTrue(app.buttons["round.save"].waitForExistence(timeout: 10))
        let cards = app.segmentedControls["round.inputMethod.0"].buttons["Cartes"]
        tapRevealing(cards)
        XCTAssertTrue(cards.isSelected, "Segment « Cartes » attendu sélectionné.")
    }

    func startScan(file: StaticString = #filePath, line: UInt = #line) {
        let scan = app.buttons["scan.start.0"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5), "Bouton « Scanner les cartes » attendu.", file: file, line: line)
        tapRevealing(scan, file: file, line: line)
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
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
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: target)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
