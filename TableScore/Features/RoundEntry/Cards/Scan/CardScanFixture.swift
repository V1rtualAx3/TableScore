#if DEBUG
import Foundation

/// Résultats de lecture **simulés** pour les tests UI (builds Debug uniquement, jamais en Release).
///
/// Lancement : `-uiTesting -scanFixture <nom>`. Le bouton « Scanner les cartes » est alors proposé
/// même sans appareil photo (simulateur) et l'écran de vérification s'ouvre directement : aucune
/// caméra, aucune autorisation demandée. Les observations passent par le vrai
/// `CardGridRecognizer` (même chemin que la photo).
enum CardScanFixture: String, CaseIterable, Sendable {
    /// 12 cartes nettes : rangées 1 5 −2 12 / 0 7 −1 3 / 9 6 10 4 ⇒ total brut 54.
    case complete
    /// 8 cartes nettes + 1 lecture incertaine (« 6 » ou « 9 ») ; colonne 4 vide.
    /// Rangées 3 3 8 — / 3 5 ? — / 3 2 1 — ; colonne 1 = 3/3/3 (non comptée) ⇒ total provisoire 19.
    case partial

    static let launchArgument = "-scanFixture"

    /// Résultat demandé ; exige aussi `-uiTesting` (comme les jeux de données `-seed`).
    static func requested(in arguments: [String]) -> CardScanFixture? {
        guard arguments.contains(PersistenceController.uiTestingLaunchArgument),
              let flagIndex = arguments.firstIndex(of: launchArgument) else { return nil }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return CardScanFixture(rawValue: arguments[valueIndex])
    }

    static let current: CardScanFixture? = requested(in: ProcessInfo.processInfo.arguments)

    var observations: [CardScanObservation] {
        switch self {
        case .complete:
            Self.layout([[1, 5, -2, 12], [0, 7, -1, 3], [9, 6, 10, 4]])
        case .partial:
            Self.layout([[3, 3, 8, nil], [3, 5, nil, nil], [3, 2, 1, nil]])
                + [Self.observation(column: 2, row: 1, candidates: [("6", 0.6), ("9", 0.55)])]
        }
    }

    // MARK: Disposition simulée (photo portrait 3:4, grille bien cadrée)

    private static let aspectRatio = 0.75
    private static let digitHeight = 0.065
    private static let columnPitch = 0.13
    private static let rowPitch = 0.17
    private static let originX = 0.18
    private static let originY = 0.25

    private static func layout(_ rows: [[Int?]]) -> [CardScanObservation] {
        var observations: [CardScanObservation] = []
        for (row, values) in rows.enumerated() {
            for (column, value) in values.enumerated() {
                guard let value else { continue }
                let text = value < 0 ? "\u{2212}\(-value)" : "\(value)"
                observations.append(observation(column: column, row: row, candidates: [(text, 1.0)]))
            }
        }
        return observations
    }

    private static func observation(column: Int, row: Int, candidates: [(String, Double)]) -> CardScanObservation {
        let length = Double(candidates.first?.0.count ?? 1)
        let width = 0.6 * digitHeight * length
        let centerX = originX + Double(column) * columnPitch
        let centerY = originY + Double(row) * rowPitch
        return CardScanObservation(
            candidates: candidates.map { CardScanObservation.Candidate(text: $0.0, confidence: $0.1) },
            box: NormalizedBox(
                x: (centerX - width / 2) / aspectRatio,
                y: centerY - digitHeight / 2,
                width: width / aspectRatio,
                height: digitHeight
            )
        )
    }
}
#endif
