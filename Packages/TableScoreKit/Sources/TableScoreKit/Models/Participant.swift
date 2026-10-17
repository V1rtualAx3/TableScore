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

    /// Longueur maximale d'un nom, en caractères perçus (graphèmes), espaces de bordure exclus.
    /// Décision UX (lisibilité du tableau des scores), pas une règle du jeu.
    public static let maxDisplayNameLength = 24

    /// Nom sans espaces de bordure ; vide ⇒ nom invalide.
    public var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Vrai si le texte contient un caractère de contrôle (retour à la ligne, tabulation, NUL…)
    /// ou un séparateur de ligne/paragraphe Unicode. Les caractères de format (ex. le liant
    /// U+200D des émojis composés) restent autorisés.
    public static func containsDisallowedCharacters(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                return true
            default:
                continue
            }
        }
        return false
    }
}
