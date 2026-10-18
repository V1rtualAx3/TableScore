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

    /// Aucune variante active : équivalent aux règles officielles.
    public var isEmpty: Bool { self == HouseRules() }
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
    /// `nil` = aucune variante. Des règles maison sans variante active sont normalisées en `nil`.
    public var houseRules: HouseRules? {
        didSet { houseRules = Self.normalized(houseRules) }
    }

    public init(
        edition: GameEdition = .classic,
        targetScore: Int = GameRules.officialTargetScore,
        houseRules: HouseRules? = nil
    ) {
        self.edition = edition
        self.targetScore = targetScore
        self.houseRules = Self.normalized(houseRules)
    }

    /// Le doublement du clôturant s'applique sauf désactivation explicite en règles maison.
    public var isCloserPenaltyActive: Bool {
        !(houseRules?.isCloserPenaltyDisabled ?? false)
    }

    /// Vrai si le calcul suit strictement la règle officielle (classique, 100 points, pénalité active).
    public var isOfficial: Bool {
        edition == .classic && targetScore == Self.officialTargetScore && isCloserPenaltyActive
    }

    private static func normalized(_ houseRules: HouseRules?) -> HouseRules? {
        guard let houseRules, !houseRules.isEmpty else { return nil }
        return houseRules
    }

    // MARK: Codable (le décodage passe par l'initialiseur pour normaliser)

    private enum CodingKeys: String, CodingKey {
        case edition, targetScore, houseRules
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let edition = try container.decode(GameEdition.self, forKey: .edition)
        let targetScore = try container.decode(Int.self, forKey: .targetScore)
        let houseRules = try container.decodeIfPresent(HouseRules.self, forKey: .houseRules)
        self.init(edition: edition, targetScore: targetScore, houseRules: houseRules)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(edition, forKey: .edition)
        try container.encode(targetScore, forKey: .targetScore)
        try container.encodeIfPresent(houseRules, forKey: .houseRules)
    }
}
