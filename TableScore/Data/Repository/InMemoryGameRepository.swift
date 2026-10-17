import Foundation
import TableScoreKit

/// Dépôt volatil pour les previews SwiftUI et les tests de view models.
///
/// Même contrat et mêmes décisions que `SwiftDataGameRepository` (via `GameWritePlanner`) ;
/// chaque écriture remplace l'état en une seule affectation (tout ou rien).
/// Les tests UI utilisent plutôt `SwiftDataGameRepository` sur un conteneur en mémoire
/// (`-uiTesting`) afin d'exercer le vrai chemin de persistance.
@MainActor
final class InMemoryGameRepository: GameRepository {
    private var games: [UUID: SavedGame] = [:]
    private let now: @MainActor () -> Date

    /// Permet de vérifier l'affichage d'une erreur d'enregistrement : chaque écriture échoue
    /// (rien n'est modifié) tant que la valeur est vraie. Ne simule jamais un succès.
    var simulatesWriteFailure = false

    init(now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: Lecture

    func activeGame() throws(GameRepositoryError) -> SavedGame? {
        let active = games.values.filter { $0.lifecycle == .active }
        guard active.count <= 1 else {
            throw GameRepositoryError.corruptedData(gameID: nil, .multipleActiveGames(count: active.count))
        }
        return active.first
    }

    func game(id: UUID) throws(GameRepositoryError) -> SavedGame {
        guard let game = games[id] else { throw GameRepositoryError.gameNotFound(id) }
        return game
    }

    func closedGames() throws(GameRepositoryError) -> [GameListing] {
        let closed = games.values
            .filter { $0.lifecycle != .active }
            .map { GameListing.readable($0) }
        return GameWritePlanner.sortedListings(closed)
    }

    // MARK: Écriture

    func createGame(
        id: UUID,
        participants: [Participant],
        rules: GameRules,
        title: String?
    ) throws(GameRepositoryError) -> SavedGame {
        let date = now()
        let candidate = try GameWritePlanner.newGame(
            id: id,
            title: title,
            participants: participants,
            rules: rules,
            at: date
        )
        if let existing = games[id] {
            return try GameWritePlanner.resolveExistingCreation(existing, candidate: candidate)
        }
        let superseded = games.values
            .filter { $0.lifecycle == .active }
            .map { GameWritePlanner.superseded($0, at: date) }
        try commit(superseded + [candidate])
        return candidate
    }

    func appendRound(_ round: RoundInput, toGame gameID: UUID) throws(GameRepositoryError) -> AppendRoundOutcome {
        let current = try game(id: gameID)
        let usedElsewhere = games.values.contains { other in
            other.id != gameID && other.rounds.contains { $0.id == round.id }
        }
        let plan = try GameWritePlanner.planAppend(
            round,
            to: current,
            roundIDUsedElsewhere: usedElsewhere,
            at: now()
        )
        switch plan {
        case .alreadySaved:
            return .alreadySaved(current)
        case .insert(let updated):
            try commit([updated])
            return .inserted(updated)
        }
    }

    func replaceRound(
        _ round: RoundInput,
        inGame gameID: UUID,
        resolution: EarlyEndResolution
    ) throws(GameRepositoryError) -> RoundReplacementOutcome {
        let current = try game(id: gameID)
        let plan = try GameWritePlanner.planReplace(round, in: current, resolution: resolution, at: now())
        switch plan {
        case .unchanged:
            return .saved(current, removedRounds: [])
        case .requiresDecision(let conflict):
            return .requiresDecision(conflict)
        case .write(let updated, _, let removedRounds):
            try commit([updated])
            return .saved(updated, removedRounds: removedRounds)
        }
    }

    func deleteLastRound(ofGame gameID: UUID) throws(GameRepositoryError) -> RoundDeletion {
        let deletion = try GameWritePlanner.planDeleteLast(of: try game(id: gameID), at: now())
        try commit([deletion.game])
        return deletion
    }

    func finishGame(id: UUID) throws(GameRepositoryError) -> SavedGame {
        let current = try game(id: id)
        guard let updated = try GameWritePlanner.planFinish(current, at: now()) else { return current }
        try commit([updated])
        return updated
    }

    func archiveGame(id: UUID) throws(GameRepositoryError) -> SavedGame {
        let current = try game(id: id)
        guard let updated = GameWritePlanner.planArchive(current, at: now()) else { return current }
        try commit([updated])
        return updated
    }

    @discardableResult
    func deleteGame(id: UUID) throws(GameRepositoryError) -> Bool {
        guard games[id] != nil else { return false }
        try failIfSimulated()
        games[id] = nil
        return true
    }

    // MARK: Transaction

    private func commit(_ updates: [SavedGame]) throws(GameRepositoryError) {
        try failIfSimulated()
        var next = games
        for game in updates { next[game.id] = game }
        games = next
    }

    private func failIfSimulated() throws(GameRepositoryError) {
        if simulatesWriteFailure {
            throw GameRepositoryError.storageFailure(.write, message: "Échec d'écriture simulé.")
        }
    }
}
