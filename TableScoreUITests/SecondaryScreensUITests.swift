import XCTest

/// Écrans secondaires (Lot 2, T7) : parties terminées, règles, paramètres.
/// Jeu `withHistory` : une partie interrompue (la plus récente, position 0), une partie terminée
/// (position 1) et une partie active.
final class SecondaryScreensUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    func testDeleteFinishedGameConfirmation() throws {
        let app = XCUIApplication()
        app.launch(seed: .withHistory)

        let link = element(app, "home.finishedGames")
        XCTAssertTrue(link.waitForExistence(timeout: 15), "L'accès aux parties terminées doit exister.")
        link.tap()

        let first = element(app, "finishedGames.game.0")
        let second = element(app, "finishedGames.game.1")
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(second.exists, "Deux parties closes sont attendues.")
        XCTAssertFalse(element(app, "finishedGames.game.2").exists)

        // Annuler la confirmation ne supprime rien.
        first.swipeLeft()
        app.buttons["Supprimer"].tap()
        let confirm = app.buttons["Supprimer définitivement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "La suppression doit être confirmée.")
        app.buttons["Annuler"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists, "Annuler ne doit rien supprimer.")

        // Confirmer supprime exactement une partie.
        first.swipeLeft()
        app.buttons["Supprimer"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertFalse(
            element(app, "finishedGames.game.1").waitForExistence(timeout: 2),
            "Une seule partie doit rester dans la liste."
        )
    }

    @MainActor
    func testRulesScreenIsReachable() throws {
        let app = XCUIApplication()
        app.launch(seed: nil)

        let link = element(app, "home.rules")
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.tap()
        XCTAssertTrue(app.navigationBars["Règles de comptage"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Le doublement n'est jamais appliqué à 0 ni à un score négatif."].exists,
            "La règle de non-doublement de 0 et des négatifs doit être visible."
        )
    }

    @MainActor
    func testDeleteAllDataRequiresTwoConfirmations() throws {
        let app = XCUIApplication()
        app.launch(seed: .withHistory)

        let settings = element(app, "home.settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()

        XCTAssertTrue(element(app, "settings.haptics").waitForExistence(timeout: 10))
        let delete = app.buttons["settings.deleteAllData"]
        XCTAssertTrue(delete.exists)

        // Première étape puis annulation : rien n'est supprimé.
        delete.tap()
        XCTAssertTrue(app.buttons["Continuer"].waitForExistence(timeout: 5))
        app.buttons["Annuler"].tap()
        XCTAssertFalse(app.alerts["Dernière confirmation"].exists)

        // Deux confirmations : tout est supprimé.
        delete.tap()
        XCTAssertTrue(app.buttons["Continuer"].waitForExistence(timeout: 5))
        app.buttons["Continuer"].tap()
        // L'alerte est présentée après la fermeture de la boîte de dialogue (court délai volontaire).
        let finalAlert = app.alerts["Dernière confirmation"]
        XCTAssertTrue(finalAlert.waitForExistence(timeout: 10), "La dernière confirmation doit apparaître.")
        let confirmAll = finalAlert.buttons["Tout supprimer"]
        XCTAssertTrue(confirmAll.waitForExistence(timeout: 5))
        confirmAll.tap()
        XCTAssertTrue(
            finalAlert.waitForNonExistence(timeout: 5),
            "L'alerte doit se refermer après la suppression."
        )

        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.buttons["home.newGame"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["home.resume"].exists, "Plus aucune partie à reprendre.")
    }
}
