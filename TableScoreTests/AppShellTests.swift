import Foundation
import Testing
import TableScoreKit
@testable import TableScore

/// Socle de l'interface (Lot 2, T0) : navigation, identifiants, fixtures de tests UI, formatage.
@Suite("Socle de l'interface")
@MainActor
struct AppShellTests {
    // MARK: Identifiants d'accessibilité (contrat des tests UI)

    @Test("Les identifiants d'accessibilité restent figés")
    func accessibilityIdentifiersArePinned() {
        #expect(AccessibilityID.Home.resume == "home.resume")
        #expect(AccessibilityID.Home.newGame == "home.newGame")
        #expect(AccessibilityID.Setup.player(number: 1) == "setup.player.1")
        #expect(AccessibilityID.Setup.addPlayer == "setup.addPlayer")
        #expect(AccessibilityID.Setup.start == "setup.start")
        #expect(AccessibilityID.Game.player(position: 0) == "game.player.0")
        #expect(AccessibilityID.Game.addRound == "game.addRound")
        #expect(AccessibilityID.Round.score(position: 2) == "round.score.2")
        #expect(AccessibilityID.Round.sign(position: 2) == "round.sign.2")
        #expect(AccessibilityID.Round.closer(position: 2) == "round.closer.2")
        #expect(AccessibilityID.Round.save == "round.save")
        #expect(AccessibilityID.GameOver.title == "gameOver.title")
        #expect(AccessibilityID.GameOver.replay == "gameOver.replay")
        #expect(AccessibilityID.History.round(index: 3) == "history.round.3")
        #expect(AccessibilityID.StorageError.retry == "storageError.retry")
    }

    // MARK: Navigation

    @Test("Ouvrir une partie ferme la feuille et remplace tout le chemin")
    func openGameReplacesPath() {
        let gameID = UUID()
        let router = AppRouter(path: [.finishedGames, .rules], sheet: .newGame)
        router.openGame(gameID)
        #expect(router.path == [.game(gameID)])
        #expect(router.sheet == nil)
    }

    @Test("Retour à l'accueil et signal de rechargement")
    func popToRootAndRevision() {
        let router = AppRouter()
        router.show(.settings)
        router.present(.roundEntry(gameID: UUID(), mode: .new))
        router.popToRoot()
        #expect(router.path.isEmpty)
        #expect(router.sheet == nil)

        let before = router.dataRevision
        router.notifyDataChanged()
        #expect(router.dataRevision == before + 1)
    }

    // MARK: Formatage d'affichage

    @Test("Signe moins typographique, écart signé, lecture VoiceOver")
    func scoreFormatting() {
        #expect(ScoreFormat.display(-3) == "\u{2212}3")
        #expect(ScoreFormat.display(0) == "0")
        #expect(ScoreFormat.display(Int.min).hasPrefix("\u{2212}"))
        #expect(ScoreFormat.delta(12) == "+12")
        #expect(ScoreFormat.delta(0) == "0")
        #expect(ScoreFormat.delta(-2) == "\u{2212}2")
        #expect(ScoreFormat.spoken(-3) == "moins 3")
        #expect(ScoreFormat.spoken(7) == "7")
    }

    @Test("Écart au premier : « +12 pts » affiché, « 12 points de plus que le premier » lu")
    func gapTexts() {
        #expect(PlayerScoreRow.gapText(12) == "+12\u{00A0}pts")
        #expect(PlayerScoreRow.spokenGap(12) == "12 points de plus que le premier")
        #expect(PlayerScoreRow.spokenGap(1) == "1 point de plus que le premier")
    }

    @Test("Textes de dates : locale française forcée")
    func frenchLocale() {
        #expect(Theme.locale.identifier == "fr_FR")
    }

    #if DEBUG
    // MARK: Fixtures de tests UI

    private typealias Key = UITestSeed.GameKey

    private func seeded(_ seed: UITestSeed) throws -> InMemoryGameRepository {
        let repository = InMemoryGameRepository()
        try seed.apply(to: repository)
        return repository
    }

    private func totals(_ game: SavedGame, _ key: Key) -> [Int] {
        game.participants.indices.map { game.computation.totals[key.participantID(position: $0)] ?? .min }
    }

    @Test("eightPlayers : 8 joueurs, négatifs, co-leaders")
    func eightPlayersSeed() throws {
        let game = try #require(try seeded(.eightPlayers).activeGame())
        #expect(game.id == UITestSeed.eightPlayers.activeGameID)
        #expect(game.participants.count == 8)
        #expect(game.rounds.count == 2)
        #expect(totals(game, .eightPlayers) == [15, 16, -7, 55, -7, 17, 9, 71])
        #expect(game.computation.status == .inProgress)
        #expect(game.computation.standings.filter(\.isLeader).count == 2)
    }

