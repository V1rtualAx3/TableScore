import CoreGraphics
import Foundation
import TableScoreKit

/// Textes **purs** de l'écran de vérification d'une grille scannée (prototype P2).
///
/// Aucune règle de score : totaux, triplets et colonnes retirées restent calculés par
/// `CardGrid.evaluate()` dans l'éditeur réutilisé. Typographie : U+00A0 avant « : » et entre un
/// nombre et son nom ; U+202F avant « ? ».
struct CardScanSummary: Equatable, Sendable {
    enum NoteKind: Equatable, Sendable {
        /// Case à confirmer ou photo inexploitable (symbole d'avertissement).
        case warning
        /// Information (colonne vide, cases sans lecture).
        case info
    }

    struct Note: Equatable, Sendable, Identifiable {
        let kind: NoteKind
        let text: String
        var id: String { text }
    }

    private static let nbsp = CardGridPresentation.nbsp
    private static let narrowNbsp = "\u{202F}"

    let result: CardScanResult
    let playerName: String

    /// Titre de la vérification : « Cartes d'Alice ».
    var title: String { Self.title(playerName: playerName) }

    static func title(playerName: String) -> String {
        "Cartes \(VerdictText.ofName(playerName))"
    }

    /// « 10 cartes lues sur 12 », « 1 carte lue sur 12 », « 0 carte lue sur 12 » (tout est à
    /// vérifier), « Aucune carte lue » (rien repéré).
    var headline: String {
        let count = result.recognizedCount
        let total = CardScanResult.cardCount
        if result.detectedCount == 0 { return "Aucune carte lue" }
        // Accord français : singulier pour 0 et 1.
        return count <= 1
            ? "\(count)\(Self.nbsp)carte lue sur \(total)"
            : "\(count)\(Self.nbsp)cartes lues sur \(total)"
    }

    /// « 2 cases à vérifier » ; `nil` s'il n'y en a aucune.
    var verifyText: String? {
        let count = result.uncertainCells.count
        guard count > 0 else { return nil }
        return count == 1 ? "1\(Self.nbsp)case à vérifier" : "\(count)\(Self.nbsp)cases à vérifier"
    }

    /// Cases jamais lues hors colonnes vides et hors cases incertaines.
    var unreadCellCount: Int {
        let emptyColumnCells = result.emptyColumns.count * CardGrid.rowCount
        return max(0, CardScanResult.cardCount - result.detectedCount - emptyColumnCells)
    }

    /// Messages affichés au-dessus de la grille (texte + symbole), dans l'ordre de lecture.
    var notes: [Note] {
        guard result.detectedCount > 0 else {
            return [Note(
                kind: .warning,
                text: "Reprenez la photo\(Self.nbsp): les 12\(Self.nbsp)cartes face visible, vues du dessus, "
                    + "bien éclairées et dans le cadre."
            )]
        }
        var notes: [Note] = []
        if !result.misplacedCells.isEmpty {
            notes.append(Note(kind: .warning, text: Self.positionsToVerifyText))
        }
        notes += result.uncertainCells.map { cell in
            Note(
                kind: .warning,
                text: Self.uncertainText(
                    cell: cell,
                    suggestion: result.suggestions[cell],
                    isMisplaced: result.misplacedCells.contains(cell)
                )
            )
        }
        notes += result.emptyColumns.map { column in
            Note(
                kind: .info,
                text: "Colonne \(column + 1)\(Self.nbsp): aucune carte lue. Si elle a été retirée pendant la manche, "
                    + "touchez «\(Self.nbsp)\(CardGridPresentation.removeColumnTitle)\(Self.nbsp)»."
            )
        }
        let unread = unreadCellCount
        if unread > 0 {
            notes.append(Note(
                kind: .info,
                text: unread == 1
                    ? "1\(Self.nbsp)case sans lecture\(Self.nbsp): complétez-la."
                    : "\(unread)\(Self.nbsp)cases sans lecture\(Self.nbsp): complétez-les."
            ))
        }
        return notes
    }

    /// Grille incomplète ou mal cadrée : la place de certaines cartes a été devinée.
    static let positionsToVerifyText = "Positions à vérifier\(nbsp): la grille n'a pas été repérée en entier "
        + "dans le cadre. Placez chaque carte à sa place."

