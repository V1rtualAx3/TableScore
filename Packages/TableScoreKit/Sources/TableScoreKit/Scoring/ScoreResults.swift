import Foundation

/// Décision sur le score du clôturant, avec sa raison (pour la prévisualisation et l'historique).
public enum CloserVerdict: Sendable, Hashable {
    /// Score brut positif et au moins un autre joueur a un score brut inférieur ou égal : doublé.
    /// Les identifiants sont dans l'ordre d'affichage des participants.
    case doubled(lowerParticipantIDs: [UUID], tiedParticipantIDs: [UUID])
    /// Seul avec le plus petit score brut : non doublé.
    case soleLowest
    /// Score brut nul : jamais doublé.
    case zeroNeverDoubled
    /// Score brut négatif : jamais doublé, même en cas d'égalité.
    case negativeNeverDoubled
    /// Le doublement aurait dû s'appliquer mais la règle maison le désactive.
    case penaltyDisabledByHouseRules

    public var isDoubled: Bool {
        if case .doubled = self { return true }
        return false
    }
}

/// Score d'un participant pour une manche.
public struct ParticipantRoundScore: Sendable, Hashable {
    public let participantID: UUID
    public let rawScore: Int
    /// Score retenu (égal au brut sauf clôturant doublé).
    public let effectiveScore: Int
    public let isClosing: Bool
}

/// Résultat du calcul d'une manche.
public struct RoundScoring: Sendable, Hashable {
    public let roundID: UUID
    public let index: Int
    public let closingParticipantID: UUID
    public let closingRawScore: Int
    public let closingEffectiveScore: Int
    public let verdict: CloserVerdict
    /// Scores dans l'ordre d'affichage des participants.
    public let scores: [ParticipantRoundScore]

    public func score(for participantID: UUID) -> ParticipantRoundScore? {
        scores.first { $0.participantID == participantID }
    }
}

/// Manche recalculée dans l'historique, avec les cumuls obtenus après elle.
public struct RoundSummary: Sendable, Hashable {
    public let scoring: RoundScoring
    public let totalsAfterRound: [UUID: Int]
    /// Au moins un cumul atteint ou dépasse le seuil après cette manche.
    public let reachesTargetScore: Bool
    /// Manche enregistrée après celle qui aurait dû terminer la partie (incohérence à arbitrer).
    public let isAfterGameEnd: Bool
}

/// Position au classement. Les égalités partagent le même rang (1, 1, 3…).
public struct Standing: Sendable, Hashable {
    public let participantID: UUID
    public let total: Int
    public let rank: Int

    public var isLeader: Bool { rank == 1 }
}

public enum GameStatus: Sendable, Hashable {
    case inProgress
    /// Partie terminée à la fin de la manche `roundIndex` ; vainqueur(s) = plus petit cumul à cette
    /// manche, co-vainqueurs en cas d'égalité, dans l'ordre d'affichage.
    case finished(roundIndex: Int, winnerIDs: [UUID])
}

/// Des manches existent après celle qui a terminé la partie (typiquement après une correction).
/// Rien n'est supprimé : la décision revient explicitement à l'utilisateur.
public struct EarlyEndInconsistency: Sendable, Hashable {
    public let endingRoundIndex: Int
    public let subsequentRoundIDs: [UUID]
}

/// Recalcul intégral d'une partie à partir de son historique.
public struct GameComputation: Sendable, Hashable {
    /// Manches dans l'ordre des indices, y compris celles postérieures à une fin anticipée.
    public let rounds: [RoundSummary]
    /// Cumuls après la dernière manche enregistrée.
    public let totals: [UUID: Int]
    /// Classement sur `totals` (égalités : ordre d'affichage).
    public let standings: [Standing]
    public let status: GameStatus
    public let inconsistency: EarlyEndInconsistency?

    /// Une nouvelle manche ne peut être ajoutée qu'à une partie en cours.
    public var acceptsNewRound: Bool { status == .inProgress }
    public var nextRoundIndex: Int { RoundInput.firstIndex + rounds.count }
}