    @Test("nearEnd : partie en cours proche du seuil")
    func nearEndSeed() throws {
        let game = try #require(try seeded(.nearEnd).activeGame())
        #expect(game.id == UITestSeed.nearEnd.activeGameID)
        #expect(totals(game, .nearEnd) == [88, 60, 23])
        #expect(game.computation.status == .inProgress)
    }

    @Test("tieEnd : partie terminée, co-vainqueurs")
    func tieEndSeed() throws {
        let game = try #require(try seeded(.tieEnd).activeGame())
        #expect(game.id == UITestSeed.tieEnd.activeGameID)
        #expect(totals(game, .tieEnd) == [105, 26, 26])
        let winners = [Key.tieEnd.participantID(position: 1), Key.tieEnd.participantID(position: 2)]
        #expect(game.computation.status == .finished(roundIndex: 3, winnerIDs: winners))
        #expect(game.lifecycle == .active)
    }

    @Test("withHistory : partie active + une terminée + une interrompue")
    func withHistorySeed() throws {
        let repository = try seeded(.withHistory)
        let active = try #require(try repository.activeGame())
        #expect(active.id == UITestSeed.withHistory.activeGameID)
        #expect(active.rounds.count == 4)
        #expect(totals(active, .historyActive) == [41, 60, 34, 53])
        #expect(active.computation.rounds[0].scoring.verdict.isDoubled)
        #expect(active.computation.rounds[1].scoring.verdict.isDoubled)

        let closed = try repository.closedGames()
        #expect(closed.count == 2)
        let finished = try repository.game(id: Key.historyFinished.id)
        #expect(finished.lifecycle == .finished)
        let interrupted = try repository.game(id: Key.historyInterrupted.id)
        #expect(interrupted.isInterrupted)
    }

    @Test("Argument -seed : absent, connu, inconnu")
    func seedArgumentParsing() throws {
        #expect(try UITestSeed.requested(in: ["TableScore", "-uiTesting"]) == nil)
        #expect(try UITestSeed.requested(in: ["TableScore", "-seed", "nearEnd"]) == .nearEnd)
        #expect(throws: GameRepositoryError.self) { try UITestSeed.requested(in: ["TableScore", "-seed", "inconnu"]) }
        #expect(throws: GameRepositoryError.self) { try UITestSeed.requested(in: ["TableScore", "-seed"]) }
    }

    @Test("Le jeu n'est appliqué qu'en Debug, avec -uiTesting, en mémoire")
    func seedGuards() throws {
        let arguments = ["TableScore", "-seed", "nearEnd"]
        let withoutUITesting = PersistenceController.LaunchContext(
            arguments: arguments, environment: [:], isDebugBuild: true
        )
        let release = PersistenceController.LaunchContext(
            arguments: arguments + ["-uiTesting"], environment: [:], isDebugBuild: false
        )
        for context in [withoutUITesting, release] {
            let repository = InMemoryGameRepository()
            try UITestSeed.applyIfRequested(context: context, to: repository)
            #expect(try repository.activeGame() == nil)
        }
    }

    @Test("Lancement avec -uiTesting -seed : dépôt SwiftData en mémoire prêt et rempli")
    func bootstrapAppliesSeedInMemory() throws {
        let context = PersistenceController.LaunchContext(
            arguments: ["TableScore", "-uiTesting", "-seed", "withHistory"],
            environment: [:],
            isDebugBuild: true
        )
        #expect(PersistenceController.storage(for: context) == .inMemory)
        let bootstrap = AppBootstrap(context: context)
        guard case .ready(let dependencies) = bootstrap.state else {
            Issue.record("Le lancement aurait dû réussir.")
            return
        }
        let active = try #require(try dependencies.repository.activeGame())
        #expect(active.id == UITestSeed.withHistory.activeGameID)
        #expect(try dependencies.repository.closedGames().count == 2)
    }

    @Test("Jeu inconnu : écran d'erreur lisible, pas de crash")
    func bootstrapUnknownSeedFails() {
        let context = PersistenceController.LaunchContext(
            arguments: ["TableScore", "-uiTesting", "-seed", "inconnu"],
            environment: [:],
            isDebugBuild: true
        )
        let bootstrap = AppBootstrap(context: context)
        guard case .failed(let message) = bootstrap.state else {
            Issue.record("Le lancement aurait dû échouer.")
            return
        }
        #expect(!message.isEmpty)
    }
    #endif
}
