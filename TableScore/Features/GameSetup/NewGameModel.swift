import Foundation
import Observation
import TableScoreKit

/// Brouillon de la création de partie : saisie des prénoms et des règles maison.
///
/// Aucune règle de score ici : la validation des participants et des règles est celle du Kit
/// (`ScoreEngine.validate`), répliquée seulement pour fournir des messages par ligne. Le modèle ne
/// garde que des chaînes de saisie et des états de présentation.
@Observable
@MainActor
final class NewGameModel {
    /// Ligne de saisie. L'identifiant est stable : il devient `Participant.id` à la création,
    /// quels que soient les réordonnancements.
    struct PlayerDraft: Identifiable, Hashable, Sendable {
        let id: UUID
        var name: String

        init(id: UUID = UUID(), name: String = "") {
            self.id = id
            self.name = name
        }
    }

    /// Problème de saisie d'un prénom (une ligne vide ou invisible n'est pas un problème : ignorée).
    enum NameIssue: Hashable, Sendable {
        case tooLong
        case invalidCharacters
        /// Prénom (nettoyé) partagé avec au moins un autre joueur.
        case duplicate(name: String)

        var message: String {
            switch self {
            case .tooLong:
                "\(Participant.maxDisplayNameLength) caractères maximum."
            case .invalidCharacters:
                "Ce prénom contient un caractère non autorisé."
            case .duplicate(let name):
                "Deux joueurs s'appellent «\u{00A0}\(name)\u{00A0}»\u{00A0}: ajoutez une initiale."
            }
        }
    }

    static let playerRange = Participant.allowedCount
    static let targetScoreRange = 50...500
    static let targetScoreStep = 10
    private static let maxSuggestions = 8

    var players: [PlayerDraft]
    var targetScore = GameRules.officialTargetScore
    var isCloserPenaltyDisabled = false
    var houseRulesExpanded = false
    /// Prénoms issus des parties du dépôt, du plus récent au plus ancien (aucun stockage dédié).
    private(set) var recentNames: [String] = []
    /// Identifiant de la partie créée (renseigné après succès).
    private(set) var createdGameID: UUID?

    private let repository: any GameRepository
    /// Identifiant de brouillon réutilisé à chaque tentative : `createGame` est idempotent.
    private let draftGameID = UUID()

    init(repository: any GameRepository) {
        self.repository = repository
        self.players = [PlayerDraft(), PlayerDraft()]
    }

    // MARK: Joueurs

    var canAddPlayer: Bool { players.count < Self.playerRange.upperBound }
    var canRemovePlayer: Bool { players.count > Self.playerRange.lowerBound }

    /// Ajoute une ligne vide (sans effet à 8 joueurs) et renvoie son identifiant.
    @discardableResult
    func addPlayer() -> UUID? {
        guard canAddPlayer else { return nil }
        let draft = PlayerDraft()
        players.append(draft)
        return draft.id
    }

    /// Supprime les lignes données (sans effet si moins de deux joueurs resteraient).
    /// Implémentation pure (sans SwiftUI) : indices hors limites ignorés.
    func remove(atOffsets offsets: IndexSet) {
        var remaining = players
        for index in offsets.reversed() where remaining.indices.contains(index) {
            remaining.remove(at: index)
        }
        guard remaining.count >= Self.playerRange.lowerBound else { return }
        players = remaining
    }

