import Foundation
import Testing
import TableScoreKit
@testable import TableScore

@Suite("Création de partie")
@MainActor
struct NewGameModelTests {
    private func makeModel(
        names: [String],
        repository: InMemoryGameRepository = InMemoryGameRepository()
    ) -> (NewGameModel, InMemoryGameRepository) {
        let model = NewGameModel(repository: repository)
        while model.players.count < names.count { model.addPlayer() }
        for (index, name) in names.enumerated() {
            model.players[index].name = name
        }
        return (model, repository)
    }

    // MARK: Nombre de joueurs

    @Test("Deux joueurs au départ, partie valide à 2")
    func twoPlayersAreValid() throws {
        let (model, repository) = makeModel(names: ["Alice", "Bob"])
        #expect(model.players.count == 2)
        #expect(model.canStart)
        #expect(model.startBlockReason == nil)
        let id = try model.start()
        #expect(try repository.game(id: id).participants.count == 2)
    }

    @Test("Huit joueurs valides, le neuvième ne peut pas être ajouté")
    func eightPlayersMax() throws {
        let names = (1...8).map { "Joueur \($0)" }
        let (model, repository) = makeModel(names: names)
        #expect(model.canStart)
        #expect(!model.canAddPlayer)
        #expect(model.addPlayer() == nil)
        #expect(model.players.count == 8)
        let id = try model.start()
        #expect(try repository.game(id: id).participants.count == 8)
    }

    @Test("Un seul prénom : impossible de commencer")
    func onePlayerIsRejected() throws {
        let (model, repository) = makeModel(names: ["Alice", "  "])
        #expect(!model.canStart)
        #expect(model.startBlockReason != nil)
        #expect(throws: GameRepositoryError.self) { try model.start() }
        #expect(try repository.activeGame() == nil)
    }

    @Test("Neuf joueurs forcés : refus du moteur, rien n'est écrit")
    func nineForcedPlayersAreRejected() throws {
        let (model, repository) = makeModel(names: (1...8).map { "J\($0)" })
        model.players.append(.init(name: "J9"))
        #expect(throws: GameRepositoryError.self) { try model.start() }
        #expect(try repository.activeGame() == nil)
    }

    @Test("On ne descend pas sous deux lignes")
    func cannotRemoveBelowTwo() {
        let (model, _) = makeModel(names: ["A", "B", "C"])
        model.remove(atOffsets: IndexSet(integer: 0))
        #expect(model.players.count == 2)
        model.remove(atOffsets: IndexSet(integer: 0))
        #expect(model.players.count == 2)
    }

    // MARK: Noms

    @Test("Les prénoms sont nettoyés et les lignes vides ignorées")
    func trimAndIgnoreBlankRows() throws {
        let (model, repository) = makeModel(names: ["  Alice  ", "", "\u{200B}", " Bob\n"])
        let id = try model.start()
        let participants = try repository.game(id: id).participants
        #expect(participants.map(\.displayName) == ["Alice", "Bob"])
        #expect(participants.map(\.displayOrder) == [0, 1])
    }

    @Test("Prénom trop long ou avec caractère interdit : signalé et bloquant")
    func invalidNames() {
        let tooLong = String(repeating: "a", count: Participant.maxDisplayNameLength + 1)
        let (model, _) = makeModel(names: [tooLong, "Bob\u{0007}"])
        #expect(model.issues[model.players[0].id] == .tooLong)
        #expect(model.issues[model.players[1].id] == .invalidCharacters)
        #expect(!model.canStart)
        #expect(throws: GameRepositoryError.self) { try model.start() }
    }

    @Test("Prénom de 24 caractères accepté")
    func maxLengthIsAccepted() {
        let name = String(repeating: "é", count: Participant.maxDisplayNameLength)
        let (model, _) = makeModel(names: [name, "Bob"])
        #expect(model.issues.isEmpty)
        #expect(model.canStart)
    }

    @Test("Prénom invisible = ligne vide")
    func invisibleNameIsBlank() {
        let (model, _) = makeModel(names: ["\u{200B}\u{2060}", "Bob"])
        #expect(model.issues.isEmpty)
        #expect(!model.canStart)
        #expect(model.startBlockReason == "Saisissez au moins deux prénoms.")
    }

    @Test("Doublons ambigus bloqués (casse, diacritiques, espaces)")
    func duplicatesAreBlocked() {
        let (model, _) = makeModel(names: ["Éloïse", " eloise ", "Bob"])
        #expect(model.issues[model.players[0].id] != nil)
        #expect(model.issues[model.players[1].id] != nil)
        #expect(model.issues[model.players[2].id] == nil)
        #expect(!model.canStart)
        #expect(throws: GameRepositoryError.self) { try model.start() }
    }

    @Test("Des prénoms distincts ne sont pas des doublons")
    func distinctNamesAreFine() {
        let (model, _) = makeModel(names: ["Alex", "Alexa"])
        #expect(model.issues.isEmpty)
    }

    // MARK: Ordre

