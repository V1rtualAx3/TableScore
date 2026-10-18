// `InMemoryGameRepository` n'existe qu'en Debug.
#if DEBUG
import Foundation
import Testing
import TableScoreKit
@testable import TableScore

/// Saisie par cartes dans la feuille de manche (Lot 3, cahier §3.3, §10 n° 5–6) : bascules
/// « Points | Cartes » sans perte, validation bloquée tant qu'une carte manque, total de la grille
/// calculé par le Kit (triplets, colonnes retirées), correction d'une manche saisie en cartes.
@Suite("Saisie d'une manche par cartes")
@MainActor
struct CardEntryModelTests {
    // MARK: Données

    private static func uuid(_ n: UInt8) -> UUID {
        UUID(uuid: (0xCA, 0x4D, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n))
    }

    private static let gameID = uuid(0xA0)

    /// Partie active sans manche : Alice, Bob, Chloé.
    private static func makeModel() throws -> (RoundEntryModel, InMemoryGameRepository) {
        let repository = InMemoryGameRepository()
        let participants = ["Alice", "Bob", "Chloé"].enumerated().map { offset, name in
            Participant(id: uuid(UInt8(offset + 1)), displayName: name, displayOrder: offset)
        }
        _ = try repository.createGame(id: gameID, participants: participants, rules: .classic)
        return (RoundEntryModel(gameID: gameID, mode: .new, repository: repository), repository)
    }

    /// Grille à partir de 3 rangées (haut → bas) de 4 valeurs.
    private static func grid(_ rows: [[Int?]], removed: Set<Int> = []) throws -> CardGrid {
        try CardGrid(rows: rows, removedColumns: removed)
    }

    /// Colonnes −2/−2/−2 (triplet négatif), 1/2/3, 4/4/5, 0/0/1 ⇒ 0 + 6 + 13 + 1 = 20.
    private static func gridTotal20() throws -> CardGrid {
        try grid([[-2, 1, 4, 0], [-2, 2, 4, 0], [-2, 3, 5, 1]])
    }

    private static func id(_ model: RoundEntryModel, _ position: Int) -> UUID {
        model.fields[position].participantID
    }

    private static func previewLine(_ model: RoundEntryModel, _ position: Int) -> RoundEntryModel.PreviewLine? {
        model.preview?.lines.first { $0.position == position }
    }

    // MARK: Bascules

    @Test("Mode « Points » par défaut ; Points → Cartes conserve la saisie points")
    func pointsToCardsKeepsPoints() throws {
        let (model, _) = try Self.makeModel()
        #expect(model.fields.allSatisfy { $0.inputMethod == .points })
        let alice = Self.id(model, 0)
        model.setText("12", for: alice)
        model.setText("3", for: Self.id(model, 1))
        model.setText("5", for: Self.id(model, 2))
        model.selectCloser(Self.id(model, 1))
        #expect(model.canSave)

        #expect(model.setInputMethod(.cards, for: alice) == nil)
        #expect(model.fields[0].inputMethod == .cards)
        #expect(model.fields[0].text == "12")
        #expect(!model.canSave)
        #expect(model.blockingReasons == ["cartes d'Alice (12\u{00A0}cartes à saisir)"])
        #expect(model.blockingSummary == "À compléter\u{00A0}: cartes d'Alice.")
        #expect(model.isDirty)

        // Retour en points avec une grille jamais touchée : rien à signaler, score 12 intact.
        #expect(model.setInputMethod(.points, for: alice) == nil)
        #expect(model.fields[0].inputMethod == .points)
        #expect(model.fields[0].text == "12")
        #expect(model.fields[0].cardsNotice == nil)
        #expect(model.canSave)
        #expect(Self.previewLine(model, 0)?.roundScore == 12)
    }

