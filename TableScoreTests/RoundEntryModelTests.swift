import Foundation
import Testing
import TableScoreKit
@testable import TableScore

/// Saisie d'une manche (Lot 2, T4) : le modèle délègue tout calcul au Kit ; ces tests vérifient
/// les exemples impératifs du cahier (§3.2, §10 n° 2–4, 10, 12) **à travers** l'écran de saisie.
@Suite("Saisie d'une manche")
@MainActor
struct RoundEntryModelTests {
    // MARK: Données

    private static func uuid(_ n: UInt8) -> UUID {
        UUID(uuid: (0x7B, 0x4E, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n))
    }

    private static let gameID = uuid(0xA0)

    private static func players(_ names: [String]) -> [Participant] {
        names.enumerated().map { offset, name in
            Participant(id: uuid(UInt8(offset + 1)), displayName: name, displayOrder: offset)
        }
    }

    /// Partie active avec des manches déjà jouées (positions du clôturant et scores bruts).
    private static func makeRepository(
        names: [String],
        rounds: [(closer: Int, scores: [Int])] = [],
        rules: GameRules = .classic
    ) throws -> (InMemoryGameRepository, [Participant], [UUID]) {
        let repository = InMemoryGameRepository()
        let participants = players(names)
        _ = try repository.createGame(id: gameID, participants: participants, rules: rules)
        var roundIDs: [UUID] = []
        for (offset, round) in rounds.enumerated() {
            let roundID = uuid(UInt8(0x10 + offset))
            let input = RoundInput(
                id: roundID,
                index: RoundInput.firstIndex + offset,
                closingParticipantID: participants[round.closer].id,
                entries: zip(participants, round.scores).map { participant, score in
                    RoundEntry.points(participant.id, rawScore: score)
                }
            )
            _ = try repository.appendRound(input, toGame: gameID)
            roundIDs.append(roundID)
        }
        return (repository, participants, roundIDs)
    }

    /// Saisie au clavier telle que l'utilisateur la tape, puis choix du clôturant.
    private static func enter(_ texts: [String], closer: Int?, in model: RoundEntryModel) {
        for (field, text) in zip(model.fields, texts) {
            model.setText(text, for: field.participantID)
        }
        if let closer {
            model.selectCloser(model.fields[closer].participantID)
        }
    }

    private static func closerLine(_ model: RoundEntryModel) -> RoundEntryModel.PreviewLine? {
        model.preview?.lines.first { $0.isCloser }
    }

    // MARK: Exemples impératifs du cahier (§3.2)

    @Test("10 / 24 / 10, Alice clôt : 20, libellé d'égalité avant confirmation")
    func tieDoublesCloser() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob", "Chloé"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        Self.enter(["10", "24", "10"], closer: 0, in: model)