    @Test("Le réordonnancement conserve les identifiants et fixe displayOrder")
    func moveKeepsIdentifiers() throws {
        let (model, repository) = makeModel(names: ["Alice", "Bob", "Chloé"])
        let ids = Dictionary(uniqueKeysWithValues: model.players.map { ($0.name, $0.id) })
        model.move(from: IndexSet(integer: 2), to: 0)
        #expect(model.players.map(\.name) == ["Chloé", "Alice", "Bob"])
        let gameID = try model.start()
        let participants = try repository.game(id: gameID).participants
        #expect(participants.map(\.displayName) == ["Chloé", "Alice", "Bob"])
        #expect(participants.map(\.displayOrder) == [0, 1, 2])
        for participant in participants {
            #expect(participant.id == ids[participant.displayName])
        }
    }

    // MARK: Règles

    @Test("Règles par défaut : classique, 100 points, sans règle maison")
    func defaultRules() {
        let model = NewGameModel(repository: InMemoryGameRepository())
        #expect(model.rules == GameRules.classic)
        #expect(model.rulesSummary == "Skyjo classique · 100 points")
        #expect(!model.hasUserInput)
    }

    @Test("Règles maison transmises à la partie")
    func houseRulesAreStored() throws {
        let (model, repository) = makeModel(names: ["Alice", "Bob"])
        model.targetScore = 150
        model.isCloserPenaltyDisabled = true
        let id = try model.start()
        let rules = try repository.game(id: id).rules
        #expect(rules.targetScore == 150)
        #expect(rules.houseRules?.isCloserPenaltyDisabled == true)
        #expect(!rules.isCloserPenaltyActive)
    }

    // MARK: Double start

    @Test("Double start : même identifiant, une seule partie")
    func doubleStartIsIdempotent() throws {
        let (model, repository) = makeModel(names: ["Alice", "Bob"])
        let first = try model.start()
        let second = try model.start()
        #expect(first == second)
        #expect(model.createdGameID == first)
        #expect(!model.canStart)
        #expect(try repository.activeGame()?.id == first)
        #expect(try repository.closedGames().isEmpty)
    }

    // MARK: Suggestions

    @Test("Suggestions dérivées des parties du dépôt, sans doublon ni noms déjà saisis")
    func suggestionsFromRepository() throws {
        let repository = InMemoryGameRepository()
        _ = try repository.createGame(
            id: UUID(),
            participants: [
                Participant(displayName: "Alice", displayOrder: 0),
                Participant(displayName: "Bob", displayOrder: 1),
            ],
            rules: .classic
        )
        let model = NewGameModel(repository: repository)
        model.loadSuggestions()
        #expect(Set(model.suggestions) == ["Alice", "Bob"])
        model.applySuggestion("alice")
        #expect(model.players[0].name == "alice")
        #expect(model.suggestions == ["Bob"])
        model.applySuggestion("Bob")
        #expect(model.players[1].name == "Bob")
        #expect(model.suggestions.isEmpty)
    }
    // MARK: Réglage « Doubler le score du clôturant »

    @Test("Doubler le score du clôturant : activé par défaut ; désactivé ⇒ règle maison")
    func doublesCloserScoreToggle() {
        let model = NewGameModel(repository: InMemoryGameRepository())
        #expect(model.doublesCloserScore)
        #expect(model.rules == GameRules.classic)

        model.doublesCloserScore = false
        #expect(model.isCloserPenaltyDisabled)
        #expect(model.rules.houseRules?.isCloserPenaltyDisabled == true)
        #expect(model.rulesSummary.contains("sans doublement du clôturant"))
        #expect(model.hasUserInput)

        model.doublesCloserScore = true
        #expect(model.rules == GameRules.classic)
    }

    // MARK: Réordonnancement (sans SwiftUI)

    @Test("Déplacement : même sémantique que move(fromOffsets:toOffset:)")
    func movePlayers() {
        let (model, _) = makeModel(names: ["A", "B", "C", "D"])
        model.move(from: IndexSet(integer: 0), to: 3)
        #expect(model.players.map(\.name) == ["B", "C", "A", "D"])
        model.move(from: IndexSet(integer: 3), to: 0)
        #expect(model.players.map(\.name) == ["D", "B", "C", "A"])
        model.move(from: IndexSet([0, 1]), to: 4)
        #expect(model.players.map(\.name) == ["C", "A", "D", "B"])
        model.move(from: IndexSet(integer: 9), to: 0)
        #expect(model.players.map(\.name) == ["C", "A", "D", "B"], "Indice hors limites ignoré.")
    }

    @Test("Suppression : plusieurs lignes, jamais sous deux joueurs")
    func removePlayers() {
        let (model, _) = makeModel(names: ["A", "B", "C", "D"])
        model.remove(atOffsets: IndexSet([0, 2]))
        #expect(model.players.map(\.name) == ["B", "D"])
        model.remove(atOffsets: IndexSet(integer: 0))
        #expect(model.players.count == 2, "Deux joueurs minimum.")
    }
}