    @Test("Cartes → Points : score pré-rempli avec le total d'une grille complète")
    func cardsToPointsPrefills() throws {
        let (model, repository) = try Self.makeModel()
        let alice = Self.id(model, 0)
        let grid = try Self.gridTotal20()
        model.setInputMethod(.cards, for: alice)
        model.setCardGrid(grid, for: alice)

        #expect(model.setInputMethod(.points, for: alice) == nil)
        #expect(model.fields[0].text == "20")
        #expect(model.fields[0].status == .value(20))
        #expect(model.fields[0].cardsNotice == nil)
        // La grille reste dans le brouillon : retour en cartes sans perte.
        #expect(model.cardGrid(for: alice) == grid)

        model.setText("7", for: Self.id(model, 1))
        model.setText("9", for: Self.id(model, 2))
        model.selectCloser(Self.id(model, 1))
        #expect(model.save() == .saved)
        let entry = try #require(try repository.game(id: Self.gameID).rounds.first?.entry(for: alice))
        // Enregistré en points : aucune grille, aucune colonne soustraite.
        #expect(entry.inputMethod == .points)
        #expect(entry.rawScore == 20)
        #expect(entry.cardGrid == nil)
    }

    @Test("Cartes → Points avec une grille incomplète : information claire, rien n'est effacé")
    func incompleteGridIsNotConvertible() throws {
        let (model, _) = try Self.makeModel()
        let alice = Self.id(model, 0)
        model.setInputMethod(.cards, for: alice)
        let partial = try Self.grid([[5, 6, nil, nil], [5, nil, nil, nil], [nil, nil, nil, nil]])
        model.setCardGrid(partial, for: alice)

        let notice = model.setInputMethod(.points, for: alice)
        #expect(notice == "La grille est incomplète\u{00A0}: saisissez le total à la main ou complétez les cartes.")
        #expect(model.fields[0].cardsNotice == notice)
        #expect(model.fields[0].text.isEmpty)
        #expect(model.blockingReasons.contains("score d'Alice"))
        #expect(model.cardGrid(for: alice) == partial)

        // Retour en cartes : la grille partielle est intacte, l'information disparaît.
        model.setInputMethod(.cards, for: alice)
        #expect(model.cardGrid(for: alice) == partial)
        #expect(model.fields[0].cardsNotice == nil)

        // Saisie du total à la main : l'information disparaît, la grille reste conservée.
        model.setInputMethod(.points, for: alice)
        model.setText("31", for: alice)
        #expect(model.fields[0].cardsNotice == nil)
        #expect(model.cardGrid(for: alice) == partial)
    }

    @Test("Score saisi à la main jamais écrasé par la grille : information si le total diffère")
    func manualPointsAreKept() throws {
        let (model, _) = try Self.makeModel()
        let alice = Self.id(model, 0)
        model.setText("18", for: alice)
        model.setInputMethod(.cards, for: alice)
        model.setCardGrid(try Self.gridTotal20(), for: alice)

        let notice = model.setInputMethod(.points, for: alice)
        #expect(model.fields[0].text == "18")
        #expect(notice == "Total des cartes\u{00A0}: 20. Le score saisi à la main (18) est conservé\u{00A0}: corrigez-le si besoin.")

        // Grille incomplète + score manuel : le score est conservé, l'information le dit.
        model.setInputMethod(.cards, for: alice)
        var grid = model.cardGrid(for: alice)
        try grid.setCard(nil, column: 1, row: 0)
        model.setCardGrid(grid, for: alice)
        let incompleteNotice = model.setInputMethod(.points, for: alice)
        #expect(model.fields[0].text == "18")
        #expect(incompleteNotice == "La grille est incomplète\u{00A0}: le score saisi à la main (18) est conservé. Vérifiez-le ou complétez les cartes.")
    }

    @Test("Score pré-rempli puis grille rendue incomplète : l'information dit que le score vient de la grille")
    func derivedPointsWithIncompleteGrid() throws {
        let (model, _) = try Self.makeModel()
        let alice = Self.id(model, 0)
        model.setInputMethod(.cards, for: alice)
        var grid = try Self.gridTotal20()
        model.setCardGrid(grid, for: alice)
        model.setInputMethod(.points, for: alice)
        #expect(model.fields[0].text == "20")

        model.setInputMethod(.cards, for: alice)
        try grid.setCard(nil, column: 2, row: 1)
        model.setCardGrid(grid, for: alice)
        let notice = model.setInputMethod(.points, for: alice)
        #expect(model.fields[0].text == "20")
        #expect(notice == "Le score affiché (20) provient de la grille avant modification. Vérifiez-le ou complétez les cartes.")
    }

