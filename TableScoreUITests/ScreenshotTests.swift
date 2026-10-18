import XCTest

/// Captures d'écran automatisées de chaque parcours principal (cahier des charges §10 n° 17 et
/// §11 : thèmes clair et sombre, grande taille de texte) **et** audit d'accessibilité de chacun de
/// ces écrans (`AccessibilityAudit`, voir `AccessibilityAuditUITests.swift`).
///
/// Les captures sont des pièces jointes du résultat de tests (`.keepAlways`) : la CI les exporte du
/// `.xcresult` et les publie dans l'artefact « captures-ecran » (docs/captures/README.md).
///
/// Un test par thème enchaîne les écrans (navigation partagée : `ScreenTour`) pour limiter le nombre
/// de lancements de l'app : chaque écran est d'abord capturé, puis audité. Un défaut d'audit fait
/// échouer le test sans interrompre le parcours (toutes les captures restent produites) ; en
/// revanche, un écran attendu absent ou un thème non appliqué l'interrompt.
///
/// Noms : « NN-ecran-clair », « NN-ecran-sombre », « NN-ecran-ax3 ».
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        // Les défauts d'audit n'arrêtent pas le parcours ; une navigation impossible lève
        // `ScreenTour.TourError`, qui l'arrête.
        continueAfterFailure = true
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
    private func captureAndAuditFullTour(appearance: UITestAppearance) throws {
        let app = XCUIApplication()
        let tour = ScreenTour(app: app, appearance: appearance) { [self] name in
            attachScreenshot(of: app, named: name)
            AccessibilityAudit.run(on: app, screen: name, in: self)
        }
        try tour.runFullTour()
    }

    @MainActor
    func testCaptureAndAuditLightTheme() throws {
        try captureAndAuditFullTour(appearance: .light)
    }

    @MainActor
    func testCaptureAndAuditDarkTheme() throws {
        try captureAndAuditFullTour(appearance: .dark)
    }

    /// Dynamic Type AX3 (thème clair) : création, tableau à 8 joueurs et saisie de manche. Captures
    /// seules : l'audit des tailles de texte accessibles est une étape ultérieure.
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
