import Foundation

/// Saisie en cours pour un participant. Les données « points » et « cartes » sont conservées
/// toutes les deux : basculer de mode ne perd rien.
///
/// Bascule cartes → points : si la grille est complète, le champ points est pré-rempli avec son
/// total, uniquement s'il est vide ou s'il provenait déjà de la grille (une saisie manuelle n'est
/// jamais écrasée). La règle s'applique quel que soit le chemin de modification de `inputMethod`.
public struct DraftEntry: Codable, Sendable, Hashable {
    public var inputMethod: InputMethod {
        didSet {
            if oldValue == .cards && inputMethod == .points { prefillPointsFromGrid() }
        }
    }
    /// Score saisi en mode points ; `nil` = vide (distinct de 0). Toute affectation externe est
    /// considérée comme une saisie manuelle.
    public var points: Int? {
        didSet { isPointsDerivedFromGrid = false }
    }
    public var cardGrid: CardGrid
    /// Vrai si `points` a été pré-rempli depuis la grille plutôt que saisi à la main.
    public private(set) var isPointsDerivedFromGrid: Bool

    public init(inputMethod: InputMethod = .points, points: Int? = nil, cardGrid: CardGrid = CardGrid()) {
        self.inputMethod = inputMethod
        self.points = points
        self.cardGrid = cardGrid
        self.isPointsDerivedFromGrid = false
    }

    /// Entrée « cartes » existante (correction) : le score points correspond au total de la grille,
    /// comme après une bascule depuis un brouillon neuf.
    init(cardsGrid grid: CardGrid, rawScore: Int) {
        self.inputMethod = .cards
        self.points = rawScore
        self.cardGrid = grid
        self.isPointsDerivedFromGrid = true
    }

    /// Score brut selon le mode actif ; `nil` si incomplet.
    public var rawScore: Int? {
        switch inputMethod {
        case .points: points
        case .cards: cardGrid.evaluate().rawScore
        }
    }

    private mutating func prefillPointsFromGrid() {
        guard let total = cardGrid.evaluate().rawScore,
              points == nil || isPointsDerivedFromGrid
        else { return }
        points = total // réinitialise l'indicateur via didSet…
        isPointsDerivedFromGrid = true // …qui est donc rétabli ensuite.
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
                entries[entry.participantID] = DraftEntry(cardsGrid: grid, rawScore: entry.rawScore)
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

    /// Change le mode de saisie (voir `DraftEntry` pour la règle de pré-remplissage) ;
    /// renvoie `false` si le participant est étranger au brouillon.
    @discardableResult
    public mutating func setInputMethod(_ inputMethod: InputMethod, for participantID: UUID) -> Bool {
        updateEntry(for: participantID) { $0.inputMethod = inputMethod }
    }

    /// Renseigne (ou efface avec `nil`) une carte de la grille d'un participant.
    public mutating func setCard(_ value: Int?, column: Int, row: Int, for participantID: UUID) throws(ValidationError) {
        guard var entry = entries[participantID] else {
            throw ValidationError.unknownParticipant(participantID)
        }
        try entry.cardGrid.setCard(value, column: column, row: row)
        entries[participantID] = entry
    }

    /// Marque (ou démarque) une colonne retirée dans la grille d'un participant.
    public mutating func setColumnRemoved(_ isRemoved: Bool, column: Int, for participantID: UUID) throws(ValidationError) {
        guard var entry = entries[participantID] else {
            throw ValidationError.unknownParticipant(participantID)
        }
        try entry.cardGrid.setColumnRemoved(isRemoved, column: column)
        entries[participantID] = entry
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

    /// Signes acceptés en tête : « - », « − » (U+2212), « – » (U+2013), « － » (U+FF0D), « + ».
    private static let signs: [Character: Bool] = [
        "-": true, "\u{2212}": true, "\u{2013}": true, "\u{FF0D}": true, "+": false,
    ]

    /// Analyse un texte de score signé.
    ///
    /// Espaces (y compris insécables) ignorés en début et fin, autorisés entre le signe et les
    /// chiffres (« − 5 » = −5), refusés entre chiffres (« 1 2 »). Chiffres ASCII uniquement.
    /// Vide ⇒ `.empty` (jamais 0 implicite) ; dépassement d'`Int` ⇒ `.invalid`.
    public static func parseScore(_ text: String) -> ParsedScore {
        var remainder = Substring(text).drop { $0.isWhitespace }
        while let last = remainder.last, last.isWhitespace { remainder = remainder.dropLast() }
        guard let first = remainder.first else { return .empty }

        var isNegative = false
        if let negative = signs[first] {
            isNegative = negative
            remainder = remainder.dropFirst().drop { $0.isWhitespace }
        }
        guard !remainder.isEmpty, remainder.allSatisfy({ $0.isASCII && $0.isNumber }) else { return .invalid }
        guard let value = Int((isNegative ? "-" : "") + String(remainder)) else { return .invalid }
        return .value(value)
    }
}
