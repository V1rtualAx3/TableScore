import Foundation
import Observation
import TableScoreKit

/// État de l'écran Historique (cahier §4.6, docs/ux/lot2-parcours.md §2.5).
///
/// Aucune règle de score ici : scores retenus, verdict du clôturant, cumuls, fin de partie et
/// incohérence proviennent de `SavedGame.computation` (recalcul intégral par `ScoreEngine`). Le
/// modèle ne fait que mettre en forme ces valeurs et orchestrer les écritures du dépôt.
///
/// Ordre d'affichage : **manche la plus récente en haut**. Justification : la dernière manche est
/// la plus souvent corrigée et la seule supprimable ; elle reste accessible sans défilement même
/// après de nombreuses manches. Le cumul « après la manche » est affiché sur chaque ligne, la
/// lecture chronologique reste donc possible de bas en haut.
@Observable
@MainActor
final class HistoryModel {
    /// Score d'un joueur pour une manche, tel que calculé par le moteur.
    struct PlayerLine: Identifiable, Hashable, Sendable {
        var id: UUID { participantID }
        let participantID: UUID
        /// Rang 0-based dans l'ordre d'affichage (convention `AccessibilityID`).
        let position: Int
        let name: String
        let rawScore: Int
        let effectiveScore: Int
        /// Cumul après la manche ; `nil` seulement si le moteur ne le fournit pas (jamais inventé).
        let totalAfterRound: Int?
        let isClosing: Bool
        let isDoubled: Bool
    }

    /// Une manche de l'historique, prête à afficher.
    struct RoundRow: Identifiable, Hashable, Sendable {
        let id: UUID
        let index: Int
        let closerName: String
        let isCloserDoubled: Bool
        /// Raison du verdict, en minuscules (« égalité avec Chloé », « zéro, jamais doublé »…).
        let closerNote: String
        let isCorrected: Bool
        /// La partie se termine à cette manche (seuil atteint pour la première fois).
        let isEndingRound: Bool
        /// Manche enregistrée après la fin de partie (incohérence §4.6).
        let isAfterGameEnd: Bool
        /// Dernière manche enregistrée (seule supprimable).
        let isLast: Bool
        /// Joueurs dans l'ordre d'affichage (jamais retrié).
        let players: [PlayerLine]
        /// Lecture VoiceOver complète de la manche.
        let accessibilityLabel: String

        var displayedCloserNote: String { closerNote.prefix(1).uppercased() + closerNote.dropFirst() }
    }

    /// Suppression annulable : la manche exacte (même identifiant) et l'état attendu pour l'annuler.
    struct UndoableDeletion: Hashable, Sendable {
        let round: RoundInput
        /// Identifiants des manches restantes juste après la suppression ; si l'historique a changé
        /// depuis (autre action), l'annulation n'est plus proposée.
        let remainingRoundIDs: [UUID]

        var index: Int { round.index }
        var bannerText: String { "Manche \(round.index) supprimée" }
    }

    /// Fin anticipée présente dans les données enregistrées (ex. données anciennes) : rien n'est
    /// effacé sans choix explicite de l'utilisateur.
    struct InconsistencyNotice: Hashable, Sendable {
        let endingRoundIndex: Int
        let subsequentRoundIndices: [Int]
        /// Identifiants confirmés par l'utilisateur (vérifiés à nouveau avant toute suppression).
        let subsequentRoundIDs: [UUID]
        let requiresReopen: Bool
        let title: String
        let message: String
        let actionTitle: String
        let confirmationTitle: String
        let confirmationMessage: String
        let confirmationButtonTitle: String
    }

    /// Suite à donner au toucher d'une manche.
    enum EditRequest: Hashable, Sendable {
        /// Présenter le formulaire de correction de cette manche.
        case present(roundID: UUID)
        /// Partie close : confirmation « Rouvrir la partie pour corriger ? » demandée.
        case needsReopen
        /// Lecture seule (partie interrompue, manche inconnue, opération en cours).
        case unavailable
    }

    let gameID: UUID
    private let repository: any GameRepository

    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private(set) var lifecycle: GameLifecycle?
    private(set) var targetScore: Int?
    /// Manches, la plus récente en premier.
    private(set) var rows: [RoundRow] = []
    private(set) var inconsistency: InconsistencyNotice?
    private(set) var undoableDeletion: UndoableDeletion?
    private(set) var isWorking = false
    /// Manche à corriger en attente de la confirmation de réouverture.
    private(set) var pendingReopenRoundID: UUID?
    /// Message d'erreur d'une action (alerte) ; remis à `nil` à la fermeture de l'alerte.
    var actionError: String?

    init(gameID: UUID, repository: any GameRepository) {
        self.gameID = gameID
        self.repository = repository
    }