    @Test("« Suivant » après le dernier champ : première grille incomplète, sinon aucune")
    func firstIncompleteGrid() throws {
        let (model, _) = try Self.makeModel()
        #expect(model.firstIncompleteGridParticipantID == nil)
        model.setInputMethod(.cards, for: Self.id(model, 2))
        model.setInputMethod(.cards, for: Self.id(model, 1))
        #expect(model.firstIncompleteGridParticipantID == Self.id(model, 1))
        model.setCardGrid(try Self.gridTotal20(), for: Self.id(model, 1))
        #expect(model.firstIncompleteGridParticipantID == Self.id(model, 2))
        model.setCardGrid(try Self.gridTotal20(), for: Self.id(model, 2))
        #expect(model.firstIncompleteGridParticipantID == nil)
    }

    // MARK: Validation et total (Kit)

    @Test("Manche non validable tant qu'une carte présente manque ; zéro est une vraie valeur")
    func validationBlockedUntilComplete() throws {
        let (model, repository) = try Self.makeModel()
        let alice = Self.id(model, 0)
        model.setInputMethod(.cards, for: alice)
        model.setText("7", for: Self.id(model, 1))
        model.setText("9", for: Self.id(model, 2))
        model.selectCloser(Self.id(model, 1))

        var grid = try Self.grid([[0, 1, 4, 0], [0, 2, 4, 0], [0, 3, 5, nil]])
        model.setCardGrid(grid, for: alice)
        #expect(!model.canSave)
        #expect(model.blockingReasons == ["cartes d'Alice (1\u{00A0}carte à saisir)"])
        #expect(model.preview == nil)
        #expect(model.save() == .ignored)
        #expect(try repository.game(id: Self.gameID).rounds.isEmpty)

        // Dernière carte : 0 (valeur réelle, distincte du vide).
        try grid.setCard(0, column: 3, row: 2)
        model.setCardGrid(grid, for: alice)
        #expect(model.canSave)
        // 0/0/0 et 0/0/0 : triplets non comptés ; 1/2/3 = 6 ; 4/4/5 = 13.
        #expect(Self.previewLine(model, 0)?.roundScore == 19)
    }

    @Test("Score brut = total de la grille : aperçu de pénalité et cumuls calculés par le moteur")
    func rawScoreIsGridTotal() throws {
        let (model, repository) = try Self.makeModel()
        let alice = Self.id(model, 0)
        let grid = try Self.gridTotal20()
        model.setInputMethod(.cards, for: alice)
        model.setCardGrid(grid, for: alice)
        model.setText("20", for: Self.id(model, 1))
        model.setText("25", for: Self.id(model, 2))
        model.selectCloser(alice)

        // Alice clôt à 20, Bob à 20 : égalité ⇒ doublé à 40 (verdict du moteur).
        let line = try #require(Self.previewLine(model, 0))
        #expect(line.isCloser)
        #expect(line.isDoubled)
        #expect(line.roundScore == 40)
        #expect(line.totalAfter == 40)
        #expect(line.closerDescription?.text == "Alice\u{00A0}: 20 → 40 (score doublé\u{00A0}: égalité avec Bob)")

        #expect(model.save() == .saved)
        let round = try #require(try repository.game(id: Self.gameID).rounds.first)
        let entry = try #require(round.entry(for: alice))
        #expect(entry.inputMethod == .cards)
        #expect(entry.rawScore == 20)
        #expect(entry.cardGrid == grid)
    }

    @Test("Triplet −2/−2/−2 : colonne non comptée (pas de −6)")
    func negativeTripletIsNotCounted() throws {
        let (model, _) = try Self.makeModel()
        let alice = Self.id(model, 0)
        model.setInputMethod(.cards, for: alice)
        let grid = try Self.gridTotal20()
        model.setCardGrid(grid, for: alice)
        #expect(grid.evaluate().columns[0] == .identicalCards(value: -2))
        model.setText("30", for: Self.id(model, 1))
        model.setText("30", for: Self.id(model, 2))
        model.selectCloser(Self.id(model, 1))
        #expect(Self.previewLine(model, 0)?.roundScore == 20)
    }

