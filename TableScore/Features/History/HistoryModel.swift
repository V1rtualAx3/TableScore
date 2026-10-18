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
        /// Grille enregistrée si le score a été saisi en mode « Cartes » (consultation en lecture
        /// seule) ; `nil` pour une saisie en points.
        var cardGrid: CardGrid? = nil

        var isCardsEntry: Bool { cardGrid != nil }
    }

    /// Une manche de l'historique, prête à afficher.
    struct RoundRow: Identifiable, Hashable, Sendable {
        let id: UUID
        let index: Int
        let closerName: String
        let isCloserDoubled: Bool
        /// Raison du verdict, en minuscules (`VerdictText.reason` : « score doublé : égalité avec
        /// Chloé », « zéro n'est jamais doublé »…).
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

        var displayedCloserNote: String { VerdictText.sentenceCase(closerNote) }

        /// Joueurs saisis en mode « Cartes » (ordre d'affichage).
        var cardPlayers: [PlayerLine] { players.filter(\.isCardsEntry) }
        var hasCardEntries: Bool { players.contains(where: \.isCardsEntry) }
        /// Bouton de consultation des grilles : « Voir les cartes de la manche 3 ».
        var cardsButtonTitle: String { "Voir les cartes de la manche \(index)" }
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
        /// Identifiants confirmés par l'utilisateur (vérifiés à nouveau par le dépôt, dans la même
        /// transaction que la suppression).
        let subsequentRoundIDs: [UUID]
        let title: String
        let message: String
        let actionTitle: String
        let confirmationTitle: String
        let confirmationMessage: String
        let confirmationButtonTitle: String
    }

    /// Suite à donner au toucher d'une manche.
    enum EditRequest: Hashable, Sendable {
        /// Présenter le formulaire de correction de cette manche (partie active ou terminée :
        /// aucune écriture ici ; une partie terminée n'est rouverte qu'à l'enregistrement).
        case present(roundID: UUID)
        /// Lecture seule (partie interrompue, manche inconnue, opération en cours, autre partie
        /// en cours pour une partie terminée — message dans `actionError`).
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
    /// Message d'erreur d'une action (alerte) ; remis à `nil` à la fermeture de l'alerte.
    var actionError: String?

    init(gameID: UUID, repository: any GameRepository) {
        self.gameID = gameID
        self.repository = repository
    }

    /// Modèle à afficher pour `gameID` : `existing` seulement s'il concerne la même partie
    /// (l'écran peut être réutilisé par la navigation pour une autre partie).
    static func resolve(_ existing: HistoryModel?, gameID: UUID, repository: any GameRepository) -> HistoryModel {
        if let existing, existing.gameID == gameID { return existing }
        return HistoryModel(gameID: gameID, repository: repository)
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
        guard let lastRound else { return "Supprimer la dernière manche\u{202F}?" }
        return "Supprimer la manche \(lastRound.index)\u{202F}?"
    }

    var deletionConfirmationButtonTitle: String {
        guard let lastRound else { return "Supprimer" }
        return "Supprimer la manche \(lastRound.index)"
    }

    var lifecycleNote: String? {
        switch lifecycle {
        case .finished:
            "Partie terminée. Touchez une manche pour la corriger."
        case .archived:
            "Partie interrompue\u{00A0}: historique en lecture seule."
        case .active, nil:
            nil
        }
    }

    // MARK: Chargement

    /// Relit la partie (appelé sur `.task(id: router.reloadKey(for: gameID))`). Synchrone : volume minuscule.
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

    /// Toucher une manche : présente directement la correction, **sans écriture** ni dialogue,
    /// y compris pour une partie terminée (la feuille la rouvre seulement au moment d'enregistrer,
    /// puis rétablit « terminée » si la partie l'est encore ; voir `RoundEntryModel`).
    ///
    /// Une partie terminée ne peut pas être corrigée si une autre partie est en cours (une seule
    /// partie active) : message explicite au lieu d'une feuille vouée à l'échec.
    func requestEdit(roundID: UUID) -> EditRequest {
        guard !isWorking, rows.contains(where: { $0.id == roundID }) else { return .unavailable }
        switch lifecycle {
        case .active:
            undoableDeletion = nil
            return .present(roundID: roundID)
        case .finished:
            // Lecture seule ; en cas d'erreur de lecture, l'enregistrement signalera le problème.
            if let other = try? repository.activeGame(), other.id != gameID {
                actionError = CorrectionText.anotherGameActive
                return .unavailable
            }
            undoableDeletion = nil
            return .present(roundID: roundID)
        case .archived, nil:
            return .unavailable
        }
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

    /// Supprime les manches jouées après la fin de partie, sur décision explicite (confirmation
    /// faite par la vue), en **une seule transaction** (`GameRepository.deleteRoundsAfterEarlyEnd`).
    ///
    /// Garanties (vérifiées par le dépôt au moment d'écrire) : seules les manches confirmées
    /// (`notice.subsequentRoundIDs`) sont supprimées, et seulement si elles correspondent encore
    /// exactement au calcul du moteur ; sinon rien n'est supprimé et la décision est redemandée.
    /// En cas d'échec, rien n'est supprimé. Statut inchangé : une partie terminée le reste.
    @discardableResult
    func deleteRoundsAfterEarlyEnd(confirmed notice: InconsistencyNotice) -> Bool {
        guard !isWorking, isEditable else { return false }
        isWorking = true
        defer { isWorking = false }
        undoableDeletion = nil
        do {
            let updated = try repository.deleteRoundsAfterEarlyEnd(
                gameID: gameID,
                confirmedRoundIDs: notice.subsequentRoundIDs
            )
            apply(updated)
            return true
        } catch {
            actionError = Self.message(for: GameRepositoryError.from(error, operation: .write))
            load()
            return false
        }
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
        // Saisies d'origine (mode et grille) : seulement pour l'affichage, jamais recalculées ici.
        let inputs = Dictionary(game.rounds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let rows = game.computation.rounds.map { summary -> RoundRow in
            let scoring = summary.scoring
            let isDoubled = scoring.verdict.isDoubled
            let input = inputs[scoring.roundID]
            let players = scoring.scores.map { score in
                PlayerLine(
                    participantID: score.participantID,
                    position: positions[score.participantID] ?? 0,
                    name: names[score.participantID] ?? "Joueur",
                    rawScore: score.rawScore,
                    effectiveScore: score.effectiveScore,
                    totalAfterRound: summary.totalsAfterRound[score.participantID],
                    isClosing: score.isClosing,
                    isDoubled: score.isClosing && isDoubled,
                    cardGrid: input?.entry(for: score.participantID)?.cardGrid
                )
            }
            let closerName = names[scoring.closingParticipantID] ?? "Joueur"
            let note = VerdictText.reason(for: scoring.verdict, nameOf: { names[$0] ?? "Joueur" })
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
            let method = player.isCardsEntry ? ", saisi en cartes" : ""
            if player.isDoubled {
                sentences.append(
                    "\(player.name) \(ScoreFormat.spoken(player.rawScore)) doublé à "
                        + "\(ScoreFormat.spoken(player.effectiveScore))\(method), total \(total)"
                )
            } else {
                sentences.append(
                    "\(player.name) \(ScoreFormat.spoken(player.effectiveScore))\(method), total \(total)"
                )
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

        guard !indices.isEmpty else { return nil }

        var message = "Le seuil de \(game.rules.targetScore) points a été atteint à la manche "
            + "\(inconsistency.endingRoundIndex). \(LaterRoundsText.playedAfterSentence(indices)) "
            + "Rien n'a été effacé\u{00A0}: corrigez une manche ou supprimez les manches jouées après la fin."
        if game.lifecycle == .archived {
            message += " Partie interrompue\u{00A0}: lecture seule."
        }
        return InconsistencyNotice(
            endingRoundIndex: inconsistency.endingRoundIndex,
            subsequentRoundIndices: indices,
            subsequentRoundIDs: inconsistency.subsequentRoundIDs,
            title: "La partie aurait dû se terminer",
            message: message,
            actionTitle: "Supprimer \(LaterRoundsText.range(indices))",
            confirmationTitle: LaterRoundsText.deletionTitle(indices),
            confirmationMessage: LaterRoundsText.deletionMessage(indices),
            confirmationButtonTitle: LaterRoundsText.deletionButton(indices)
        )
    }

    private static func message(for error: GameRepositoryError) -> String {
        switch error {
        case .anotherGameActive:
            CorrectionText.anotherGameActive
        case .noRoundToDelete:
            "Aucune manche à supprimer."
        default:
            error.userFacingMessage
        }
    }
}
