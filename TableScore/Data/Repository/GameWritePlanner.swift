import Foundation
import TableScoreKit

/// Décisions d'écriture communes aux dépôts SwiftData et en mémoire : fonctions pures sur des
/// valeurs, sans E/S. Chaque dépôt se contente d'appliquer le plan de façon atomique.
///
/// Toute règle de score est déléguée à `ScoreEngine` ; ce type ne fait qu'orchestrer
/// (idempotence, cycle de vie, résolution explicite d'une fin anticipée).
enum GameWritePlanner {

    enum AppendPlan: Sendable, Hashable {
        case alreadySaved
        case insert(SavedGame)
    }

    enum ReplacePlan: Sendable, Hashable {
        /// Correction identique à l'existant : aucune écriture.
        case unchanged
        case requiresDecision(EarlyEndConflict)
        /// `replacedRound` est absent si la manche corrigée fait elle-même partie des manches supprimées.
        case write(SavedGame, replacedRound: RoundInput?, removedRounds: [RoundInput])
    }

    // MARK: Création

    /// Partie neuve, validée par le moteur (nombre de joueurs, identifiants, noms, seuil).
    static func newGame(
        id: UUID,
        title: String?,
        participants: [Participant],
        rules: GameRules,
        at date: Date
    ) throws(GameRepositoryError) -> SavedGame {
        let cleanedParticipants = participants.map {
            Participant(id: $0.id, displayName: $0.trimmedDisplayName, displayOrder: $0.displayOrder)
        }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTitle = (trimmedTitle?.isEmpty ?? true) ? nil : trimmedTitle
        do {
            return try SavedGame(
                id: id,
                title: cleanedTitle,
                lifecycle: .active,
                rules: rules,
                participants: cleanedParticipants,
                rounds: [],
                createdAt: date,
                updatedAt: date,
                finishedAt: nil,
                archivedAt: nil
            )
        } catch {
            throw GameRepositoryError.from(error, operation: .write)
        }
    }

    /// Second `createGame` avec un identifiant existant : idempotent si la demande est identique.
    static func resolveExistingCreation(
        _ existing: SavedGame,
        candidate: SavedGame
    ) throws(GameRepositoryError) -> SavedGame {
        guard existing.participants == candidate.participants,
              existing.rules == candidate.rules,
              existing.title == candidate.title
        else {
            throw GameRepositoryError.identifierConflict(existing.id)
        }
        return existing
    }

    /// Clôture de l'ancienne partie active lors d'une création : `finished` si le moteur la
    /// considère terminée, sinon `archived` (« interrompue »).
    static func superseded(_ game: SavedGame, at date: Date) -> SavedGame {
        if game.isOver {
            return game.updatingLifecycle(
                .finished,
                updatedAt: date,
                finishedAt: game.finishedAt ?? date,
                archivedAt: game.archivedAt
            )
        }
        return game.updatingLifecycle(.archived, updatedAt: date, finishedAt: game.finishedAt, archivedAt: date)
    }

    // MARK: Manches

    static func planAppend(
        _ round: RoundInput,
        to game: SavedGame,
        roundIDUsedElsewhere: Bool,
        at date: Date
    ) throws(GameRepositoryError) -> AppendPlan {
        // Idempotence d'abord : une nouvelle tentative après succès reste un succès sans écriture,
        // même si la partie a changé de statut entre-temps.
        if let existing = game.rounds.first(where: { $0.id == round.id }) {
            guard existing == game.normalized(round) else {
                throw GameRepositoryError.identifierConflict(round.id)
            }
            return .alreadySaved
        }
        guard !roundIDUsedElsewhere else { throw GameRepositoryError.identifierConflict(round.id) }
        try requireActive(game)
        do {
            _ = try ScoreEngine.computeAppending(
                round,
                to: game.rounds,
                participants: game.participants,
                rules: game.rules
            )
        } catch {
            throw GameRepositoryError.from(error, operation: .write)
        }
        return .insert(try rebuilt(game, rounds: game.rounds + [round], at: date))
    }