        let line = try #require(Self.closerLine(model))
        #expect(line.roundScore == 20)
        #expect(line.isDoubled)
        #expect(line.totalAfter == 20)
        #expect(line.closerDescription?.text == "Alice : 10 → 20 (score doublé : égalité avec Chloé)")
        #expect(model.canSave)
        // Aperçu seulement : rien n'est écrit avant confirmation.
        #expect(try repository.game(id: Self.gameID).rounds.isEmpty)
    }

    @Test("12 contre 9 : 24, « Bob a fait moins »")
    func lowerScoreDoublesCloser() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        Self.enter(["12", "9"], closer: 0, in: model)

        let line = try #require(Self.closerLine(model))
        #expect(line.roundScore == 24)
        #expect(line.closerDescription?.text == "Alice : 12 → 24 (score doublé : Bob a fait moins)")
    }

    @Test("Égalité et score inférieur : « a fait moins » est prioritaire")
    func lowerTakesPrecedenceOverTie() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob", "Chloé"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        Self.enter(["10", "8", "10"], closer: 0, in: model)

        let line = try #require(Self.closerLine(model))
        #expect(line.roundScore == 20)
        #expect(line.closerDescription?.text == "Alice : 10 → 20 (score doublé : Bob a fait moins)")
    }

    @Test("10 contre 11 : non doublé, seul plus petit score")
    func soleLowestIsNotDoubled() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        Self.enter(["10", "11"], closer: 0, in: model)

        let line = try #require(Self.closerLine(model))
        #expect(line.roundScore == 10)
        #expect(!line.isDoubled)
        #expect(line.closerDescription?.text == "Alice : 10 (seul plus petit score, pas de pénalité)")
    }

    @Test("0 contre −1 : 0, zéro jamais doublé (saisie avec le bouton ±)")
    func zeroIsNeverDoubled() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        let bob = model.fields[1].participantID
        model.setText("0", for: model.fields[0].participantID)
        model.setText("1", for: bob)
        model.toggleSign(for: bob)
        model.selectCloser(model.fields[0].participantID)

        #expect(model.fields[1].text == "\u{2212}1")
        #expect(model.fields[1].status == .value(-1))
        let line = try #require(Self.closerLine(model))
        #expect(line.roundScore == 0)
        #expect(line.closerDescription?.text == "Alice : 0 (zéro n'est jamais doublé)")
        let bobLine = try #require(model.preview?.lines.first { $0.participantID == bob })
        #expect(bobLine.roundScore == -1)
        #expect(bobLine.totalAfter == -1)
    }

    @Test("−5 contre −5 : −5, négatif jamais doublé malgré l'égalité")
    func negativeTieIsNeverDoubled() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        // Signe saisi de deux façons acceptées par le Kit : bouton ±, « - » ASCII.
        model.setText("5", for: model.fields[0].participantID)
        model.toggleSign(for: model.fields[0].participantID)
        model.setText("-5", for: model.fields[1].participantID)
        model.selectCloser(model.fields[0].participantID)

        let line = try #require(Self.closerLine(model))
        #expect(line.roundScore == -5)
        #expect(!line.isDoubled)
        #expect(line.closerDescription?.text == "Alice : \u{2212}5 (score négatif, jamais doublé)")
        #expect(line.closerDescription?.spoken.contains("moins 5") == true)
    }

    @Test("−2 contre −4 : −2")
    func negativeAgainstLowerIsNotDoubled() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        Self.enter(["-2", "-4"], closer: 0, in: model)
        #expect(Self.closerLine(model)?.roundScore == -2)
    }

    @Test("Règle maison : pénalité désactivée, libellé explicite")
    func houseRuleDisablesPenalty() throws {
        let rules = GameRules(houseRules: HouseRules(isCloserPenaltyDisabled: true))
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"], rules: rules)
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        Self.enter(["12", "9"], closer: 0, in: model)

        let line = try #require(Self.closerLine(model))
        #expect(line.roundScore == 12)
        #expect(line.closerDescription?.text == "Alice : 12 (pas de doublement : règle maison)")
    }

    @Test("Cumuls à venir : total avant → après, fin de partie annoncée")
    func previewShowsUpcomingTotals() throws {
        let (repository, _, _) = try Self.makeRepository(
            names: ["Alice", "Bob", "Chloé"],
            rounds: [(closer: 1, scores: [20, 5, 14]), (closer: 0, scores: [18, 30, 9]), (closer: 2, scores: [32, 25, 0])]
        )
        // Totaux : Alice 88 (20 + 36 doublé + 32), Bob 60, Chloé 23.
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        #expect(model.title == "Manche 4")
        Self.enter(["10", "24", "10"], closer: 0, in: model)

        let preview = try #require(model.preview)
        let alice = try #require(preview.lines.first)
        #expect(alice.totalBefore == 88)
        #expect(alice.totalAfter == 108)
        #expect(alice.totalText == "Total : 88 → 108")
        #expect(preview.endsGameAtThisRound)
    }

    // MARK: Validation de la saisie

    @Test("Enregistrement impossible si un score manque ou sans clôturant")
    func cannotSubmitIncompleteRound() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob", "Chloé"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        #expect(!model.canSave)
        #expect(model.blockingReasons.contains("qui a terminé la manche"))

        Self.enter(["10", "", "0"], closer: 0, in: model)
        #expect(!model.canSave)
        #expect(model.blockingReasons == ["score de Bob"])
        #expect(model.preview == nil)
        #expect(model.save() == .ignored)

        model.setText("7", for: model.fields[1].participantID)
        #expect(model.canSave)
        #expect(model.blockingReasons.isEmpty)
        #expect(model.blockingSummary == nil)
    }

    @Test("Sans clôturant, aucune présélection et enregistrement bloqué")
    func closerIsRequired() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        Self.enter(["3", "4"], closer: nil, in: model)
        #expect(model.closerID == nil)
        #expect(!model.canSave)
        #expect(model.blockingReasons == ["qui a terminé la manche"])
        #expect(model.save() == .ignored)
        #expect(try repository.game(id: Self.gameID).rounds.isEmpty)
    }

    @Test("Un seul clôturant : choisir un autre joueur remplace le précédent")
    func singleCloser() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        Self.enter(["3", "4"], closer: 0, in: model)
        model.selectCloser(model.fields[1].participantID)
        #expect(model.closerID == model.fields[1].participantID)
        #expect(model.preview?.lines.filter(\.isCloser).count == 1)
    }

    @Test("Bouton ± : vide → « − » (invalide) → vide ; 5 → −5 → 5")
    func signToggle() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        let alice = model.fields[0].participantID

        #expect(!model.fields[0].isNegative)
        model.toggleSign(for: alice)
        #expect(model.fields[0].text == "\u{2212}")
        #expect(model.fields[0].status == .signOnly)
        #expect(model.fields[0].isNegative)
        #expect(model.fields[0].message == nil) // saisie en cours : pas d'erreur affichée
        Self.enter(["\u{2212}", "4"], closer: 1, in: model)
        #expect(!model.canSave)
        #expect(model.blockingReasons == ["score de Alice"])

        model.toggleSign(for: alice)
        #expect(model.fields[0].text.isEmpty)
        #expect(model.fields[0].status == .empty)

        model.setText("5", for: alice)
        model.toggleSign(for: alice)
        #expect(model.fields[0].status == .value(-5))
        model.toggleSign(for: alice)
        #expect(model.fields[0].text == "5")
        #expect(model.fields[0].status == .value(5))
        #expect(model.canSave)
    }

    @Test("Zéro est une valeur, distincte du champ vide")
    func zeroIsDistinctFromEmpty() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        #expect(model.fields[0].status == .empty)
        #expect(model.fields[0].spokenValue == "vide")
        model.setText("0", for: model.fields[0].participantID)
        #expect(model.fields[0].status == .value(0))
    }

    @Test("Texte invalide : erreur bloquante ; valeur inhabituelle : avertissement seul")
    func invalidAndUnusualValues() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        Self.enter(["1a", "200"], closer: 1, in: model)

        #expect(model.fields[0].status == .invalid)
        #expect(model.fields[0].message == "Nombre entier attendu")
        #expect(model.blockingReasons == ["score de Alice à corriger"])

        #expect(model.fields[1].status == .unusual(200))
        #expect(model.fields[1].message?.contains("inhabituel") == true)

        model.setText("3", for: model.fields[0].participantID)
        #expect(model.canSave) // 200 reste enregistrable
    }

    // MARK: Enregistrement

    @Test("Double enregistrement : une seule manche, même identifiant")
    func doubleSaveWritesOnce() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        Self.enter(["3", "4"], closer: 0, in: model)
        let roundID = try #require(model.roundID)

        #expect(model.save() == .saved)
        #expect(model.save() == .ignored)
        #expect(model.isCompleted)
        #expect(model.hasWrittenData)
        let rounds = try repository.game(id: Self.gameID).rounds
        #expect(rounds.count == 1)
        #expect(rounds.first?.id == roundID)
    }

    @Test("Échec d'écriture : message, saisie conservée, nouvelle tentative avec le même identifiant")
    func failedSaveKeepsDraftAndRetriesWithSameID() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        Self.enter(["3", "4"], closer: 0, in: model)
        let roundID = try #require(model.roundID)

        repository.simulatesWriteFailure = true
        #expect(model.save() == .failed)
        #expect(model.saveErrorMessage == GameRepositoryError.storageFailure(.write, message: "").userFacingMessage)
        #expect(!model.isCompleted)
        #expect(!model.isSaving)
        #expect(model.fields.map(\.text) == ["3", "4"])
        #expect(try repository.game(id: Self.gameID).rounds.isEmpty)

        repository.simulatesWriteFailure = false
        model.dismissSaveError()
        #expect(model.save() == .saved)
        #expect(model.roundID == roundID)
        #expect(try repository.game(id: Self.gameID).rounds.map(\.id) == [roundID])
    }

    @Test("Saisie modifiée : confirmation avant abandon")
    func dirtyTracking() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        #expect(!model.isDirty)
        model.setText("3", for: model.fields[0].participantID)
        #expect(model.isDirty)
        model.setText("", for: model.fields[0].participantID)
        #expect(!model.isDirty)
        #expect(model.prepareForDismissal() == false)
    }

    @Test("Partie terminée : aucune nouvelle manche ne peut être saisie")
    func finishedGameRefusesNewRound() throws {
        let (repository, _, _) = try Self.makeRepository(
            names: ["Alice", "Bob"],
            rounds: [(closer: 1, scores: [60, 0]), (closer: 1, scores: [45, 0])]
        )
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        Self.enter(["1", "2"], closer: 0, in: model)
        #expect(!model.canSave)
        #expect(model.blockingReasons == ["La partie est terminée : aucune manche ne peut être ajoutée."])
    }

    @Test("Partie inconnue : état d'erreur lisible")
    func unknownGame() {
        let model = RoundEntryModel(gameID: Self.uuid(0xEE), mode: .new, repository: InMemoryGameRepository())
        #expect(model.loadState == .failed(message: GameRepositoryError.gameNotFound(Self.uuid(0xEE)).userFacingMessage))
        #expect(!model.canSave)
    }

    // MARK: Correction (§4.6)

    @Test("Correction : brouillon pré-rempli, recalcul des manches suivantes annoncé")
    func editPrefillsDraft() throws {
        let (repository, _, roundIDs) = try Self.makeRepository(
            names: ["Alice", "Bob"],
            rounds: [(closer: 0, scores: [-3, 10]), (closer: 1, scores: [4, 2])]
        )
        let model = RoundEntryModel(gameID: Self.gameID, mode: .edit(roundID: roundIDs[0]), repository: repository)
        #expect(model.title == "Correction de la manche 1")
        #expect(model.fields.map(\.text) == ["\u{2212}3", "10"])
        #expect(model.closerID == model.fields[0].participantID)
        #expect(!model.isDirty)
        #expect(model.preview?.recomputesLaterRounds == true)

        // Correction identique : succès sans écriture.
        #expect(model.save() == .saved)
        #expect(!model.hasWrittenData)
    }

    @Test("Correction créant une fin anticipée : aucune écriture sans décision, puis suppression confirmée")
    func editWithEarlyEndRequiresDecision() throws {
        let (repository, participants, roundIDs) = try Self.makeRepository(
            names: ["Alice", "Bob"],
            rounds: [(closer: 1, scores: [50, 0]), (closer: 1, scores: [40, 0]), (closer: 1, scores: [5, 0])]
        )
        let before = try repository.game(id: Self.gameID)
        let model = RoundEntryModel(gameID: Self.gameID, mode: .edit(roundID: roundIDs[0]), repository: repository)
        model.setText("60", for: participants[0].id) // Alice atteint 100 dès la manche 2
        #expect(model.preview?.earlyEndRoundIndex == 2)

        #expect(model.save() == .needsDecision)
        let decision = try #require(model.pendingDecision)
        guard case .deleteLaterRounds(let earlyEnd) = decision else {
            Issue.record("Décision de fin anticipée attendue")
            return
        }
        #expect(earlyEnd.laterRoundIDs == [roundIDs[2]])
        #expect(decision.message
            == "Cette correction termine la partie à la manche 2. La manche suivante (3) devra être supprimée.")
        #expect(try repository.game(id: Self.gameID) == before)

        // « Annuler la correction » : toujours rien d'écrit, saisie conservée.
        model.dismissDecision()
        #expect(model.pendingDecision == nil)
        #expect(model.fields[0].text == "60")
        #expect(try repository.game(id: Self.gameID) == before)
        #expect(model.save() == .needsDecision)

        // Choix explicite : correction + suppression en une transaction.
        let pending = try #require(model.pendingDecision)
        #expect(model.confirm(pending) == .saved)
        let after = try repository.game(id: Self.gameID)
        #expect(after.rounds.map(\.id) == [roundIDs[0], roundIDs[1]])
        #expect(after.rounds[0].entry(for: participants[0].id)?.rawScore == 60)
        #expect(after.isOver)
    }

    @Test("Décision confirmée puis saisie modifiée : nouvelle décision demandée")
    func confirmationIsInvalidatedByEdit() throws {
        let (repository, participants, roundIDs) = try Self.makeRepository(
            names: ["Alice", "Bob"],
            rounds: [(closer: 1, scores: [50, 0]), (closer: 1, scores: [40, 0]), (closer: 1, scores: [5, 0])]
        )
        let before = try repository.game(id: Self.gameID)
        let model = RoundEntryModel(gameID: Self.gameID, mode: .edit(roundID: roundIDs[0]), repository: repository)
        model.setText("60", for: participants[0].id)
        #expect(model.save() == .needsDecision)
        model.dismissDecision()
        model.setText("61", for: participants[0].id)
        #expect(model.save() == .needsDecision)
        #expect(try repository.game(id: Self.gameID) == before)
    }

    @Test("Correction faisant reprendre une partie terminée : information avant écriture")
    func editResumingGameAsksConfirmation() throws {
        let (repository, participants, roundIDs) = try Self.makeRepository(
            names: ["Alice", "Bob"],
            rounds: [(closer: 1, scores: [50, 0]), (closer: 1, scores: [60, 0])]
        )
        let before = try repository.game(id: Self.gameID)
        #expect(before.isOver)
        let model = RoundEntryModel(gameID: Self.gameID, mode: .edit(roundID: roundIDs[1]), repository: repository)
        model.setText("10", for: participants[0].id)

        #expect(model.save() == .needsDecision)
        #expect(model.pendingDecision == .gameResumes(targetScore: 100))
        #expect(try repository.game(id: Self.gameID) == before)

        let decision = try #require(model.pendingDecision)
        #expect(model.confirm(decision) == .saved)
        #expect(try repository.game(id: Self.gameID).isOver == false)
    }

    @Test("Correction d'une partie close : réouverture à l'enregistrement, puis statut « terminée » rétabli")
    func editFinishedGameReopensThenFinishes() throws {
        let (repository, participants, roundIDs) = try Self.makeRepository(
            names: ["Alice", "Bob"],
            rounds: [(closer: 1, scores: [50, 0]), (closer: 1, scores: [60, 0])]
        )
        _ = try repository.finishGame(id: Self.gameID)
        let model = RoundEntryModel(gameID: Self.gameID, mode: .edit(roundID: roundIDs[0]), repository: repository)
        model.setText("45", for: participants[0].id)
        // Ouvrir et saisir n'écrit rien.
        #expect(try repository.game(id: Self.gameID).lifecycle == .finished)

        #expect(model.save() == .saved)
        let after = try repository.game(id: Self.gameID)
        #expect(after.lifecycle == .finished)
        #expect(after.rounds[0].entry(for: participants[0].id)?.rawScore == 45)
        #expect(model.hasWrittenData)
    }

    @Test("Correction d'une manche introuvable : état d'erreur")
    func editUnknownRound() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .edit(roundID: Self.uuid(0xEF)), repository: repository)
        #expect(model.loadState == .failed(message: "Cette manche n'existe plus."))
    }

    // MARK: Libellés

    @Test("Liste de prénoms en français")
    func joinedNames() {
        #expect(PenaltyPreviewFormatter.joinedNames([]) == "")
        #expect(PenaltyPreviewFormatter.joinedNames(["Bob"]) == "Bob")
        #expect(PenaltyPreviewFormatter.joinedNames(["Bob", "Chloé"]) == "Bob et Chloé")
        #expect(PenaltyPreviewFormatter.joinedNames(["Bob", "Chloé", "Dimitri"]) == "Bob, Chloé et Dimitri")
    }

    @Test("Plusieurs joueurs à égalité ou plus bas : accord du verbe")
    func pluralReasons() throws {
        let (repository, _, _) = try Self.makeRepository(names: ["Alice", "Bob", "Chloé"])
        let model = RoundEntryModel(gameID: Self.gameID, mode: .new, repository: repository)
        Self.enter(["10", "10", "10"], closer: 0, in: model)
        #expect(Self.closerLine(model)?.closerDescription?.detail
            == "10 → 20 (score doublé : égalité avec Bob et Chloé)")

        Self.enter(["10", "2", "3"], closer: 0, in: model)
        #expect(Self.closerLine(model)?.closerDescription?.detail
            == "10 → 20 (score doublé : Bob et Chloé ont fait moins)")
    }

    @Test("Message de fin anticipée avec plusieurs manches")
    func earlyEndMessagePlural() {
        #expect(PenaltyPreviewFormatter.earlyEndMessage(endingRoundIndex: 6, laterRoundIndices: [7, 8, 9])
            == "Cette correction termine la partie à la manche 6. Les manches suivantes (7 à 9) devront être supprimées.")
        #expect(PenaltyPreviewFormatter.deleteLaterRoundsTitle(count: 3) == "Supprimer les manches suivantes")
    }

    @Test("Plage habituelle dérivée des cartes du Kit : −24 à 144")
    func usualRange() {
        #expect(RoundEntryModel.usualScores == -24...144)
    }
}
