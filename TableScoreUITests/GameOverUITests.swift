import XCTest

/// Fin de partie : co-vainqueurs (seed `tieEnd`) et « Rejouer avec les mêmes joueurs ».
final class GameOverUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func openTieEnd(_ app: XCUIApplication) {
        app.launch(seed: .tieEnd)
        let resume = app.buttons["home.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 15), "La partie du jeu de données doit être reprenable.")
        resume.tap()
    }

    @MainActor
    func testGameOverCoWinners() throws {
        let app = XCUIApplication()
        openTieEnd(app)

        XCTAssertTrue(
            app.staticTexts["gameOver.title"].waitForExistence(timeout: 10),
            "Le titre « Partie terminée » doit s'afficher."
        )
        let winners = app.descendants(matching: .any)["gameOver.winners"]
        XCTAssertTrue(winners.waitForExistence(timeout: 5))
        XCTAssertTrue(winners.label.contains("Bob"), "Bob est co-vainqueur : \(winners.label)")
        XCTAssertTrue(winners.label.contains("Chloé"), "Chloé est co-vainqueur : \(winners.label)")
        XCTAssertFalse(winners.label.contains("Alice"), "Alice (105) ne gagne pas.")
        XCTAssertFalse(app.buttons["game.addRound"].exists, "Plus de nouvelle manche après la fin.")
    }

    @MainActor
    func testReplaySamePlayers() throws {
        let app = XCUIApplication()
        openTieEnd(app)

        let replay = app.buttons["gameOver.replay"]
        XCTAssertTrue(replay.waitForExistence(timeout: 10))
        replay.tap()

        XCTAssertTrue(
            app.buttons["game.addRound"].waitForExistence(timeout: 10),
            "La nouvelle partie doit proposer « Ajouter une manche »."
        )
        let firstRound = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Manche 1")).firstMatch
        XCTAssertTrue(firstRound.waitForExistence(timeout: 5), "La nouvelle partie démarre à « Manche 1 ».")
        XCTAssertFalse(app.staticTexts["gameOver.title"].exists)
    }
}