    @Test("Ligne horizontale identique : jamais retirée")
    func horizontalLineIsCounted() throws {
        let (model, _) = try Self.makeModel()
        let alice = Self.id(model, 0)
        model.setInputMethod(.cards, for: alice)
        // Rangée du haut 5/5/5/5 : comptée (aucune colonne identique) ⇒ 5×4 + 1×4 + 2×4 = 32.
        model.setCardGrid(try Self.grid([[5, 5, 5, 5], [1, 1, 1, 1], [2, 2, 2, 2]]), for: alice)
        model.setText("40", for: Self.id(model, 1))
        model.setText("40", for: Self.id(model, 2))
        model.selectCloser(Self.id(model, 1))
        #expect(Self.previewLine(model, 0)?.roundScore == 32)
    }

    @Test("Colonne retirée : 0 sans exiger ses valeurs, valeurs conservées, aucun double retrait")
    func removedColumnIsNotRemovedTwice() throws {
        let (model, _) = try Self.makeModel()
        let alice = Self.id(model, 0)
        model.setInputMethod(.cards, for: alice)
        model.setText("40", for: Self.id(model, 1))
        model.setText("40", for: Self.id(model, 2))
        model.selectCloser(Self.id(model, 1))

        // Colonne 0 retirée (aucune valeur), 7/7/7 (non comptée), 1/2/3, 4/5/6 ⇒ 6 + 15 = 21.
        var grid = try Self.grid([[nil, 7, 1, 4], [nil, 7, 2, 5], [nil, 7, 3, 6]], removed: [0])
        model.setCardGrid(grid, for: alice)
        #expect(model.canSave)
        #expect(Self.previewLine(model, 0)?.roundScore == 21)

        // Colonne 7/7/7 marquée retirée en plus : toujours 0, jamais −21.
        try grid.setColumnRemoved(true, column: 1)
        model.setCardGrid(grid, for: alice)
        #expect(Self.previewLine(model, 0)?.roundScore == 21)

        // Démarquer la colonne 1 : ses valeurs saisies sont toujours là (triplet ⇒ 0).
        try grid.setColumnRemoved(false, column: 1)
        model.setCardGrid(grid, for: alice)
        #expect(model.cardGrid(for: alice).columns[1].values == [7, 7, 7])
        #expect(Self.previewLine(model, 0)?.roundScore == 21)
    }

    @Test("Saisie points : jamais de soustraction de colonnes ; grille ignorée en mode Points")
    func pointsModeNeverSubtractsColumns() throws {
        let (model, repository) = try Self.makeModel()
        let alice = Self.id(model, 0)
        // Une grille n'est pas modifiable en mode Points.
        model.setCardGrid(try Self.gridTotal20(), for: alice)
        #expect(model.cardGrid(for: alice) == CardGrid())

        model.setText("21", for: alice)
        model.setText("4", for: Self.id(model, 1))
        model.setText("9", for: Self.id(model, 2))
        model.selectCloser(Self.id(model, 1))
        #expect(Self.previewLine(model, 0)?.roundScore == 21)
        #expect(model.save() == .saved)
        let entry = try #require(try repository.game(id: Self.gameID).rounds.first?.entry(for: alice))
        #expect(entry.rawScore == 21)
        #expect(entry.inputMethod == .points)
    }

    @Test("Saisie modifiée : bascule de mode et grille comptent pour la confirmation d'abandon")
    func dirtyTrackingIncludesCards() throws {
        let (model, _) = try Self.makeModel()
        let alice = Self.id(model, 0)
        #expect(!model.isDirty)
        model.setInputMethod(.cards, for: alice)
        #expect(model.isDirty)
        model.setInputMethod(.points, for: alice)
        #expect(!model.isDirty)

        model.setInputMethod(.cards, for: alice)
        var grid = CardGrid()
        try grid.setCard(3, column: 0, row: 0)
        model.setCardGrid(grid, for: alice)
        model.setInputMethod(.points, for: alice)
        // Grille partielle conservée dans le brouillon : la saisie reste « modifiée ».
        #expect(model.isDirty)
    }

