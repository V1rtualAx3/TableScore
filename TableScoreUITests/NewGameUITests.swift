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

        // Le bouton finit sous la zone « Commencer » et le clavier (le nouveau champ prend le
        // focus) : touchers dans la zone réellement visible, et chaque ajout est vérifié.
        let form = FormDriver(app: app, actionButton: app.buttons["setup.start"])
        let addPlayer = app.buttons["setup.addPlayer"]
        for number in 3...8 {
            form.bringIntoView(addPlayer)
            XCTAssertTrue(addPlayer.isEnabled, "L'ajout est possible à \(number - 1) joueurs.")
            addPlayer.tap()
            XCTAssertTrue(
                app.textFields["setup.player.\(number)"].waitForExistence(timeout: 5),
                "Le joueur \(number) doit avoir été ajouté."
            )
        }
        form.bringIntoView(addPlayer)
        XCTAssertFalse(addPlayer.isEnabled, "L'ajout est désactivé à 8 joueurs.")
        XCTAssertFalse(app.textFields["setup.player.9"].exists)
        form.bringIntoView(app.textFields["setup.player.8"])
    }
}
