#if DEBUG
import Foundation
import TableScoreKit

/// Jeux de données déterministes pour les tests UI et les previews (**builds Debug uniquement**).
///
/// Lancement : `-uiTesting -seed <nom>`. Garde-fous : le jeu n'est appliqué que si le build est
/// Debug, si `-uiTesting` est présent **et** si `PersistenceController.storage(for:)` choisit
/// la mémoire : jamais d'écriture sur disque. Prénoms factices ; identifiants fixes.
///
/// Les données passent par l'API publique du dépôt (`createGame` / `appendRound`) : le moteur
/// valide et calcule tout. Les valeurs attendues ci-dessous sont documentées pour les tests,
/// elles ne sont pas utilisées comme calcul.
enum UITestSeed: String, CaseIterable, Sendable {
    /// 8 joueurs, partie active, 2 manches ; totaux 15, 16, −7, 55, −7, 17, 9, 71
    /// (co-leaders Chloé et Élodie à −7 ; nom long « Marie-Charlotte »).
    case eightPlayers
    /// 3 joueurs, partie active, 3 manches ; totaux Alice 88, Bob 60, Chloé 23
    /// (une manche où Alice marque ≥ 12 termine la partie).
    case nearEnd
    /// 3 joueurs, partie **terminée selon le moteur** (statut de cycle de vie encore `active`)
    /// après 3 manches ; totaux Alice 105, Bob 26, Chloé 26 : co-vainqueurs Bob et Chloé.
    case tieEnd
    /// Partie active de 4 joueurs avec 4 manches (doublée par égalité, doublée « a fait moins »,
    /// zéro, négatif ; totaux Alice 41, Bob 60, Chloé 34, Dimitri 53) + une partie terminée
    /// (Bob gagne, 2 manches) + une partie interrompue (archivée, 1 manche).
    case withHistory
    /// Lot 3 : 3 joueurs, partie active, 1 manche où Alice est saisie **en cartes** — colonnes
    /// 7/7/7 (non comptée), 1/2/3, colonne retirée, −2/−2/−2 (non comptée) ⇒ 6 ; Bob 10
    /// (clôturant, doublé à 20 : Alice et Chloé ont fait moins), Chloé 4. Totaux 6, 20, 4.
    case withCards

    static let launchArgument = "-seed"

    /// Partie ouverte après application du jeu (partie `active` du dépôt).
    var activeGameID: UUID {
        switch self {
        case .eightPlayers: GameKey.eightPlayers.id
        case .nearEnd: GameKey.nearEnd.id
        case .tieEnd: GameKey.tieEnd.id
        case .withHistory: GameKey.historyActive.id
        case .withCards: GameKey.cards.id
        }
    }

    /// Clés des parties créées par les jeux de données (identifiants fixes).
    enum GameKey: UInt8, CaseIterable, Sendable {
        case eightPlayers = 1
        case nearEnd
        case tieEnd
        case historyFinished
        case historyInterrupted
        case historyActive
        case cards

        var id: UUID { UITestSeed.fixtureID(kind: 0x01, key: rawValue, item: 0) }

        func participantID(position: Int) -> UUID {
            UITestSeed.fixtureID(kind: 0x02, key: rawValue, item: UInt8(clamping: position))
        }

        func roundID(index: Int) -> UUID {
            UITestSeed.fixtureID(kind: 0x03, key: rawValue, item: UInt8(clamping: index))
        }
    }

    // MARK: Lancement