    @Test("Résumé : au-delà de deux saisies manquantes, un décompte")
    func blockingSummaryCountsCardsAndScores() throws {
        let (model, _) = try Self.makeModel()
        model.setInputMethod(.cards, for: Self.id(model, 0))
        model.setInputMethod(.cards, for: Self.id(model, 2))
        #expect(model.blockingReasons == [
            "cartes d'Alice (12\u{00A0}cartes à saisir)",
            "score de Bob",
            "cartes de Chloé (12\u{00A0}cartes à saisir)",
            "qui a terminé la manche",
        ])
        #expect(model.blockingSummary == "À compléter\u{00A0}: 3 scores, qui a terminé la manche.")
    }

    // MARK: Correction d'une manche saisie en cartes

    @Test("Correction : grille rechargée en mode Cartes, modifiable, recalcul et enregistrement")
    func correctionReloadsGrid() throws {
        let repository = InMemoryGameRepository()
        try UITestSeed.withCards.apply(to: repository)
        let key = UITestSeed.GameKey.cards
        let model = RoundEntryModel(gameID: key.id, mode: .edit(roundID: key.roundID(index: 1)), repository: repository)
        let alice = key.participantID(position: 0)

        let original = try CardGrid(rows: [[7, 1, nil, -2], [7, 2, nil, -2], [7, 3, nil, -2]], removedColumns: [2])
        #expect(model.fields.map(\.inputMethod) == [.cards, .points, .points])
        #expect(model.cardGrid(for: alice) == original)
        #expect(!model.isDirty)
        #expect(model.canSave)
        #expect(Self.previewLine(model, 0)?.roundScore == 6)

        // 1/2/3 → 4/2/3 : total 9 ; Bob (10) reste doublé (Alice 9 et Chloé 4 font moins).
        var grid = model.cardGrid(for: alice)
        try grid.setCard(4, column: 1, row: 0)
        model.setCardGrid(grid, for: alice)
        #expect(model.isDirty)
        #expect(Self.previewLine(model, 0)?.roundScore == 9)
        #expect(Self.previewLine(model, 1)?.roundScore == 20)

        #expect(model.save() == .saved)
        let saved = try repository.game(id: key.id)
        let entry = try #require(saved.rounds.first?.entry(for: alice))
        #expect(entry.inputMethod == .cards)
        #expect(entry.cardGrid == grid)
        #expect(entry.rawScore == 9)
        #expect(saved.computation.totals[alice] == 9)
    }

    @Test("Correction identique d'une manche en cartes : succès sans écriture")
    func identicalCardCorrectionWritesNothing() throws {
        let repository = InMemoryGameRepository()
        try UITestSeed.withCards.apply(to: repository)
        let key = UITestSeed.GameKey.cards
        let model = RoundEntryModel(gameID: key.id, mode: .edit(roundID: key.roundID(index: 1)), repository: repository)
        #expect(model.save() == .saved)
        #expect(!model.hasWrittenData)
    }

    @Test("Correction : une manche en cartes peut repasser en points (total pré-rempli)")
    func correctionCardsToPoints() throws {
        let repository = InMemoryGameRepository()
        try UITestSeed.withCards.apply(to: repository)
        let key = UITestSeed.GameKey.cards
        let model = RoundEntryModel(gameID: key.id, mode: .edit(roundID: key.roundID(index: 1)), repository: repository)
        let alice = key.participantID(position: 0)

        #expect(model.setInputMethod(.points, for: alice) == nil)
        #expect(model.fields[0].text == "6")
        #expect(model.save() == .saved)
        let entry = try #require(try repository.game(id: key.id).rounds.first?.entry(for: alice))
        #expect(entry.inputMethod == .points)
        #expect(entry.rawScore == 6)
        #expect(entry.cardGrid == nil)
    }
}
#endif
