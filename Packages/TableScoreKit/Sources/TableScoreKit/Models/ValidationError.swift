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
    case gameAlreadyFinished(atRoundIndex: Int)

    // Grille de cartes
    case invalidGridShape
    case cardValueOutOfRange(Int)
    case cardPositionOutOfRange(column: Int, row: Int)
    case incompleteCardGrid(participantID: UUID)
    case cardGridScoreMismatch(participantID: UUID, expected: Int, found: Int)

    // Arithmétique : dépassement de capacité d'`Int` (doublement ou cumul).
    case arithmeticOverflow(participantID: UUID)
}
