import XCTest

/// Historique et correction (cahier §4.6, §10 n° 11–12 ; docs/ux/lot2-parcours.md §2.5).
///
/// Jeu `withHistory` : partie active Alice/Bob/Chloé/Dimitri, 4 manches, totaux 41/60/34/53.
/// Dépendances : accès à l'historique via le tableau (T3 : `game.menu` → `game.menu.history`, ou
/// `game.historyLink`) ; formulaire de correction et alerte de fin anticipée (T4 :
/// `round.score.<position>`, `round.save`, `round.cancel`, bouton « Revenir à la saisie »).
/// Tant que le formulaire T4 n'existe pas, les étapes qui en dépendent sont marquées « ignorées »
/// (`XCTSkip`) avec un message explicite, jamais réussies par défaut.
final class HistoryUITests: XCTestCase {
    private let timeout: TimeInterval = 10

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Tests

    /// Ouvre la manche 1 depuis l'historique : la feuille de correction s'ouvre ; si le formulaire
    /// est disponible, Chloé passe de 10 à 11 et les cumuls des manches suivantes sont recalculés.
    @MainActor
    func testEditOldRoundRecomputes() throws {
        let app = XCUIApplication()
        app.launch(seed: .withHistory)
        openHistory(app)

        let firstRound = try scrollTo(app.buttons["history.round.1"], in: app)
        firstRound.tap()
        XCTAssertTrue(
            waitForEntrySheet(app),
            "Toucher une manche doit ouvrir la feuille de correction."
        )

        let chloeField = app.textFields["round.score.2"]
        guard chloeField.waitForExistence(timeout: timeout) else {
            throw XCTSkip("Formulaire de correction (T4) indisponible : recalcul non vérifié.")
        }
        replaceText(in: chloeField, with: "11")
        let save = app.buttons["round.save"]
        XCTAssertTrue(save.waitForExistence(timeout: timeout))
        save.tap()
        XCTAssertTrue(waitForDisappearance(of: save), "La feuille doit se fermer après la correction.")

        let correctedRound = try scrollTo(app.buttons["history.round.1"], in: app)
        XCTAssertTrue(correctedRound.label.contains("Chloé 11, total 11"), correctedRound.label)
        XCTAssertTrue(correctedRound.label.contains("Manche corrigée"), correctedRound.label)
        XCTAssertTrue(correctedRound.label.contains("Alice 10, total 10"), correctedRound.label)

        let lastRound = try scrollTo(app.buttons["history.round.4"], in: app)
        XCTAssertTrue(lastRound.label.contains("Alice 9, total 31"), lastRound.label)
        XCTAssertTrue(lastRound.label.contains("Chloé 6, total 35"), lastRound.label)
    }

