import Foundation
import TableScoreKit

/// Partie telle que stockée (source de vérité) + son recalcul intégral par `ScoreEngine`.
///
/// Seuls participants, règles, manches (scores bruts, clôturant, saisie), statut et dates sont
/// persistés. `computation` (scores retenus, cumuls, classement, fin de partie) est **toujours
/// dérivé** à la construction et n'est jamais écrit.
///
/// Forme normalisée (identique quelle que soit l'implémentation du dépôt) : participants triés par
/// ordre d'affichage, manches par indice, entrées de chaque manche dans l'ordre des participants.
struct SavedGame: Sendable, Hashable, Identifiable {
    let id: UUID
    let title: String?
    let lifecycle: GameLifecycle
    let rules: GameRules
    let participants: [Participant]
    let rounds: [RoundInput]
    /// Dérivé de `participants`, `rules` et `rounds` ; jamais persisté.
    let computation: GameComputation
    let createdAt: Date
    let updatedAt: Date
    let finishedAt: Date?
    let archivedAt: Date?

    /// Seul initialiseur accessible : valide et recalcule toute la partie.
    init(
        id: UUID,
        title: String?,
        lifecycle: GameLifecycle,
        rules: GameRules,
        participants: [Participant],
        rounds: [RoundInput],
        createdAt: Date,
        updatedAt: Date,
        finishedAt: Date?,
        archivedAt: Date?
    ) throws(ValidationError) {
        let orderedParticipants = participants.sorted { $0.displayOrder < $1.displayOrder }
        let computation = try ScoreEngine.computeGame(
            participants: orderedParticipants,
            rounds: rounds,
            rules: rules
        )
        let order = Self.displayOrderByParticipant(orderedParticipants)
        let orderedRounds = rounds
            .sorted { $0.index < $1.index }
            .map { Self.normalized($0, order: order) }
        self.init(
            validatedID: id,
            title: title,
            lifecycle: lifecycle,
            rules: rules,
            participants: orderedParticipants,
            rounds: orderedRounds,
            computation: computation,
            createdAt: createdAt,
            updatedAt: updatedAt,
            finishedAt: finishedAt,
            archivedAt: archivedAt
        )
    }

    private init(
        validatedID id: UUID,
        title: String?,
        lifecycle: GameLifecycle,
        rules: GameRules,
        participants: [Participant],
        rounds: [RoundInput],
        computation: GameComputation,
        createdAt: Date,
        updatedAt: Date,
        finishedAt: Date?,
        archivedAt: Date?
    ) {
        self.id = id
        self.title = title
        self.lifecycle = lifecycle
        self.rules = rules
        self.participants = participants
        self.rounds = rounds
        self.computation = computation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.archivedAt = archivedAt
    }

    /// Vrai si le moteur considère la partie terminée (seuil atteint après une manche).
    var isOver: Bool {
        if case .finished = computation.status { return true }
        return false
    }

    /// Partie rangée alors qu'elle n'était pas terminée (« Interrompue »). Dérivé, jamais stocké.
    var isInterrupted: Bool {
        lifecycle == .archived && !isOver
    }

    /// Manche mise sous la forme normalisée de cette partie (comparaison d'idempotence).
    func normalized(_ round: RoundInput) -> RoundInput {
        Self.normalized(round, order: Self.displayOrderByParticipant(participants))
    }

    /// Nouvel historique : recalcul intégral (validation complète par le moteur).
    func replacingRounds(_ newRounds: [RoundInput], updatedAt date: Date) throws(ValidationError) -> SavedGame {
        try SavedGame(
            id: id,
            title: title,
            lifecycle: lifecycle,
            rules: rules,
            participants: participants,
            rounds: newRounds,
            createdAt: createdAt,
            updatedAt: date,
            finishedAt: finishedAt,
            archivedAt: archivedAt
        )
    }

    /// Changement de statut seul : l'historique et donc le calcul sont inchangés.
    func updatingLifecycle(
        _ newLifecycle: GameLifecycle,
        updatedAt date: Date,
        finishedAt newFinishedAt: Date?,
        archivedAt newArchivedAt: Date?
    ) -> SavedGame {
        SavedGame(
            validatedID: id,
            title: title,
            lifecycle: newLifecycle,
            rules: rules,
            participants: participants,
            rounds: rounds,
            computation: computation,
            createdAt: createdAt,
            updatedAt: date,
            finishedAt: newFinishedAt,
            archivedAt: newArchivedAt
        )
    }

    // MARK: Normalisation

    private static func displayOrderByParticipant(_ participants: [Participant]) -> [UUID: Int] {
        // `uniquingKeysWith` : jamais de crash, même sur des données non encore validées.
        Dictionary(participants.map { ($0.id, $0.displayOrder) }, uniquingKeysWith: { first, _ in first })
    }

    private static func normalized(_ round: RoundInput, order: [UUID: Int]) -> RoundInput {
        var copy = round
        copy.entries = round.entries.sorted { lhs, rhs in
            let lhsOrder = order[lhs.participantID] ?? Int.max
            let rhsOrder = order[rhs.participantID] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.participantID.uuidString < rhs.participantID.uuidString
        }
        return copy
    }
}