    static func planReplace(
        _ round: RoundInput,
        in game: SavedGame,
        resolution: EarlyEndResolution,
        at date: Date
    ) throws(GameRepositoryError) -> ReplacePlan {
        try requireActive(game)
        let preview: GameComputation
        do {
            // Refuse une manche inconnue ou un changement d'indice ; signale une fin anticipée.
            preview = try ScoreEngine.computeReplacing(
                round,
                in: game.rounds,
                participants: game.participants,
                rules: game.rules
            )
        } catch {
            throw GameRepositoryError.from(error, operation: .write)
        }
        let normalizedRound = game.normalized(round)
        if game.rounds.contains(normalizedRound) { return .unchanged }

        let correctedRounds = game.rounds.map { $0.id == round.id ? normalizedRound : $0 }
        guard let inconsistency = preview.inconsistency else {
            let updated = try rebuilt(game, rounds: correctedRounds, at: date)
            return .write(updated, replacedRound: normalizedRound, removedRounds: [])
        }

        let conflict = EarlyEndConflict(inconsistency: inconsistency, preview: preview)
        switch resolution {
        case .rejectIfEarlyEnd:
            return .requiresDecision(conflict)
        case .deleteRoundsAfterEarlyEnd(let confirmedRoundIDs):
            let toRemove = Set(inconsistency.subsequentRoundIDs)
            // Décision périmée ou partielle : on redemande plutôt que d'effacer autre chose.
            guard Set(confirmedRoundIDs) == toRemove else { return .requiresDecision(conflict) }
            let kept = correctedRounds.filter { !toRemove.contains($0.id) }
            let removed = game.rounds.filter { toRemove.contains($0.id) }
            let updated = try rebuilt(game, rounds: kept, at: date)
            let replaced: RoundInput? = toRemove.contains(round.id) ? nil : normalizedRound
            return .write(updated, replacedRound: replaced, removedRounds: removed)
        }
    }

    static func planDeleteLast(of game: SavedGame, at date: Date) throws(GameRepositoryError) -> RoundDeletion {
        try requireActive(game)
        guard let last = game.rounds.last else {
            throw GameRepositoryError.noRoundToDelete(gameID: game.id)
        }
        let updated = try rebuilt(game, rounds: Array(game.rounds.dropLast()), at: date)
        return RoundDeletion(deletedRound: last, game: updated)
    }

    // MARK: Cycle de vie

    /// `nil` : déjà terminée, aucune écriture.
    static func planFinish(_ game: SavedGame, at date: Date) throws(GameRepositoryError) -> SavedGame? {
        switch game.lifecycle {
        case .finished:
            return nil
        case .archived:
            throw GameRepositoryError.gameNotActive(id: game.id, lifecycle: game.lifecycle)
        case .active:
            guard game.isOver else { throw GameRepositoryError.gameNotOver(game.id) }
            return game.updatingLifecycle(.finished, updatedAt: date, finishedAt: date, archivedAt: nil)
        }
    }

    /// `nil` : déjà rangée, aucune écriture.
    static func planArchive(_ game: SavedGame, at date: Date) -> SavedGame? {
        guard game.lifecycle != .archived else { return nil }
        return game.updatingLifecycle(.archived, updatedAt: date, finishedAt: game.finishedAt, archivedAt: date)
    }

    static func requireActive(_ game: SavedGame) throws(GameRepositoryError) {
        guard game.lifecycle == .active else {
            throw GameRepositoryError.gameNotActive(id: game.id, lifecycle: game.lifecycle)
        }
    }

    /// Ordre déterministe : plus récente d'abord, puis identifiant.
    static func sortedListings(_ listings: [GameListing]) -> [GameListing] {
        listings.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func rebuilt(
        _ game: SavedGame,
        rounds: [RoundInput],
        at date: Date
    ) throws(GameRepositoryError) -> SavedGame {
        do {
            return try game.replacingRounds(rounds, updatedAt: date)
        } catch {
            throw GameRepositoryError.from(error, operation: .write)
        }
    }
}
