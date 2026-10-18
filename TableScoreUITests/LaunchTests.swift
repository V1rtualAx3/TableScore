import XCTest

/// Test UI de lancement (Lot 0) : l'application démarre et affiche l'accueil.
final class LaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsHomeScreen() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.navigationBars["TableScore"].waitForExistence(timeout: 15),
            "Le titre de l'écran d'accueil doit apparaître."
        )
        XCTAssertTrue(
            app.buttons["home.newGameButton"].exists,
            "L'action principale « Nouvelle partie » doit être présente."
        )
    }
}
