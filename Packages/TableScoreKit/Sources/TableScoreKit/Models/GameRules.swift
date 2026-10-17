import Foundation

/// Édition du jeu prise en charge. Seul Skyjo classique est implémenté
/// (ni Skyjo Action, ni Skyjo Junior).
public enum GameEdition: String, Codable, Sendable, Hashable, CaseIterable {
    case classic
}

/// Variantes « règles maison », hors règle officielle. Jamais actives par défaut.
public struct HouseRules: Codable, Sendable, Hashable {
    /// Désactive le doublement du score du clôturant (variante non officielle).
    public var isCloserPenaltyDisabled: Bool

    public init(isCloserPenaltyDisabled: Bool = false) {
        self.isCloserPenaltyDisabled = isCloserPenaltyDisabled
    }
}

/// Règles d'une partie. Valeur par défaut : Skyjo classique, fin à 100 points, sans règle maison.
public struct GameRules: Codable, Sendable, Hashable {
    /// Seuil officiel de fin de partie.
    public static let officialTargetScore = 100
    /// Bornes techniques raisonnables d'un seuil personnalisé (règles maison).
    public static let allowedTargetScores: ClosedRange<Int> = 1...1_000
    /// Configuration officielle par défaut.
    public static let classic = GameRules()

    public var edition: GameEdition
    /// La partie se termine après la manche où au moins un cumul atteint ou dépasse ce seuil.
    public var targetScore: Int
    /// `nil` = règles officielles. Une variante n'est active que si elle est explicitement fournie ici.
    public var houseRules: HouseRules?

    public init(
        edition: GameEdition = .classic,
        targetScore: Int = GameRules.officialTargetScore,
        houseRules: HouseRules? = nil
    ) {
        self.edition = edition
        self.targetScore = targetScore
        self.houseRules = houseRules
    }

    /// Le doublement du clôturant s'applique sauf désactivation explicite en règles maison.
    public var isCloserPenaltyActive: Bool {
        !(houseRules?.isCloserPenaltyDisabled ?? false)
    }

    /// Vrai si la partie suit strictement la configuration officielle (classique, 100 points).
    public var isOfficial: Bool {
        edition == .classic && houseRules == nil && targetScore == Self.officialTargetScore
    }
}
