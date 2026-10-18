import Foundation
import Testing
import TableScoreKit

@Suite("Codable : aller-retour des modèles persistables")
struct CodableTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test("Participant")
    func participant() throws {
        let participant = Participant(id: Fx.alice, displayName: "  Zoé 🦊 ", displayOrder: 3)
        #expect(try roundTrip(participant) == participant)
    }

    @Test("GameRules : officielles, seuil personnalisé, pénalité désactivée")
    func gameRules() throws {
        let variants = [
            GameRules.classic,
            GameRules(targetScore: 250),
            GameRules(targetScore: 60, houseRules: HouseRules(isCloserPenaltyDisabled: true)),
        ]
        for rules in variants {
            #expect(try roundTrip(rules) == rules)
        }
    }

    @Test("GameRules : règles maison vides normalisées au décodage")
    func gameRulesDecodingNormalizes() throws {
        let json = #"{"edition":"classic","targetScore":100,"houseRules":{"isCloserPenaltyDisabled":false}}"#
        let decoded = try JSONDecoder().decode(GameRules.self, from: Data(json.utf8))
        #expect(decoded.houseRules == nil)
        #expect(decoded == GameRules.classic)
    }

    @Test("GameRules : édition inconnue refusée")
    func unknownEditionRejected() {
        let json = #"{"edition":"action","targetScore":100}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GameRules.self, from: Data(json.utf8))
        }
    }

    @Test("RoundDraft : points, cartes, clôturant et indicateur de pré-remplissage conservés")
    func roundDraft() throws {
        var draft = RoundDraft(index: 3, participants: Fx.players(3))
        draft.setPoints(-2, for: Fx.alice)
        draft.setInputMethod(.cards, for: Fx.bob)
        try draft.setCard(7, column: 0, row: 0, for: Fx.bob)
        try draft.setColumnRemoved(true, column: 1, for: Fx.bob)
        draft.setPoints(0, for: Fx.chloe)
        draft.closingParticipantID = Fx.chloe

        let decoded = try roundTrip(draft)
        #expect(decoded == draft)
        #expect(decoded.roundID == draft.roundID)
        #expect(decoded.participantIDs == [Fx.alice, Fx.bob, Fx.chloe])
        #expect(decoded.entry(for: Fx.chloe)?.points == 0)
        #expect(decoded.entry(for: Fx.bob)?.cardGrid.columns[0][0] == 7)
    }

    @Test("RoundDraft de correction (entrée cartes) : indicateur conservé")
    func editingDraft() throws {
        let grid = try CardGrid(rows: [[7, 1, 2, 3], [7, 4, 5, 6], [7, 8, 9, 10]])
        let aliceEntry = try RoundEntry.cards(Fx.alice, grid: grid)
        let round = RoundInput(index: 1, closingParticipantID: Fx.bob, entries: [
            aliceEntry,
            .points(Fx.bob, rawScore: 3),
        ])
        let draft = RoundDraft(editing: round, participants: Fx.players(2))
        let decoded = try roundTrip(draft)
        #expect(decoded == draft)
        #expect(decoded.entry(for: Fx.alice)?.isPointsDerivedFromGrid == true)
    }
}