    /// Jeu demandé par `-seed <nom>` ; `nil` si l'argument est absent.
    /// Lève une erreur si le nom est inconnu ou manquant (échec visible plutôt que silencieux).
    static func requested(in arguments: [String]) throws(GameRepositoryError) -> UITestSeed? {
        guard let flagIndex = arguments.firstIndex(of: launchArgument) else { return nil }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex),
              let seed = UITestSeed(rawValue: arguments[valueIndex]) else {
            throw GameRepositoryError.storageFailure(.setup, message: "Jeu de données de test inconnu.")
        }
        return seed
    }

    /// Applique le jeu demandé, uniquement sur un stockage en mémoire de test UI.
    @MainActor
    static func applyIfRequested(
        context: PersistenceController.LaunchContext,
        to repository: any GameRepository
    ) throws(GameRepositoryError) {
        guard context.isDebugBuild,
              context.arguments.contains(PersistenceController.uiTestingLaunchArgument),
              PersistenceController.storage(for: context) == .inMemory,
              let seed = try requested(in: context.arguments) else { return }
        try seed.apply(to: repository)
    }

    // MARK: Données

    @MainActor
    func apply(to repository: any GameRepository) throws(GameRepositoryError) {
        switch self {
        case .eightPlayers:
            try Self.insert(
                .eightPlayers,
                names: ["Alice", "Bastien", "Chloé", "Dimitri", "Élodie", "Farid", "Gaëlle", "Marie-Charlotte"],
                rounds: [
                    SeedRound(closer: 0, scores: [3, 12, -2, 25, 0, 18, 7, 31]),
                    SeedRound(closer: 2, scores: [9, 4, -5, 30, -7, -1, 2, 40]),
                ],
                into: repository
            )
        case .nearEnd:
            try Self.insert(
                .nearEnd,
                names: ["Alice", "Bob", "Chloé"],
                rounds: [
                    SeedRound(closer: 1, scores: [20, 5, 14]),
                    SeedRound(closer: 0, scores: [18, 30, 9]),
                    SeedRound(closer: 2, scores: [32, 25, 0]),
                ],
                into: repository
            )
        case .tieEnd:
            try Self.insert(
                .tieEnd,
                names: ["Alice", "Bob", "Chloé"],
                rounds: [
                    SeedRound(closer: 0, scores: [10, 24, 10]),
                    SeedRound(closer: 1, scores: [40, 3, 17]),
                    SeedRound(closer: 2, scores: [45, -1, -1]),
                ],
                into: repository
            )
        case .withHistory:
            // Ordre significatif : chaque création clôt la partie active précédente
            // (terminée ⇒ `finished`, sinon `archived` « interrompue »).
            try Self.insert(
                .historyFinished,
                names: ["Alice", "Bob"],
                rounds: [
                    SeedRound(closer: 1, scores: [60, 4]),
                    SeedRound(closer: 1, scores: [45, 8]),
                ],
                into: repository
            )
            try Self.insert(
                .historyInterrupted,
                names: ["Chloé", "Dimitri", "Élodie"],
                rounds: [SeedRound(closer: 0, scores: [2, 15, 9])],
                into: repository
            )
            try Self.insert(
                .historyActive,
                names: ["Alice", "Bob", "Chloé", "Dimitri"],
                rounds: [
                    SeedRound(closer: 0, scores: [10, 24, 10, 15]),
                    SeedRound(closer: 1, scores: [5, 12, 18, 30]),
                    SeedRound(closer: 2, scores: [7, -2, 0, 11]),
                    SeedRound(closer: 3, scores: [9, 14, 6, -3]),
                ],
                into: repository
            )
        case .withCards:
            let aliceGrid: CardGrid
            do {
                aliceGrid = try CardGrid(
                    rows: [[7, 1, nil, -2], [7, 2, nil, -2], [7, 3, nil, -2]],
                    removedColumns: [2]
                )
            } catch {
                throw GameRepositoryError.storageFailure(.setup, message: "Jeu de données de test incohérent.")
            }
            try Self.insert(
                .cards,
                names: ["Alice", "Bob", "Chloé"],
                rounds: [SeedRound(closer: 1, scores: [6, 10, 4], grids: [0: aliceGrid])],
                into: repository
            )
        }
    }

    /// Manche : position du clôturant + scores bruts dans l'ordre d'affichage ; `grids` : joueurs
    /// saisis en cartes (position → grille), dont le total doit valoir le score indiqué.
    private struct SeedRound {
        let closer: Int
        let scores: [Int]
        var grids: [Int: CardGrid] = [:]
    }

    @MainActor
    private static func insert(
        _ key: GameKey,
        names: [String],
        rounds: [SeedRound],
        into repository: any GameRepository
    ) throws(GameRepositoryError) {
        let participants = names.enumerated().map { position, name in
            Participant(id: key.participantID(position: position), displayName: name, displayOrder: position)
        }
        _ = try repository.createGame(id: key.id, participants: participants, rules: .classic)

        for (offset, round) in rounds.enumerated() {
            guard participants.indices.contains(round.closer), round.scores.count == participants.count else {
                throw GameRepositoryError.storageFailure(.setup, message: "Jeu de données de test incohérent.")
            }
            let index = RoundInput.firstIndex + offset
            var entries: [RoundEntry] = []
            for (position, participant) in participants.enumerated() {
                let score = round.scores[position]
                guard let grid = round.grids[position] else {
                    entries.append(.points(participant.id, rawScore: score))
                    continue
                }
                // Total calculé par le Kit ; il doit correspondre au score documenté.
                guard let entry = try? RoundEntry.cards(participant.id, grid: grid), entry.rawScore == score else {
                    throw GameRepositoryError.storageFailure(.setup, message: "Jeu de données de test incohérent.")
                }
                entries.append(entry)
            }
            let input = RoundInput(
                id: key.roundID(index: index),
                index: index,
                closingParticipantID: participants[round.closer].id,
                entries: entries
            )
            _ = try repository.appendRound(input, toGame: key.id)
        }
    }

    /// UUID déterministe, sans force-unwrap : `7E57xxxx-…` (« test »).
    fileprivate static func fixtureID(kind: UInt8, key: UInt8, item: UInt8) -> UUID {
        UUID(uuid: (0x7E, 0x57, kind, key, 0, item, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0))
    }
}
#endif
