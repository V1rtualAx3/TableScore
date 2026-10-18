import Foundation

/// Erreurs de validation du domaine. Toute donnée incohérente produit une erreur typée,
/// jamais un crash ni une valeur par défaut implicite.
public enum ValidationError: Error, Sendable, Hashable {
    // Règles
    case invalidTargetScore(Int)

    // Participants
    case participantCountOutOfRange(count: Int)
    case duplicateParticipantID(UUID)
    case duplicateDisplayOrder(Int)
    case emptyParticipantName(participantID: UUID)
    /// Nom (sans espaces de bordure) au-delà de `Participant.maxDisplayNameLength` graphèmes ou de
    /// `Participant.maxDisplayNameByteCount` octets UTF-8 ; `maxLength` est la limite en graphèmes.
    case participantNameTooLong(participantID: UUID, maxLength: Int)
    /// Caractère de contrôle ou retour à la ligne dans le nom.
    case participantNameHasInvalidCharacters(participantID: UUID)

    // Manche
    case unknownParticipant(UUID)
    case duplicateEntry(participantID: UUID)
    case missingEntry(participantID: UUID)
    case closingParticipantNotInGame(UUID)
    case missingClosingParticipant
    case missingScore(participantID: UUID)

    // Historique
    case roundIndexMismatch(expected: Int, found: Int)
    case duplicateRoundID(UUID)
    case unknownRound(UUID)
    case gameAlreadyFinished(atRoundIndex: Int)
    /// Erreur survenue en recalculant la manche `index` de l'historique (entrées, grille, cumul).
    indirect case invalidRound(index: Int, reason: ValidationError)

    // Grille de cartes
    case invalidGridShape
    case cardValueOutOfRange(Int)
    case cardPositionOutOfRange(column: Int, row: Int)
    case incompleteCardGrid(participantID: UUID)
    case cardGridScoreMismatch(participantID: UUID, expected: Int, found: Int)

    // Arithmétique : dépassement de capacité d'`Int` (doublement ou cumul).
    case arithmeticOverflow(participantID: UUID)

    /// Cause élémentaire, sans le contexte de manche.
    public var underlyingReason: ValidationError {
        if case .invalidRound(_, let reason) = self { return reason.underlyingReason }
        return self
    }
}
