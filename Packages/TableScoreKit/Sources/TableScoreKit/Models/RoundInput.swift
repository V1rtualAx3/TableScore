import Foundation

/// Mode de saisie d'un score de manche.
public enum InputMethod: String, Codable, Sendable, Hashable, CaseIterable {
    /// Saisie directe du score brut (flux principal). Les colonnes ont déjà été retirées physiquement :
    /// l'application ne soustrait rien une seconde fois.
    case points
    /// Aide au décompte par grille de cartes.
    case cards
}

/// Origine d'un score brut. Une saisie « cartes » embarque toujours sa grille : aucun état
/// « cartes sans grille » n'est représentable.
public enum EntrySource: Codable, Sendable, Hashable {
    case points
    case cards(CardGrid)
}

/// Score brut signé d'un participant pour une manche (avant toute pénalité).
public struct RoundEntry: Codable, Sendable, Hashable {
    public let participantID: UUID
    /// Score brut signé. Source de vérité ; le score retenu est toujours dérivé par `ScoreEngine`.
    public let rawScore: Int
    public let source: EntrySource

    public init(participantID: UUID, rawScore: Int, source: EntrySource = .points) {
        self.participantID = participantID
        self.rawScore = rawScore
        self.source = source
    }

    /// Entrée saisie en points.
    public static func points(_ participantID: UUID, rawScore: Int) -> RoundEntry {
        RoundEntry(participantID: participantID, rawScore: rawScore, source: .points)
    }

    /// Entrée calculée depuis une grille complète.
    public static func cards(_ participantID: UUID, grid: CardGrid) throws(ValidationError) -> RoundEntry {
        guard let rawScore = grid.evaluate().rawScore else {
            throw ValidationError.incompleteCardGrid(participantID: participantID)
        }
        return RoundEntry(participantID: participantID, rawScore: rawScore, source: .cards(grid))
    }

    public var inputMethod: InputMethod {
        switch source {
        case .points: .points
        case .cards: .cards
        }
    }

    public var cardGrid: CardGrid? {
        if case .cards(let grid) = source { return grid }
        return nil
    }
}

/// Manche saisie : scores bruts + clôturant unique. Les scores retenus et cumuls n'y sont pas
/// stockés : ils sont recalculés par `ScoreEngine`.
public struct RoundInput: Codable, Sendable, Hashable, Identifiable {
    /// Indice de la première manche (« Manche 1 »). Les indices sont continus.
    public static let firstIndex = 1

    /// Identifiant stable, utilisé aussi pour détecter une double soumission.
    public let id: UUID
    public var index: Int
    /// Un et un seul clôturant par construction.
    public var closingParticipantID: UUID
    public var entries: [RoundEntry]

    public init(id: UUID = UUID(), index: Int, closingParticipantID: UUID, entries: [RoundEntry]) {
        self.id = id
        self.index = index
        self.closingParticipantID = closingParticipantID
        self.entries = entries
    }

    public func entry(for participantID: UUID) -> RoundEntry? {
        entries.first { $0.participantID == participantID }
    }

    /// Remplace l'entrée du participant (correction) ou l'ajoute si absente.
    public mutating func setEntry(_ entry: RoundEntry) {
        if let position = entries.firstIndex(where: { $0.participantID == entry.participantID }) {
            entries[position] = entry
        } else {
            entries.append(entry)
        }
    }
}
