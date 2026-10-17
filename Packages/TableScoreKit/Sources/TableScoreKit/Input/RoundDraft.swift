import Foundation

/// Saisie en cours pour un participant. Les données « points » et « cartes » sont conservées
/// toutes les deux : basculer de mode ne perd rien.
public struct DraftEntry: Codable, Sendable, Hashable {
    public var inputMethod: InputMethod
    /// Score saisi en mode points ; `nil` = vide (distinct de 0).
    public var points: Int?
    public var cardGrid: CardGrid

    public init(inputMethod: InputMethod = .points, points: Int? = nil, cardGrid: CardGrid = CardGrid()) {
        self.inputMethod = inputMethod
        self.points = points
        self.cardGrid = cardGrid
    }

    /// Score brut selon le mode actif ; `nil` si incomplet.
    public var rawScore: Int? {
        switch inputMethod {
        case .points: points
        case .cards: cardGrid.evaluate().rawScore
        }
    }

    func makeEntry(participantID: UUID) throws(ValidationError) -> RoundEntry {
        switch inputMethod {
        case .points:
            guard let points else { throw ValidationError.missingScore(participantID: participantID) }
            return .points(participantID, rawScore: points)
        case .cards:
            return try RoundEntry.cards(participantID, grid: cardGrid)
        }
    }
}

/// Résultat de l'analyse d'un texte saisi pour un score.
public enum ParsedScore: Sendable, Hashable {
    case empty
    case value(Int)
    /// Caractères non numériques ou valeur hors capacité d'`Int`.
    case invalid
}

/// Brouillon d'une manche, avant validation. L'identifiant de manche est fixé à la création :
/// une seconde soumission du même brouillon est détectable (`ScoreEngine.containsRound`).
public struct RoundDraft: Codable, Sendable, Hashable {
    public let roundID: UUID
    public let index: Int
    /// Participants dans l'ordre d'affichage (stable pendant la saisie).
    public let participantIDs: [UUID]
    public private(set) var entries: [UUID: DraftEntry]
    /// Clôturant unique ; `nil` tant qu'il n'est pas choisi.
    public var closingParticipantID: UUID?

    public init(roundID: UUID = UUID(), index: Int, participants: [Participant]) {
        self.roundID = roundID
        self.index = index
        let ordered = participants.sorted { $0.displayOrder < $1.displayOrder }
        self.participantIDs = ordered.map { $0.id }
        var entries: [UUID: DraftEntry] = [:]
        for participant in ordered { entries[participant.id] = DraftEntry() }
        self.entries = entries
        self.closingParticipantID = nil
    }

    /// Brouillon pré-rempli pour corriger une manche existante (même identifiant, même indice).
    public init(editing round: RoundInput, participants: [Participant]) {
        self.init(roundID: round.id, index: round.index, participants: participants)
        closingParticipantID = round.closingParticipantID
        for entry in round.entries where entries[entry.participantID] != nil {
            switch entry.source {
            case .points:
                entries[entry.participantID] = DraftEntry(inputMethod: .points, points: entry.rawScore)
            case .cards(let grid):
                entries[entry.participantID] = DraftEntry(inputMethod: .cards, points: entry.rawScore, cardGrid: grid)
            }
        }
    }

    public func entry(for participantID: UUID) -> DraftEntry? {
        entries[participantID]
    }

    /// Modifie l'entrée d'un participant ; renvoie `false` si le participant est étranger au brouillon.
    @discardableResult
    public mutating func updateEntry(for participantID: UUID, _ update: (inout DraftEntry) -> Void) -> Bool {
        guard var entry = entries[participantID] else { return false }
        update(&entry)
        entries[participantID] = entry
        return true
    }

    @discardableResult
    public mutating func setPoints(_ points: Int?, for participantID: UUID) -> Bool {
        updateEntry(for: participantID) { $0.points = points }
    }

    /// Participants sans score exploitable, dans l'ordre d'affichage.
    public var missingScoreParticipantIDs: [UUID] {
        participantIDs.filter { entries[$0]?.rawScore == nil }
    }

    /// Vrai seulement si tous les scores sont renseignés et un clôturant membre est choisi.
    public var canSubmit: Bool {
        (try? makeRoundInput()) != nil
    }

    /// Convertit le brouillon en manche. La validation complète (membres, cumuls, doublon)
    /// est ensuite assurée par `ScoreEngine.computeAppending`.
    public func makeRoundInput() throws(ValidationError) -> RoundInput {
        var roundEntries: [RoundEntry] = []
        roundEntries.reserveCapacity(participantIDs.count)
        for participantID in participantIDs {
            guard let draft = entries[participantID] else {
                throw ValidationError.missingScore(participantID: participantID)
            }
            let entry = try draft.makeEntry(participantID: participantID)
            roundEntries.append(entry)
        }
        guard let closingParticipantID else { throw ValidationError.missingClosingParticipant }
        guard participantIDs.contains(closingParticipantID) else {
            throw ValidationError.closingParticipantNotInGame(closingParticipantID)
        }
        return RoundInput(
            id: roundID,
            index: index,
            closingParticipantID: closingParticipantID,
            entries: roundEntries
        )
    }

    /// Analyse un texte de score signé. Accepte « - », « − » (U+2212) et « + » en tête ;
    /// vide ⇒ `.empty` (jamais 0 implicite) ; débordement ⇒ `.invalid`.
    public static func parseScore(_ text: String) -> ParsedScore {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let normalized = String(trimmed.map { $0 == "\u{2212}" ? "-" : $0 })
        guard let value = Int(normalized) else { return .invalid }
        return .value(value)
    }
}
