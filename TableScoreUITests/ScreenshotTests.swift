import XCTest

/// Captures d'écran automatisées de chaque parcours principal (cahier des charges §10 n° 17 et
/// §11 : thèmes clair et sombre, grande taille de texte). Les captures sont des pièces jointes du
/// résultat de tests (`.keepAlways`) : la CI les exporte du `.xcresult` et les publie dans
/// l'artefact « captures-ecran » (voir docs/captures/README.md).
///
/// Un test par thème enchaîne les écrans (navigation partagée : `ScreenTour`) pour limiter le
/// nombre de lancements de l'app. Aucune assertion sur le contenu des captures, mais le test échoue
/// si un écran attendu n'apparaît pas ou si le thème demandé n'est pas appliqué.
///
/// Noms : « NN-ecran-clair », « NN-ecran-sombre », « NN-ecran-ax3 ».
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Joint une capture de l'app au résultat de tests, conservée même en cas de succès.
    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func runFullTour(appearance: UITestAppearance) throws {
        let app = XCUIApplication()
        let tour = ScreenTour(app: app, appearance: appearance) { [self] name in
            attachScreenshot(of: app, named: name)
        }
        try tour.runFullTour()
    }

    @MainActor
    func testScreenshotsLightTheme() throws {
        try runFullTour(appearance: .light)
    }

    @MainActor
    func testScreenshotsDarkTheme() throws {
        try runFullTour(appearance: .dark)
    }

    /// Dynamic Type AX3 (thème clair) : création, tableau à 8 joueurs et saisie de manche.
    @MainActor
    func testScreenshotsAccessibilityLargeText() throws {
        let app = XCUIApplication()
        let tour = ScreenTour(
            app: app,
            appearance: .light,
            extraArguments: UITestTextSize.accessibilityXXXL,
            label: "ax3"
        ) { [self] name in
            attachScreenshot(of: app, named: name)
        }
        try tour.runLargeTextTour()
    }
}