    /// « Colonne 2, rangée 1 : lecture incertaine (6 ?), choisissez la valeur. » ; place devinée :
    /// « Colonne 2, rangée 1 : position incertaine (5 ?), vérifiez la place de cette carte. »
    static func uncertainText(cell: CardScanResult.Cell, suggestion: Int?, isMisplaced: Bool = false) -> String {
        let position = CardGridPresentation.positionTitle(cell)
        let reason = isMisplaced ? "position incertaine" : "lecture incertaine"
        let action = isMisplaced ? "vérifiez la place de cette carte." : "choisissez la valeur."
        guard let suggestion else {
            return "\(position)\(nbsp): \(reason), \(action)"
        }
        return "\(position)\(nbsp): \(reason) (\(ScoreFormat.display(suggestion))\(narrowNbsp)?), \(action)"
    }

    /// Rappel permanent sous la grille.
    static let reviewReminder = "La lecture automatique peut se tromper\(nbsp): vérifiez chaque carte. "
        + "Rien n'est enregistré avant l'enregistrement de la manche."

    /// Annonce VoiceOver à l'affichage du résultat.
    var announcement: String {
        guard result.detectedCount > 0 else { return "Aucune carte lue. Reprenez la photo." }
        var parts = [headline]
        if let verifyText { parts.append(verifyText) }
        return parts.joined(separator: ", ") + ". Vérifiez la grille avant de l'utiliser."
    }

    // MARK: Remplacement (jamais d'écrasement silencieux)

    /// Vrai si le joueur a déjà saisi des cartes ou marqué une colonne retirée.
    static func needsReplaceConfirmation(current: CardGrid) -> Bool {
        current != CardGrid()
    }

    /// « Utiliser » n'a de sens que si la grille vérifiée contient quelque chose.
    static func canUse(_ grid: CardGrid) -> Bool {
        grid != CardGrid()
    }

    static let replaceTitle = "Remplacer les cartes saisies\(narrowNbsp)?"

    static func replaceMessage(playerName: String) -> String {
        "Les cartes déjà saisies pour \(playerName) seront remplacées par la grille vérifiée."
    }
}

/// Géométrie **pure** du cadre-guide et de sa zone dans la photo.
enum CardScanGeometry {
    /// Largeur / hauteur du cadre : 4 cartes de large, 3 de haut (cartes ≈ 1,55 fois plus hautes
    /// que larges).
    static let guideAspectRatio: CGFloat = 0.86
    static let guideInset: CGFloat = 24

    /// Plus grand cadre centré de rapport `guideAspectRatio` dans `size`, avec une marge.
    static func guideRect(in size: CGSize) -> CGRect {
        let availableWidth = max(size.width - 2 * guideInset, 1)
        let availableHeight = max(size.height - 2 * guideInset, 1)
        var width = availableWidth
        var height = width / guideAspectRatio
        if height > availableHeight {
            height = availableHeight
            width = height * guideAspectRatio
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// Zone du cadre dans la photo redressée, l'aperçu remplissant la vue (« aspect fill » :
    /// une partie de l'image est rognée à l'écran). `nil` si les dimensions sont inexploitables.
    static func regionOfInterest(guide: CGRect, viewSize: CGSize, imageAspectRatio: Double) -> NormalizedBox? {
        guard viewSize.width > 0, viewSize.height > 0, imageAspectRatio.isFinite, imageAspectRatio > 0 else {
            return nil
        }
        let viewAspect = Double(viewSize.width / viewSize.height)
        // Fraction de l'image visible à l'écran, centrée.
        var visibleWidth = 1.0
        var visibleHeight = 1.0
        if viewAspect > imageAspectRatio {
            visibleHeight = imageAspectRatio / viewAspect
        } else {
            visibleWidth = viewAspect / imageAspectRatio
        }
        let originX = (1 - visibleWidth) / 2
        let originY = (1 - visibleHeight) / 2
        let box = NormalizedBox(
            x: originX + Double(guide.minX / viewSize.width) * visibleWidth,
            y: originY + Double(guide.minY / viewSize.height) * visibleHeight,
            width: Double(guide.width / viewSize.width) * visibleWidth,
            height: Double(guide.height / viewSize.height) * visibleHeight
        )
        return box.isValid ? box : nil
    }

    /// Zone analysée par Vision : le cadre élargi de `margin`, borné à l'image, en coordonnées
    /// Vision (normalisées, origine en bas à gauche).
    static func visionRegion(for box: NormalizedBox, margin: Double) -> CGRect {
        let minX = min(max(box.x - margin, 0), 1)
        let maxX = min(max(box.x + box.width + margin, 0), 1)
        let minY = min(max(box.y - margin, 0), 1)
        let maxY = min(max(box.y + box.height + margin, 0), 1)
        return CGRect(x: minX, y: 1 - maxY, width: max(maxX - minX, 0), height: max(maxY - minY, 0))
    }
}