    /// Déplace des lignes (même sémantique que `move(fromOffsets:toOffset:)` de SwiftUI :
    /// `destination` est un indice d'insertion dans le tableau d'origine).
    func move(from source: IndexSet, to destination: Int) {
        let valid = source.filter { players.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let target = min(max(destination, 0), players.count)
        let moving = valid.map { players[$0] }
        var result = players
        for index in valid.reversed() { result.remove(at: index) }
        let insertionIndex = target - valid.filter { $0 < target }.count
        for (offset, player) in moving.enumerated() {
            result.insert(player, at: insertionIndex + offset)
        }
        players = result
    }

    /// Rang 1-based affiché (« Prénom du joueur 1 »).
    func number(of id: UUID) -> Int {
        (players.firstIndex { $0.id == id } ?? 0) + 1
    }

    func isLast(_ id: UUID) -> Bool { players.last?.id == id }

    func isBlank(_ id: UUID) -> Bool {
        guard let player = players.first(where: { $0.id == id }) else { return true }
        return Self.isBlank(player.name)
    }

    /// Validation « Entrée » : renvoie la ligne à focaliser ensuite (nil = fermer le clavier).
    func submit(from id: UUID) -> UUID? {
        guard let index = players.firstIndex(where: { $0.id == id }) else { return nil }
        if index + 1 < players.count { return players[index + 1].id }
        guard !Self.isBlank(players[index].name) else { return nil }
        return addPlayer()
    }

    /// Le dernier champ ferme le clavier s'il n'y a rien à enchaîner.
    func shouldFinishOnSubmit(_ id: UUID) -> Bool {
        isLast(id) && (!canAddPlayer || isBlank(id))
    }

    // MARK: Validation de la saisie

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Vide, espaces seuls ou caractères invisibles seuls : ligne ignorée (comme le Kit).
    static func isBlank(_ text: String) -> Bool {
        !Participant.hasVisibleContent(trimmed(text))
    }

    /// Clé de comparaison insensible à la casse, aux diacritiques et à la largeur.
    static func comparisonKey(_ text: String) -> String {
        trimmed(text).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private var filledPlayers: [PlayerDraft] {
        players.filter { !Self.isBlank($0.name) }
    }

    /// Problème par ligne (au plus un par joueur).
    var issues: [UUID: NameIssue] {
        var result: [UUID: NameIssue] = [:]
        var idsByKey: [String: [UUID]] = [:]
        for player in filledPlayers {
            let name = Self.trimmed(player.name)
            if name.count > Participant.maxDisplayNameLength
                || name.utf8.count > Participant.maxDisplayNameByteCount {
                result[player.id] = .tooLong
            } else if Participant.containsDisallowedCharacters(name) {
                result[player.id] = .invalidCharacters
            } else {
                idsByKey[Self.comparisonKey(name), default: []].append(player.id)
            }
        }
        for ids in idsByKey.values where ids.count > 1 {
            for id in ids {
                if let player = players.first(where: { $0.id == id }) {
                    result[id] = .duplicate(name: Self.trimmed(player.name))
                }
            }
        }
        return result
    }

    /// Raison lisible pour laquelle « Commencer » est indisponible (nil si la saisie est valide).
    var startBlockReason: String? {
        if !issues.isEmpty { return "Corrigez les prénoms signalés." }
        if filledPlayers.count < Self.playerRange.lowerBound { return "Saisissez au moins deux prénoms." }
        return nil
    }

    var canStart: Bool { createdGameID == nil && startBlockReason == nil }

    /// Vrai si l'utilisateur a saisi quelque chose (confirmation avant « Annuler »).
    var hasUserInput: Bool {
        players.contains { !$0.name.isEmpty }
            || targetScore != GameRules.officialTargetScore
            || isCloserPenaltyDisabled
    }

    // MARK: Règles

    /// Réglage affiché « Doubler le score du clôturant » (activé = règle officielle).
    /// Désactivé ⇒ `HouseRules.isCloserPenaltyDisabled`.
    var doublesCloserScore: Bool {
        get { !isCloserPenaltyDisabled }
        set { isCloserPenaltyDisabled = !newValue }
    }

    var rules: GameRules {
        GameRules(
            targetScore: targetScore,
            houseRules: isCloserPenaltyDisabled ? HouseRules(isCloserPenaltyDisabled: true) : nil
        )
    }

    var rulesSummary: String {
        var summary = "Skyjo classique · \(targetScore) points"
        if isCloserPenaltyDisabled { summary += " · sans doublement du clôturant" }
        return summary
    }

    // MARK: Suggestions

    /// Prénoms récents non encore utilisés dans la saisie.
    var suggestions: [String] {
        let used = Set(filledPlayers.map { Self.comparisonKey($0.name) })
        return recentNames.filter { !used.contains(Self.comparisonKey($0)) }
    }

    var canApplySuggestion: Bool {
        canAddPlayer || players.contains { Self.isBlank($0.name) }
    }

    /// Charge les prénoms récents depuis le dépôt (lecture seule ; une erreur n'empêche rien).
    func loadSuggestions() {
        var games: [SavedGame] = []
        if let active = try? repository.activeGame() { games.append(active) }
        if let closed = try? repository.closedGames() {
            for case .readable(let game) in closed { games.append(game) }
        }
        games.sort { $0.updatedAt > $1.updatedAt }

        var seen = Set<String>()
        var names: [String] = []
        for game in games {
            for participant in game.participants {
                let name = participant.trimmedDisplayName
                guard seen.insert(Self.comparisonKey(name)).inserted else { continue }
                names.append(name)
            }
        }
        recentNames = Array(names.prefix(Self.maxSuggestions))
    }

    /// Remplit la première ligne vide (en ajoute une si besoin) et renvoie la ligne remplie.
    @discardableResult
    func applySuggestion(_ name: String) -> UUID? {
        if let index = players.firstIndex(where: { Self.isBlank($0.name) }) {
            players[index].name = name
            return players[index].id
        }
        guard let id = addPlayer(), let index = players.firstIndex(where: { $0.id == id }) else { return nil }
        players[index].name = name
        return id
    }

    // MARK: Création

    /// Crée la partie. Idempotent : le même brouillon réutilise toujours le même identifiant.
    func start() throws(GameRepositoryError) -> UUID {
        let filled = filledPlayers
        let participants = filled.enumerated().map { offset, player in
            Participant(id: player.id, displayName: Self.trimmed(player.name), displayOrder: offset)
        }
        let rules = self.rules
        do {
            try ScoreEngine.validate(participants: participants)
            try ScoreEngine.validate(rules: rules)
        } catch {
            throw GameRepositoryError.from(error, operation: .write)
        }
        // Le Kit n'interdit pas les homonymes : refus propre à l'écran, avec le message de la ligne.
        for (id, issue) in issues {
            if case .duplicate = issue {
                throw GameRepositoryError.validation(.duplicateParticipantID(id))
            }
        }
        let game = try repository.createGame(
            id: draftGameID,
            participants: participants,
            rules: rules,
            title: nil
        )
        createdGameID = game.id
        return game.id
    }
}
