import Foundation
import TableScoreKit

/// Décisions d'écriture communes aux dépôts SwiftData et en mémoire : fonctions pures sur des
/// valeurs, sans E/S. Chaque dépôt se contente d'appliquer le plan de façon atomique.
///
/// Toute règle de score est déléguée à `ScoreEngine` ; ce type ne fait qu'orchestrer
/// (idempotence, cycle de vie, résolution explicite d'une fin anticipée, titre).
enum GameWritePlanner {
    /// Longueur maximale du titre facultatif d'une partie (caractères perçus).
    static let maxTitleLength = 80
    /// Borne en octets UTF-8 (graphèmes chargés de marques combinantes).
    static let maxTitleByteCount = 512

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

    /// Partie neuve, validée par le moteur (nombre de joueurs, identifiants, noms, seuil) ;
    /// titre facultatif contrôlé ici (≤ `maxTitleLength`, sans caractère de contrôle).
    static func newGame(
        id: UUID,
        title: String?,
        participants: [Participant],
        rules: GameRules,
        at date: Date
    ) throws(GameRepositoryError) -> SavedGame {
        let cleanedTitle = try validatedTitle(title)
        let cleanedParticipants = participants.map {
            Participant(id: $0.id, displayName: $0.trimmedDisplayName, displayOrder: $0.displayOrder)
        }
        do {
            return try SavedGame(
                id: id,
                title: cleanedTitle,
                lifecycle: .active,
                rules: rules,
                participants: cleanedParticipants,
                rounds: [],
                roundInfo: [:],
                createdAt: date,
                updatedAt: date,
                finishedAt: nil,
                archivedAt: nil
            )
        } catch {
            throw GameRepositoryError.from(error, operation: .write)
        }
    }

