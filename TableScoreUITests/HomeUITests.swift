import XCTest

/// Accueil : action principale selon l'état, confirmation de remplacement, reprise après relance.
final class HomeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func waitForHome(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["TableScore"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testEmptyStateOffersNewGameOnly() throws {
        let app = XCUIApplication()
        app.launch(seed: nil)
        waitForHome(app)

        XCTAssertTrue(app.buttons["home.newGame"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home.resume"].exists)
        XCTAssertTrue(app.buttons["home.finishedGames"].exists || app.staticTexts["Parties terminées"].exists)
    }

    @MainActor
    func testActiveGameOffersResumeAndOpensScoreboard() throws {
        let app = XCUIApplication()
        app.launch(seed: .nearEnd)
        waitForHome(app)

        let resume = app.buttons["home.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.newGame"].exists, "« Nouvelle partie » reste disponible en secondaire.")
        resume.tap()
        XCTAssertTrue(app.buttons["game.addRound"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testNewGameWithActiveGameAsksConfirmation() throws {
        let app = XCUIApplication()
        app.launch(seed: .nearEnd)
        waitForHome(app)

        app.buttons["home.newGame"].tap()
        let confirm = app.buttons["Abandonner et commencer"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["setup.start"].exists, "Rien ne démarre avant confirmation.")

        // Annuler laisse la partie intacte.
        app.buttons["Annuler"].firstMatch.tap()
        XCTAssertTrue(app.buttons["home.resume"].waitForExistence(timeout: 5))

        app.buttons["home.newGame"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["setup.start"].waitForExistence(timeout: 10))
    }

    /// Relance réelle sur un store fichier dédié (`-uiTestingPersistentStore`, Debug uniquement),
    /// distinct du vrai store ; `-resetUITestStore` le vide au premier lancement seulement.
    @MainActor
    func testResumeAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingPersistentStore", "-resetUITestStore"]
        app.launch()
        waitForHome(app)
        XCTAssertFalse(app.buttons["home.resume"].exists, "Le store dédié doit démarrer vide.")

        app.buttons["home.newGame"].tap()
        let first = app.textFields["setup.player.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        first.typeText("Alice")
        let second = app.textFields["setup.player.2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
        second.typeText("Bob")
        let start = app.buttons["setup.start"]
        XCTAssertTrue(start.isEnabled)
        start.tap()
        XCTAssertTrue(app.buttons["game.addRound"].waitForExistence(timeout: 10))

        app.terminate()

        // Relance sans réinitialisation : la partie doit être proposée à la reprise.
        app.launchArguments = ["-uiTesting", "-uiTestingPersistentStore"]
        app.launch()
        waitForHome(app)
        XCTAssertTrue(app.buttons["home.resume"].waitForExistence(timeout: 10))

        app.buttons["home.resume"].tap()
        XCTAssertTrue(app.buttons["game.addRound"].waitForExistence(timeout: 10))
    }
}
