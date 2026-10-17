import XCTest

/// Création de partie : parcours d'accueil -> feuille -> tableau des scores.
final class NewGameUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func openNewGameSheet(_ app: XCUIApplication) {
        app.launch(seed: nil)
        let newGame = app.buttons["home.newGame"]
        XCTAssertTrue(newGame.waitForExistence(timeout: 15), "« Nouvelle partie » doit être présent.")
        newGame.tap()
        XCTAssertTrue(
            app.textFields["setup.player.1"].waitForExistence(timeout: 10),
            "Le premier champ de prénom doit apparaître."
        )
    }

    /// Fait défiler le formulaire jusqu'à ce que l'élément soit atteignable (liste paresseuse).
    @MainActor
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !(element.exists && element.isHittable), attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
    }

    @MainActor
    func testCreateGameTwoPlayers() throws {
        let app = XCUIApplication()
        openNewGameSheet(app)

        let start = app.buttons["setup.start"]
        XCTAssertTrue(start.exists)
        XCTAssertFalse(start.isEnabled, "« Commencer » est désactivé sans prénoms.")

        let first = app.textFields["setup.player.1"]
        first.tap()
        first.typeText("Alice")
        let second = app.textFields["setup.player.2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
        second.typeText("Bob")

        XCTAssertTrue(start.isEnabled, "« Commencer » est actif avec deux prénoms valides.")
        start.tap()

        XCTAssertTrue(
            app.buttons["game.addRound"].waitForExistence(timeout: 15),
            "L'écran de partie doit s'afficher avec « Ajouter une manche »."
        )
    }

    @MainActor
    func testEightPlayersMax() throws {
        let app = XCUIApplication()
        openNewGameSheet(app)

        let addPlayer = app.buttons["setup.addPlayer"]
        for _ in 3...8 {
            scrollIntoView(addPlayer, in: app)
            XCTAssertTrue(addPlayer.isEnabled)
            addPlayer.tap()
        }
        scrollIntoView(addPlayer, in: app)
        XCTAssertTrue(addPlayer.exists)
        XCTAssertFalse(addPlayer.isEnabled, "L'ajout est désactivé à 8 joueurs.")
        XCTAssertTrue(app.textFields["setup.player.8"].exists || app.textFields["setup.player.8"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["setup.player.9"].exists)
    }
}