    /// Suppression confirmée de la dernière manche puis « Annuler » : la manche revient à l'identique.
    @MainActor
    func testDeleteLastRoundUndo() throws {
        let app = XCUIApplication()
        app.launch(seed: .withHistory)
        openHistory(app)

        let lastRound = app.buttons["history.round.4"]
        XCTAssertTrue(lastRound.waitForExistence(timeout: timeout))
        let originalLabel = lastRound.label

        let delete = try scrollTo(app.buttons["history.deleteLastRound"], in: app)
        delete.tap()
        let confirm = app.buttons["Supprimer la manche 4"]
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout), "Une confirmation doit être demandée.")
        confirm.tap()

        XCTAssertTrue(waitForDisappearance(of: app.buttons["history.round.4"]), "La manche 4 doit disparaître.")
        XCTAssertTrue(app.buttons["history.round.3"].waitForExistence(timeout: timeout))
        let undo = app.buttons["history.undoDeletion"]
        XCTAssertTrue(undo.waitForExistence(timeout: timeout), "Le bandeau « Annuler » doit apparaître.")
        undo.tap()

        let restored = app.buttons["history.round.4"]
        XCTAssertTrue(restored.waitForExistence(timeout: timeout), "La manche 4 doit être rétablie.")
        XCTAssertEqual(restored.label, originalLabel, "La manche rétablie doit être identique.")
        XCTAssertTrue(restored.label.contains("Alice 9, total 41"), restored.label)
        XCTAssertTrue(waitForDisappearance(of: undo), "Le bandeau disparaît après l'annulation.")
    }

    /// Correction de la manche 1 qui fait atteindre 100 points à Dimitri : une décision explicite est
    /// demandée (§10 n° 12) ; « Revenir à la saisie » puis abandon : rien n'est effacé.
    /// Dépend de T4 (formulaire + alerte « La partie aurait dû se terminer »).
    @MainActor
    func testCorrectionCreatesEarlyFinishRequiresChoice() throws {
        let app = XCUIApplication()
        app.launch(seed: .withHistory)
        openHistory(app)

        let firstRound = try scrollTo(app.buttons["history.round.1"], in: app)
        let originalLabel = firstRound.label
        firstRound.tap()
        XCTAssertTrue(waitForEntrySheet(app), "Toucher une manche doit ouvrir la feuille de correction.")

        let dimitriField = app.textFields["round.score.3"]
        guard dimitriField.waitForExistence(timeout: timeout) else {
            throw XCTSkip("Formulaire de correction (T4) indisponible : fin anticipée non vérifiée.")
        }
        replaceText(in: dimitriField, with: "100")
        let save = app.buttons["round.save"]
        XCTAssertTrue(save.waitForExistence(timeout: timeout))
        save.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: timeout), "Une décision explicite doit être demandée.")
        let back = alert.buttons["Revenir à la saisie"]
        XCTAssertTrue(back.exists, "Choix « Revenir à la saisie » attendu : \(alert.buttons.allElementsBoundByIndex.map(\.label))")
        back.tap()

        // Abandon de la correction (confirmation si le brouillon est modifié).
        let cancel = app.buttons["round.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: timeout))
        cancel.tap()
        let discard = app.buttons["Abandonner"]
        if discard.waitForExistence(timeout: 3) {
            discard.tap()
        }
        XCTAssertTrue(waitForDisappearance(of: cancel), "La feuille doit se fermer.")

        // Aucune manche supprimée, aucune correction écrite.
        XCTAssertTrue(app.buttons["history.round.4"].waitForExistence(timeout: timeout))
        let unchanged = try scrollTo(app.buttons["history.round.1"], in: app)
        XCTAssertEqual(unchanged.label, originalLabel)
        XCTAssertTrue(unchanged.label.contains("Dimitri 15, total 15"), unchanged.label)
    }

    // MARK: Navigation et utilitaires

    /// Accueil → « Reprendre la partie » → tableau → Historique.
    @MainActor
    private func openHistory(_ app: XCUIApplication) {
        let resume = app.buttons["home.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 15), "« Reprendre la partie » attendu sur l'accueil.")
        resume.tap()

        let menu = app.buttons["game.menu"]
        if menu.waitForExistence(timeout: timeout) {
            menu.tap()
            let item = app.buttons["game.menu.history"]
            XCTAssertTrue(item.waitForExistence(timeout: timeout), "Entrée « Historique » attendue dans le menu.")
            item.tap()
        } else {
            let link = app.buttons["game.historyLink"]
            XCTAssertTrue(link.waitForExistence(timeout: timeout), "Accès à l'historique attendu sur le tableau.")
            link.tap()
        }
        XCTAssertTrue(
            app.navigationBars["Historique"].waitForExistence(timeout: timeout),
            "L'écran Historique doit s'afficher."
        )
        XCTAssertTrue(app.buttons["history.round.4"].waitForExistence(timeout: timeout))
    }

    /// Fait défiler la liste (la manche la plus récente est en haut) jusqu'à rendre l'élément touchable.
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) throws -> XCUIElement {
        let list = app.collectionViews.firstMatch
        for _ in 0..<8 {
            if element.exists && element.isHittable { return element }
            list.swipeUp()
        }
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            list.swipeDown()
        }
        guard element.exists && element.isHittable else {
            XCTFail("Élément introuvable dans l'historique : \(element)")
            throw ElementNotFound()
        }
        return element
    }

    private struct ElementNotFound: Error {}

    @MainActor
    private func waitForEntrySheet(_ app: XCUIApplication) -> Bool {
        app.buttons["round.cancel"].waitForExistence(timeout: timeout)
            || app.buttons["round.save"].exists
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Remplace le contenu d'un champ (curseur placé en fin de champ, puis effacement).
    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        let deletions = String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2)
        field.typeText(deletions + text)
    }
}
