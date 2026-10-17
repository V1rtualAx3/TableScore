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
    /// Borne en octets UTF-8 : un graphème peut accumuler des marques combinantes (« zalgo »).
    public static let maxDisplayNameByteCount = 256

    /// Contrôles de direction bidirectionnelle (LRE…RLO, LRI…PDI) : refusés, ils permettent de
    /// maquiller l'affichage d'un texte.
    private static let bidiControlRanges: [ClosedRange<UInt32>] = [0x202A...0x202E, 0x2066...0x2069]

    /// Nom sans espaces de bordure ; vide ⇒ nom invalide.
    public var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Vrai si le texte contient un caractère de contrôle (retour à la ligne, tabulation, NUL…),
    /// un séparateur de ligne/paragraphe Unicode ou un contrôle bidirectionnel. Les autres
    /// caractères de format restent autorisés (ex. le liant U+200D des émojis composés ; le
    /// sélecteur U+FE0F est une marque, également autorisée).
    public static func containsDisallowedCharacters(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if bidiControlRanges.contains(where: { $0.contains(scalar.value) }) {
                return true
            }
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                return true
            default:
                continue
            }
        }
        return false
    }

    /// Vrai si le texte contient au moins un caractère visible, c'est-à-dire autre qu'un espace
    /// ou un caractère de format invisible (U+200B, U+2060, U+FEFF…).
    public static func hasVisibleContent(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace { continue }
            if scalar.properties.generalCategory == .format { continue }
            return true
        }
        return false
    }
}
