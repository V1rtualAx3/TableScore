import Foundation

/// Joueur d'une partie. L'identifiant est stable : changer l'ordre d'affichage ou le nom
/// ne modifie jamais l'identité ni les scores associés.
public struct Participant: Codable, Sendable, Hashable, Identifiable {
    /// Nombre de joueurs autorisé par la règle classique.
    public static let allowedCount: ClosedRange<Int> = 2...8

    public let id: UUID
    public var displayName: String
    /// Ordre d'affichage explicite et stable (unique au sein d'une partie).
    public var displayOrder: Int

    public init(id: UUID = UUID(), displayName: String, displayOrder: Int) {
        self.id = id
        self.displayName = displayName
        self.displayOrder = displayOrder
    }

    /// Nom sans espaces de bordure ; vide ⇒ nom invalide.
    public var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
