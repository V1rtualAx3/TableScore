import Foundation
import TableScoreKit

/// Lecture seule de `GameComputation` pour l'écran de fin de partie.
///
/// Aucune règle de score ici : vainqueur(s) = `winnerIDs` du moteur, scores finaux et rangs =
/// `standingsAtEnd` (donc cohérents avec les vainqueurs, même en cas d'incohérence de fin
/// anticipée où `totals` diffère de `totalsAtEnd`). Rien n'est recalculé.
struct GameOverSummary: Equatable, Sendable {
    struct Line: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
        let total: Int
        /// Rang du moteur (les égalités partagent le même rang).
        let rank: Int
        let isWinner: Bool
    }

    /// Classement final, dans l'ordre du moteur.
    let lines: [Line]
    /// Prénoms des vainqueurs, dans l'ordre fourni par le moteur.
    let winnerNames: [String]
    /// Total commun des vainqueurs.
    let winnerTotal: Int?
    /// Nombre de manches jouées jusqu'à la fin de la partie (indice de la manche qui termine).
    let roundCount: Int
    let targetScore: Int

    /// `nil` si la partie n'est pas terminée selon le moteur.
    init?(game: SavedGame) {
        let computation = game.computation
        guard case .finished(let roundIndex, let winnerIDs) = computation.status,
              let standings = computation.standingsAtEnd else { return nil }
        let namesByID = Dictionary(
            game.participants.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        let winners = Set(winnerIDs)
        let lines = standings.compactMap { standing -> Line? in
            guard let name = namesByID[standing.participantID] else { return nil }
            return Line(
                id: standing.participantID,
                name: name,
                total: standing.total,
                rank: standing.rank,
                isWinner: winners.contains(standing.participantID)
            )
        }
        self.lines = lines
        self.winnerNames = winnerIDs.compactMap { namesByID[$0] }
        self.winnerTotal = lines.first(where: \.isWinner)?.total
        self.roundCount = roundIndex
        self.targetScore = game.rules.targetScore
    }

    var hasCoWinners: Bool { winnerNames.count > 1 }

    /// « Bob » ; « Bob et Chloé » ; « Alice, Bob et Chloé ».
    var joinedWinnerNames: String { Self.join(winnerNames) }

    /// « Bravo Bob ! » ou « Égalité : Bob et Chloé gagnent ensemble ».
    var headline: String {
        let names = joinedWinnerNames
        return hasCoWinners
            ? String(localized: "Égalité\u{00A0}: \(names) gagnent ensemble")
            : String(localized: "Bravo \(names)\u{202F}!")
    }

    /// « Vainqueur : Bob, 26 points » / « Égalité : Bob et Chloé, 26 points chacun » (VoiceOver).
    var spokenWinners: String {
        let names = joinedWinnerNames
        guard let total = winnerTotal else {
            return String(localized: "Vainqueur\u{00A0}: \(names)")
        }
        let points = ScoreFormat.spoken(total)
        return hasCoWinners
            ? String(localized: "Égalité\u{00A0}: \(names), \(points) points chacun")
            : String(localized: "Vainqueur\u{00A0}: \(names), \(points) points")
    }

    /// « Partie terminée. Vainqueur : Bob, 26 points ».
    var spokenSummary: String {
        String(localized: "Partie terminée. \(spokenWinners)")
    }

    /// Rappel : le gagnant n'est pas le premier à atteindre le seuil.
    var rulesReminder: String {
        String(localized: "La partie s'arrête dès qu'un joueur atteint \(targetScore) points. Le plus petit total gagne.")
    }

    /// Liste française partagée (`VerdictText.frenchList`).
    static func join(_ names: [String]) -> String {
        VerdictText.frenchList(names)
    }
}
