import Foundation
import Observation
import TableScoreKit

/// Modèle du tableau des scores : charge la partie depuis le dépôt (source de vérité) et expose
/// des données **d'affichage**. Aucun calcul de score ici : totaux, rangs, leaders, fin de partie
/// et incohérences viennent de `GameComputation` (`ScoreEngine`).
@Observable
@MainActor
final class GameModel {
    /// Ligne du tableau, dans l'ordre stable `displayOrder` (jamais retrié).
    struct Row: Identifiable, Equatable {
        let id: UUID
        /// Rang 0-based dans l'ordre d'affichage (= indice d'identifiant d'accessibilité).
        let position: Int
        let name: String
        let total: Int
        /// Rang du moteur (les égalités partagent le même rang).
        let rank: Int
        let isLeader: Bool
        /// Différence d'affichage avec le total des leaders ; `nil` pour un leader.
        let gapToLeader: Int?
    }

    /// Message non bloquant « Manche n enregistrée », déduit au rechargement.
    struct Banner: Equatable {
        let message: String
        let detail: String?
    }

    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(message: String)
    }

    private(set) var loadState: LoadState = .loading
    private(set) var game: SavedGame?
    private(set) var banner: Banner?
    /// Incrémenté à chaque nouvelle manche détectée (déclencheur de l'haptique).
    private(set) var savedRoundCount = 0
    /// Vrai si l'échec de chargement est « partie introuvable » (sinon : message générique du dépôt).
    private(set) var loadFailureIsNotFound = false
    /// Incrémenté une seule fois par modèle quand l'écran de fin est annoncé (haptique unique).
    private(set) var endFeedbackCount = 0
    private var hasAnnouncedEnd = false
    /// Erreur d'une action (rejouer, abandonner), affichée dans une alerte.
    var actionError: String?

    let gameID: UUID
    private let repository: any GameRepository
    /// Brouillon de « Rejouer » conservé : un double appel recrée la même partie (idempotent).
    private var replayDraft: (id: UUID, participants: [Participant])?

    init(gameID: UUID, repository: any GameRepository) {
        self.gameID = gameID
        self.repository = repository
    }

    /// Modèle à afficher pour `gameID` : `existing` seulement s'il concerne la même partie.
    /// La navigation peut réutiliser l'écran (et son `@State`) pour une autre partie : « Rejouer »
    /// remplace `[.game(ancienne)]` par `[.game(nouvelle)]` à la même position. Recharger
    /// l'ancien modèle afficherait encore la partie terminée au lieu de la nouvelle.
    static func resolve(_ existing: GameModel?, gameID: UUID, repository: any GameRepository) -> GameModel {
        if let existing, existing.gameID == gameID { return existing }
        return GameModel(gameID: gameID, repository: repository)
    }

    // MARK: Chargement

    /// Recharge la partie ; détecte une nouvelle dernière manche pour la bannière.
    func load() {
        do {
            let loaded = try repository.game(id: gameID)
            let previousCount = game?.computation.rounds.count
            game = loaded
            loadState = .loaded
            let count = loaded.computation.rounds.count
            loadFailureIsNotFound = false
            if let previousCount {
                if loaded.isOver {
                    // La fin de partie remplace bannière et haptique « manche enregistrée » :
                    // une seule annonce VoiceOver et une seule haptique (écran de fin).
                    banner = nil
                } else if count > previousCount, let last = loaded.computation.rounds.last {
                    banner = makeBanner(for: last, in: loaded)
                    savedRoundCount += 1
                } else if count < previousCount {
                    banner = nil
                }
            }
        } catch {
            let repositoryError = GameRepositoryError.from(error, operation: .read)
            game = nil
            banner = nil
            if case .gameNotFound = repositoryError { loadFailureIsNotFound = true } else { loadFailureIsNotFound = false }
            loadState = .failed(message: repositoryError.userFacingMessage)
        }
    }

    func dismissBanner() {
        banner = nil
    }

    private func makeBanner(for summary: RoundSummary, in game: SavedGame) -> Banner {
        let message = String(localized: "Manche \(summary.scoring.index) enregistrée")
        var detail: String?
        if summary.scoring.verdict.isDoubled,
           let closer = game.participants.first(where: { $0.id == summary.scoring.closingParticipantID }) {
            let name = closer.displayName
            let raw = ScoreFormat.display(summary.scoring.closingRawScore)
            let effective = ScoreFormat.display(summary.scoring.closingEffectiveScore)
            detail = String(localized: "\(name)\u{00A0}: score doublé (\(raw) → \(effective))")
        }
        return Banner(message: message, detail: detail)
    }

    // MARK: Affichage

    var isOver: Bool { game?.isOver ?? false }

    /// Écran de fin complet (vainqueurs + tableau final) : partie terminée et lisible par `GameOverSummary`.
    /// Les lignes de score et le classement sont alors masqués (un seul tableau : `standingsAtEnd`).
    var showsFinalResults: Bool {
        guard let game else { return false }
        return GameOverSummary(game: game) != nil
    }

    /// `true` une seule fois par modèle, quand l'écran de fin est affiché (annonce + haptique uniques).
    func consumeEndAnnouncement() -> Bool {
        guard showsFinalResults, !hasAnnouncedEnd else { return false }
        hasAnnouncedEnd = true
        endFeedbackCount += 1
        return true
    }

    /// « Historique (3 manches) » ; `nil` sans manche (le lien est masqué).
    var historyLinkTitle: String? {
        switch roundCount {
        case 0: nil
        case 1: String(localized: "Historique (1 manche)")
        default: String(localized: "Historique (\(roundCount) manches)")
        }
    }

    /// Une nouvelle manche n'est proposée que pour une partie active que le moteur juge en cours.
    var canAddRound: Bool {
        guard let game else { return false }
        return game.lifecycle == .active && game.computation.acceptsNewRound
    }

    /// « Abandonner » = archiver ; uniquement pour la partie active non terminée.
    var canAbandon: Bool { canAddRound }

    var roundCount: Int { game?.computation.rounds.count ?? 0 }
    var playerCount: Int { game?.participants.count ?? 0 }
    var hasInconsistency: Bool { game?.computation.inconsistency != nil }

    var headerTitle: String {
        guard let game else { return String(localized: "Partie") }
        if game.isOver { return String(localized: "Partie terminée") }
        return String(localized: "Manche \(game.computation.nextRoundIndex)")
    }

    /// Titre système de la barre : « Manche 3 · 8 joueurs » pendant la partie ; `headerTitle` seul
    /// sans partie chargée ou sur l'écran de fin (où la barre n'affiche pas de titre).
    var navigationTitle: String {
        guard game != nil, !showsFinalResults else { return headerTitle }
        return headerTitle + " · " + headerSubtitle
    }

    var headerSubtitle: String {
        String(localized: "\(playerCount) joueurs")
    }

    /// Lignes dans l'ordre d'affichage stable.
    var rows: [Row] {
        guard let game else { return [] }
        let computation = game.computation
        let standings = Dictionary(
            computation.standings.map { ($0.participantID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let leaderTotal = computation.standings.first(where: \.isLeader)?.total
        return game.participants.enumerated().map { position, participant in
            let standing = standings[participant.id]
            let total = standing?.total ?? computation.totals[participant.id] ?? 0
            let isLeader = standing?.isLeader ?? false
            let gap: Int? = (isLeader || leaderTotal == nil) ? nil : total - (leaderTotal ?? total)
            return Row(
                id: participant.id,
                position: position,
                name: participant.displayName,
                total: total,
                rank: standing?.rank ?? position + 1,
                isLeader: isLeader,
                gapToLeader: gap
            )
        }
    }

    /// Classement secondaire : ordre fourni par le moteur (`standings`).
    var rankedRows: [Row] {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (game?.computation.standings ?? []).compactMap { byID[$0.participantID] }
    }

    // MARK: Actions

    /// Crée une nouvelle partie (mêmes prénoms, même ordre, mêmes règles) et renvoie son identifiant.
    func replay() -> UUID? {
        guard let game else { return nil }
        let draft = replayDraft ?? (
            id: UUID(),
            participants: game.participants.map {
                Participant(displayName: $0.displayName, displayOrder: $0.displayOrder)
            }
        )
        replayDraft = draft
        do {
            let created = try repository.createGame(
                id: draft.id,
                participants: draft.participants,
                rules: game.rules,
                title: game.title
            )
            return created.id
        } catch {
            actionError = GameRepositoryError.from(error, operation: .write).userFacingMessage
            return nil
        }
    }

    /// Archive la partie (conservée, « Interrompue ») ; `true` si réussi.
    func abandon() -> Bool {
        do {
            _ = try repository.archiveGame(id: gameID)
            return true
        } catch {
            actionError = GameRepositoryError.from(error, operation: .write).userFacingMessage
            return false
        }
    }
}