    /// Titre sans espaces de bordure ; vide ⇒ `nil`. Mêmes caractères interdits que les noms
    /// (contrôles, séparateurs de ligne, contrôles bidirectionnels) ; un titre fait uniquement de
    /// caractères invisibles est refusé. Utilisé à la création **et** à la relecture.
    static func validatedTitle(_ title: String?) throws(GameRepositoryError) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard trimmed.count <= maxTitleLength, trimmed.utf8.count <= maxTitleByteCount else {
            throw GameRepositoryError.invalidTitle(.tooLong(maxLength: maxTitleLength))
        }
        guard Participant.hasVisibleContent(trimmed), !Participant.containsDisallowedCharacters(trimmed) else {
            throw GameRepositoryError.invalidTitle(.invalidCharacters)
        }
        return trimmed
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
        var info = game.roundInfo
        info[round.id] = SavedRoundInfo(createdAt: date, modifiedAt: date)
        return .insert(try rebuilt(game, rounds: game.rounds + [round], roundInfo: info, at: date))
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
        var info = game.roundInfo
        info[round.id] = SavedRoundInfo(
            createdAt: game.roundInfo[round.id]?.createdAt ?? game.createdAt,
            modifiedAt: date
        )
        guard let inconsistency = preview.inconsistency else {
            let updated = try rebuilt(game, rounds: correctedRounds, roundInfo: info, at: date)
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
            let updated = try rebuilt(game, rounds: kept, roundInfo: info, at: date)
            let replaced: RoundInput? = toRemove.contains(round.id) ? nil : normalizedRound
            return .write(updated, replacedRound: replaced, removedRounds: removed)
        }
    }

    static func planDeleteLast(of game: SavedGame, at date: Date) throws(GameRepositoryError) -> RoundDeletion {
        try requireActive(game)
        guard let last = game.rounds.last else {
            throw GameRepositoryError.noRoundToDelete(gameID: game.id)
        }
        let updated = try rebuilt(game, rounds: Array(game.rounds.dropLast()), roundInfo: game.roundInfo, at: date)
        return RoundDeletion(deletedRound: last, game: updated)
    }

    /// Résolution d'une fin anticipée déjà enregistrée : partie recalculée sans les manches
    /// postérieures à la fin, et liste exacte des manches supprimées.
    struct EarlyEndDeletionPlan: Sendable, Hashable {
        let game: SavedGame
        let removedRounds: [RoundInput]
    }

    /// Plan pur de `GameRepository.deleteRoundsAfterEarlyEnd` (contrat détaillé sur le protocole).
    ///
    /// Invariants vérifiés : identifiants confirmés == `subsequentRoundIDs` du moteur (ensemble et
    /// cardinal) ; après suppression, partie terminée selon le moteur et sans incohérence ; statut
    /// inchangé (`finished` conserve sa date de fin, jamais de réouverture).
    static func planDeleteRoundsAfterEarlyEnd(
        _ game: SavedGame,
        confirmedRoundIDs: [UUID],
        at date: Date
    ) throws(GameRepositoryError) -> EarlyEndDeletionPlan {
        guard game.lifecycle != .archived else {
            throw GameRepositoryError.gameNotActive(id: game.id, lifecycle: game.lifecycle)
        }
        guard let inconsistency = game.computation.inconsistency,
              !inconsistency.subsequentRoundIDs.isEmpty
        else {
            throw GameRepositoryError.staleEarlyEndDecision(gameID: game.id)
        }
        let toRemove = Set(inconsistency.subsequentRoundIDs)
        // Décision périmée, partielle ou dupliquée : on redemande plutôt que d'effacer autre chose.
        guard confirmedRoundIDs.count == toRemove.count, Set(confirmedRoundIDs) == toRemove else {
            throw GameRepositoryError.staleEarlyEndDecision(gameID: game.id)
        }
        let kept = game.rounds.filter { !toRemove.contains($0.id) }
        let removed = game.rounds.filter { toRemove.contains($0.id) }
        guard removed.count == toRemove.count else {
            throw GameRepositoryError.staleEarlyEndDecision(gameID: game.id)
        }
        var updated = try rebuilt(game, rounds: kept, roundInfo: game.roundInfo, at: date)
        // Garde-fou (invariant du moteur) : la manche de fin devient la dernière manche.
        guard updated.isOver, updated.computation.inconsistency == nil else {
            throw GameRepositoryError.staleEarlyEndDecision(gameID: game.id)
        }
        if updated.lifecycle == .finished && updated.finishedAt == nil {
            updated = updated.updatingLifecycle(.finished, updatedAt: date, finishedAt: date, archivedAt: nil)
        }
        return EarlyEndDeletionPlan(game: updated, removedRounds: removed)
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

    /// `nil` : déjà active, aucune écriture. `otherActiveGameID` : partie active différente, s'il y en a.
    static func planReopen(
        _ game: SavedGame,
        otherActiveGameID: UUID?,
        at date: Date
    ) throws(GameRepositoryError) -> SavedGame? {
        switch game.lifecycle {
        case .active:
            return nil
        case .archived:
            throw GameRepositoryError.invalidLifecycleTransition(id: game.id, from: game.lifecycle)
        case .finished:
            if let otherActiveGameID {
                throw GameRepositoryError.anotherGameActive(otherActiveGameID)
            }
            return game.updatingLifecycle(.active, updatedAt: date, finishedAt: nil, archivedAt: nil)
        }
    }

    /// `nil` : déjà rangée, aucune écriture. Une partie terminée selon le moteur garde (ou reçoit)
    /// sa date de fin.
    static func planArchive(_ game: SavedGame, at date: Date) -> SavedGame? {
        guard game.lifecycle != .archived else { return nil }
        return game.updatingLifecycle(
            .archived,
            updatedAt: date,
            finishedAt: game.finishedAt ?? (game.isOver ? date : nil),
            archivedAt: date
        )
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
        roundInfo: [UUID: SavedRoundInfo],
        at date: Date
    ) throws(GameRepositoryError) -> SavedGame {
        do {
            return try game.replacingRounds(rounds, roundInfo: roundInfo, updatedAt: date)
        } catch {
            throw GameRepositoryError.from(error, operation: .write)
        }
    }
}
