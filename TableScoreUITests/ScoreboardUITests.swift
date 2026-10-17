import XCTest

/// Tableau des scores : 8 joueurs en très grande taille de texte (Dynamic Type accessibilité XXL).
final class ScoreboardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testScoreboardEightPlayersXXL() throws {
        let app = XCUIApplication()
        app.launch(
            seed: .eightPlayers,
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXL",
            ]
        )

        let resume = app.buttons["home.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 15), "« Reprendre la partie » doit être proposé.")
        resume.tap()

        let addRound = app.buttons["game.addRound"]
        XCTAssertTrue(addRound.waitForExistence(timeout: 10), "Le CTA doit être présent.")
        XCTAssertTrue(addRound.isHittable, "Le CTA fixé en bas doit rester atteignable en XXL.")

        // Les huit lignes sont atteignables par défilement vertical.
        for position in 0..<8 {
            let row = app.descendants(matching: .any)["game.player.\(position)"]
            var attempts = 0
            while !row.exists && attempts < 12 {
                app.swipeUp()
                attempts += 1
            }
            XCTAssertTrue(row.exists, "La ligne du joueur \(position) doit être accessible par défilement.")
        }
        XCTAssertTrue(addRound.isHittable, "Le CTA reste atteignable après défilement.")
    }
}