    // MARK: Dérivés

    var lastRound: RoundRow? { rows.first(where: \.isLast) }

    var isEditable: Bool { lifecycle == .active || lifecycle == .finished }

    /// Suppression simple de la dernière manche : partie en cours, sans incohérence à résoudre
    /// (dans ce cas, la résolution explicite remplace la suppression unitaire).
    var canDeleteLastRound: Bool {
        lifecycle == .active && inconsistency == nil && lastRound != nil && !isWorking
    }

    /// Une partie interrompue (archivée) reste en lecture seule : l'incohérence y est seulement signalée.
    var canResolveInconsistency: Bool {
        inconsistency != nil && isEditable && !isWorking
    }

    var deletionConfirmationTitle: String {
        guard let lastRound else { return "Supprimer la dernière manche ?" }
        return "Supprimer la manche \(lastRound.index) ?"
    }

    var deletionConfirmationButtonTitle: String {
        guard let lastRound else { return "Supprimer" }
        return "Supprimer la manche \(lastRound.index)"
    }

    var lifecycleNote: String? {
        switch lifecycle {
        case .finished:
            "Partie terminée. Touchez une manche pour rouvrir la partie et la corriger."
        case .archived:
            "Partie interrompue : historique en lecture seule."
        case .active, nil:
            nil
        }
    }

    // MARK: Chargement

    /// Relit la partie (appelé sur `.task(id: router.dataRevision)`). Synchrone : volume minuscule.
    func load() {
        defer { hasLoaded = true }
        let game: SavedGame
        do {
            game = try repository.game(id: gameID)
        } catch {
            let repositoryError = GameRepositoryError.from(error, operation: .read)
            loadError = repositoryError.userFacingMessage
            rows = []
            inconsistency = nil
            undoableDeletion = nil
            lifecycle = nil
            targetScore = nil
            return
        }
        apply(game)
    }

    private func apply(_ game: SavedGame) {
        loadError = nil
        lifecycle = game.lifecycle
        targetScore = game.rules.targetScore
        rows = Self.makeRows(for: game)
        inconsistency = Self.makeNotice(for: game)
        if let deletion = undoableDeletion,
           game.lifecycle != .active || game.rounds.map(\.id) != deletion.remainingRoundIDs {
            // Une autre action a modifié l'historique : l'annulation ne s'applique plus.
            undoableDeletion = nil
        }
    }

    // MARK: Correction

    /// Toucher une manche. Une partie close demande d'abord une confirmation de réouverture.
    func requestEdit(roundID: UUID) -> EditRequest {
        guard !isWorking, rows.contains(where: { $0.id == roundID }) else { return .unavailable }
        switch lifecycle {
        case .active:
            undoableDeletion = nil
            return .present(roundID: roundID)
        case .finished:
            pendingReopenRoundID = roundID
            return .needsReopen
        case .archived, nil:
            return .unavailable
        }
    }

    func cancelReopen() {
        pendingReopenRoundID = nil
    }

