import XCTest

/// Tests UI de lancement : l'app démarre sur l'accueil, sans écran d'erreur de stockage.
final class LaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsHomeScreen() throws {
        let app = XCUIApplication()
        app.launch(seed: nil)

        XCTAssertTrue(
            app.navigationBars["TableScore"].waitForExistence(timeout: 15),
            "Le titre de l'écran d'accueil doit apparaître."
        )
        XCTAssertTrue(
            app.buttons["home.newGame"].exists,
            "L'action principale « Nouvelle partie » doit être présente."
        )
    }

    @MainActor
    func testSeededLaunchShowsHomeWithoutStorageError() throws {
        let app = XCUIApplication()
        app.launch(seed: .withHistory)

        XCTAssertTrue(
            app.navigationBars["TableScore"].waitForExistence(timeout: 15),
            "Le jeu de données doit s'appliquer sans bloquer l'accueil."
        )
        XCTAssertFalse(
            app.buttons["storageError.retry"].exists,
            "Aucune erreur de stockage ne doit être affichée."
        )
    }
}
