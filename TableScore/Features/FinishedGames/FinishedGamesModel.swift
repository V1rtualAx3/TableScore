import Foundation
import Observation
import TableScoreKit

/// Ligne affichable d'une partie close. Aucune règle de score ici : les vainqueurs viennent du
/// moteur (`GameComputation.status`), le nombre de manches de l'historique enregistré.
struct FinishedGameRow: Identifiable, Hashable {
    enum Kind: Hashable {
        /// Partie terminée selon le moteur.
        case finished
        /// Partie rangée avant la fin (`SavedGame.isInterrupted`).
        case interrupted
        /// Données illisibles : listée pour pouvoir être supprimée.
        case unreadable
    }

    let id: UUID
    let kind: Kind
    let date: Date
    let playerNames: [String]
    /// Vide si la partie n'est pas terminée ou illisible ; plusieurs noms = co-vainqueurs.
    let winnerNames: [String]
    let roundCount: Int

    var isReadable: Bool { kind != .unreadable }
    var hasCoWinners: Bool { winnerNames.count > 1 }

    init(
        id: UUID,
        kind: Kind,
        date: Date,
        playerNames: [String] = [],
        winnerNames: [String] = [],
        roundCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.date = date
        self.playerNames = playerNames
        self.winnerNames = winnerNames
        self.roundCount = roundCount
    }

    init(_ game: SavedGame) {
        let namesByID = Dictionary(
            game.participants.map { ($0.id, $0.trimmedDisplayName) },
            uniquingKeysWith: { first, _ in first }
        )
        var winners: [String] = []
        if case .finished(_, let winnerIDs) = game.computation.status {
            winners = winnerIDs.compactMap { namesByID[$0] }
        }
        self.init(
            id: game.id,
            kind: game.isOver ? .finished : .interrupted,
            date: game.finishedAt ?? game.archivedAt ?? game.updatedAt,
            playerNames: game.participants.map(\.trimmedDisplayName),
            winnerNames: winners,
            roundCount: game.rounds.count
        )
    }
}

/// État de l'écran « Parties terminées » : lecture du dépôt et suppression confirmée.
@Observable
@MainActor
final class FinishedGamesModel {
    private(set) var rows: [FinishedGameRow] = []
    private(set) var isLoaded = false
    /// Message générique (jamais de détail technique) ; `nil` si la lecture a réussi.
    private(set) var loadErrorMessage: String?
    private(set) var deletionErrorMessage: String?
    /// Partie dont la suppression attend la confirmation de l'utilisateur.
    private(set) var pendingDeletionID: UUID?

    var hasDeletionError: Bool {
        get { deletionErrorMessage != nil }
        set { if !newValue { deletionErrorMessage = nil } }
    }

    private let repository: any GameRepository

    init(repository: any GameRepository) {
        self.repository = repository
    }

    func load() {
        do {
            rows = try repository.closedGames().map { listing in
                switch listing {
                case .readable(let game):
                    FinishedGameRow(game)
                case .corrupted(let id, let updatedAt, _):
                    FinishedGameRow(id: id, kind: .unreadable, date: updatedAt)
                }
            }
            loadErrorMessage = nil
        } catch {
            rows = []
            loadErrorMessage = GameRepositoryError.from(error, operation: .read).userFacingMessage
        }
        isLoaded = true
    }

    // MARK: Suppression (toujours confirmée)

    func requestDeletion(of id: UUID) {
        pendingDeletionID = id
    }

    func cancelDeletion() {
        pendingDeletionID = nil
    }

    /// Supprime définitivement la partie en attente de confirmation. Renvoie `true` si le dépôt a
    /// été modifié (l'appelant notifie alors le routeur). Sans demande préalable : aucun effet.
    @discardableResult
    func confirmDeletion() -> Bool {
        guard let id = pendingDeletionID else { return false }
        return delete(id: id)
    }

    /// Suppression d'une partie dont la confirmation vient d'être donnée (la vue transmet
    /// l'identifiant présenté dans la boîte de dialogue, indépendamment de l'ordre de fermeture).
    @discardableResult
    func delete(id: UUID) -> Bool {
        pendingDeletionID = nil
        do {
            try repository.deleteGame(id: id)
            deletionErrorMessage = nil
            load()
            return true
        } catch {
            deletionErrorMessage = GameRepositoryError.from(error, operation: .write).userFacingMessage
            load()
            return false
        }
    }
}