    /// Rouvre la partie (`reopenGame`) puis renvoie la manche à corriger ; `nil` en cas d'échec
    /// (message dans `actionError`, aucune autre modification).
    func confirmReopen(roundID: UUID) -> UUID? {
        pendingReopenRoundID = nil
        guard !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let reopened = try repository.reopenGame(id: gameID)
            apply(reopened)
        } catch {
            actionError = Self.message(for: GameRepositoryError.from(error, operation: .write))
            load()
            return nil
        }
        guard rows.contains(where: { $0.id == roundID }) else { return nil }
        undoableDeletion = nil
        return roundID
    }

    // MARK: Suppression de la dernière manche

    /// Supprime la dernière manche (confirmation faite par la vue). Renvoie `true` si le dépôt a
    /// été modifié (la vue signale alors le changement au routeur).
    @discardableResult
    func deleteLastRound() -> Bool {
        guard canDeleteLastRound else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let deletion = try repository.deleteLastRound(ofGame: gameID)
            undoableDeletion = UndoableDeletion(
                round: deletion.deletedRound,
                remainingRoundIDs: deletion.game.rounds.map(\.id)
            )
            apply(deletion.game)
            return true
        } catch {
            actionError = Self.message(for: GameRepositoryError.from(error, operation: .write))
            load()
            return false
        }
    }

    /// Rétablit la manche supprimée (même identifiant, même contenu) via `appendRound`, idempotent :
    /// une manche déjà rétablie est un succès sans écriture.
    @discardableResult
    func undoDeletion() -> Bool {
        guard let deletion = undoableDeletion, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try repository.appendRound(deletion.round, toGame: gameID)
            undoableDeletion = nil
            apply(outcome.game)
            return true
        } catch {
            undoableDeletion = nil
            actionError = Self.message(for: GameRepositoryError.from(error, operation: .write))
            load()
            return false
        }
    }

    func dismissUndo() {
        undoableDeletion = nil
    }

    // MARK: Incohérence §4.6

    /// Supprime les manches jouées après la fin de partie, **une à une** depuis la dernière, sur
    /// décision explicite (confirmation faite par la vue).
    ///
    /// Garanties : seules les manches confirmées (`notice.subsequentRoundIDs`) peuvent être
    /// supprimées ; chaque suppression vérifie que la dernière manche fait partie de cet ensemble ;
    /// si les données ont changé depuis l'affichage, rien n'est supprimé et la décision est
    /// redemandée. Limite : le dépôt n'offre pas d'opération atomique pour ce cas ; en cas d'échec
    /// en cours de route, les manches déjà supprimées le restent (ce sont uniquement des manches
    /// confirmées) et l'erreur est affichée. Une partie close est d'abord rouverte.
    @discardableResult
    func deleteRoundsAfterEarlyEnd(confirmed notice: InconsistencyNotice) -> Bool {
        guard !isWorking, isEditable else { return false }
        isWorking = true
        defer { isWorking = false }
        undoableDeletion = nil
        let confirmedIDs = Set(notice.subsequentRoundIDs)
        var changed = false
        do {
            var current = try repository.game(id: gameID)
            guard let live = current.computation.inconsistency,
                  Set(live.subsequentRoundIDs) == confirmedIDs else {
                actionError = "Les manches ont changé depuis l'affichage. Rien n'a été supprimé : vérifiez l'historique."
                apply(current)
                return false
            }
            if current.lifecycle == .finished {
                current = try repository.reopenGame(id: gameID)
                changed = true
            }
            var remainingDeletions = confirmedIDs.count
            while current.computation.inconsistency != nil {
                guard remainingDeletions > 0,
                      let last = current.rounds.last,
                      confirmedIDs.contains(last.id) else {
                    actionError = "La suppression a été interrompue : une manche non confirmée aurait été touchée."
                    break
                }
                current = try repository.deleteLastRound(ofGame: gameID).game
                remainingDeletions -= 1
                changed = true
            }
            apply(current)
        } catch {
            actionError = Self.message(for: GameRepositoryError.from(error, operation: .write))
            load()
        }
        return changed
    }

    // MARK: Mise en forme (aucun calcul de score)

    private static func makeRows(for game: SavedGame) -> [RoundRow] {
        let participants = game.participants
        let names = Dictionary(
            participants.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        let positions = Dictionary(
            participants.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let endingIndex: Int?
        if case .finished(let roundIndex, _) = game.computation.status {
            endingIndex = roundIndex
        } else {
            endingIndex = nil
        }
        let lastRoundID = game.computation.rounds.last?.scoring.roundID

        let rows = game.computation.rounds.map { summary -> RoundRow in
            let scoring = summary.scoring
            let isDoubled = scoring.verdict.isDoubled
            let players = scoring.scores.map { score in
                PlayerLine(
                    participantID: score.participantID,
                    position: positions[score.participantID] ?? 0,
                    name: names[score.participantID] ?? "Joueur",
                    rawScore: score.rawScore,
                    effectiveScore: score.effectiveScore,
                    totalAfterRound: summary.totalsAfterRound[score.participantID],
                    isClosing: score.isClosing,
                    isDoubled: score.isClosing && isDoubled
                )
            }
            let closerName = names[scoring.closingParticipantID] ?? "Joueur"
            let note = closerNote(for: scoring.verdict, names: names)
            let isCorrected = game.info(forRound: scoring.roundID)?.wasCorrected ?? false
            let isEnding = endingIndex == scoring.index
            return RoundRow(
                id: scoring.roundID,
                index: scoring.index,
                closerName: closerName,
                isCloserDoubled: isDoubled,
                closerNote: note,
                isCorrected: isCorrected,
                isEndingRound: isEnding,
                isAfterGameEnd: summary.isAfterGameEnd,
                isLast: scoring.roundID == lastRoundID,
                players: players,
                accessibilityLabel: spokenSummary(
                    index: scoring.index,
                    closerName: closerName,
                    note: note,
                    isCorrected: isCorrected,
                    isEnding: isEnding,
                    isAfterGameEnd: summary.isAfterGameEnd,
                    players: players
                )
            )
        }
        return rows.reversed()
    }

    /// Raison du verdict calculé par le moteur, formulée pour l'affichage (docs/ux §3.2).
    static func closerNote(for verdict: CloserVerdict, names: [UUID: String]) -> String {
        func joined(_ ids: [UUID]) -> String { frenchList(ids.map { names[$0] ?? "Joueur" }) }
        switch verdict {
        case .doubled(let lower, let tied):
            // Cas mixte : priorité au plus petit score (formulation, pas une règle).
            if !lower.isEmpty {
                return "score doublé : \(joined(lower)) \(lower.count > 1 ? "ont" : "a") fait moins"
            }
            return "score doublé : égalité avec \(joined(tied))"
        case .soleLowest:
            return "seul plus petit score, pas de pénalité"
        case .zeroNeverDoubled:
            return "zéro, jamais doublé"
        case .negativeNeverDoubled:
            return "score négatif, jamais doublé"
        case .penaltyDisabledByHouseRules:
            return "pénalité désactivée par les règles maison"
        }
    }

    /// « Alice », « Alice et Bob », « Alice, Bob et Chloé » (indépendant de la langue de l'appareil).
    static func frenchList(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " et " + last
    }

    private static func spokenSummary(
        index: Int,
        closerName: String,
        note: String,
        isCorrected: Bool,
        isEnding: Bool,
        isAfterGameEnd: Bool,
        players: [PlayerLine]
    ) -> String {
        var sentences = ["Manche \(index), \(closerName) a terminé, \(note)"]
        if isCorrected { sentences.append("Manche corrigée") }
        if isEnding { sentences.append("Fin de partie à cette manche") }
        if isAfterGameEnd { sentences.append("Jouée après la fin de la partie") }
        for player in players {
            let total = player.totalAfterRound.map { ScoreFormat.spoken($0) } ?? "inconnu"
            if player.isDoubled {
                sentences.append(
                    "\(player.name) \(ScoreFormat.spoken(player.rawScore)) doublé à "
                        + "\(ScoreFormat.spoken(player.effectiveScore)), total \(total)"
                )
            } else {
                sentences.append("\(player.name) \(ScoreFormat.spoken(player.effectiveScore)), total \(total)")
            }
        }
        return sentences.joined(separator: ". ") + "."
    }

    private static func makeNotice(for game: SavedGame) -> InconsistencyNotice? {
        guard let inconsistency = game.computation.inconsistency,
              !inconsistency.subsequentRoundIDs.isEmpty else { return nil }
        let ids = Set(inconsistency.subsequentRoundIDs)
        let indices = game.computation.rounds
            .filter { ids.contains($0.scoring.roundID) }
            .map(\.scoring.index)
        guard let first = indices.first, let last = indices.last else { return nil }

        let rangeText: String
        let roundsText: String
        switch indices.count {
        case 1:
            rangeText = "la manche \(first)"
            roundsText = "La manche \(first) a été jouée ensuite."
        case 2:
            rangeText = "les manches \(first) et \(last)"
            roundsText = "Les manches \(first) et \(last) ont été jouées ensuite."
        default:
            rangeText = "les manches \(first) à \(last)"
            roundsText = "Les manches \(first) à \(last) ont été jouées ensuite."
        }
        let requiresReopen = game.lifecycle == .finished
        var message = "Le seuil de \(game.rules.targetScore) points a été atteint à la manche "
            + "\(inconsistency.endingRoundIndex). \(roundsText) Rien n'a été effacé : corrigez une "
            + "manche ou supprimez les manches jouées après la fin."
        if game.lifecycle == .archived {
            message += " Partie interrompue : lecture seule."
        }
        let count = indices.count
        var confirmationMessage = "\(rangeText.prefix(1).uppercased() + rangeText.dropFirst()) "
            + "\(count > 1 ? "seront effacées" : "sera effacée"). Cette action ne peut pas être annulée."
        if requiresReopen {
            confirmationMessage += " La partie sera rouverte."
        }
        return InconsistencyNotice(
            endingRoundIndex: inconsistency.endingRoundIndex,
            subsequentRoundIndices: indices,
            subsequentRoundIDs: inconsistency.subsequentRoundIDs,
            requiresReopen: requiresReopen,
            title: "La partie aurait dû se terminer",
            message: message,
            actionTitle: "Supprimer \(rangeText)",
            confirmationTitle: count > 1
                ? "Supprimer définitivement \(count) manches ?"
                : "Supprimer définitivement la manche \(first) ?",
            confirmationMessage: confirmationMessage,
            confirmationButtonTitle: count > 1 ? "Supprimer \(count) manches" : "Supprimer la manche \(first)"
        )
    }

    private static func message(for error: GameRepositoryError) -> String {
        switch error {
        case .anotherGameActive:
            "Une autre partie est en cours. Terminez-la ou abandonnez-la avant de corriger celle-ci."
        case .noRoundToDelete:
            "Aucune manche à supprimer."
        default:
            error.userFacingMessage
        }
    }
}
