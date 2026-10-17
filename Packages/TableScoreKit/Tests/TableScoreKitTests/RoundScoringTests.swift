import Foundation
import Testing
import TableScoreKit

/// Exemple du tableau §3.2 : Alice clôture toujours ; les autres joueurs suivent dans l'ordre.
struct OfficialExample: Sendable, CustomStringConvertible {
    let label: String
    let closerRaw: Int
    let othersRaw: [Int]
    let expected: Int
    let verdict: CloserVerdict

    var description: String { label }

    static let all: [OfficialExample] = [
        OfficialExample(label: "Alice 10, Bob 24, Chloé 10 ⇒ 20 (égalité)", closerRaw: 10, othersRaw: [24, 10],
                        expected: 20, verdict: .doubled(lowerParticipantIDs: [], tiedParticipantIDs: [Fx.chloe])),
        OfficialExample(label: "Alice 10, Bob 11 ⇒ 10 (plus petit strict)", closerRaw: 10, othersRaw: [11],
                        expected: 10, verdict: .soleLowest),
        OfficialExample(label: "Alice 12, Bob 9 ⇒ 24 (Bob fait mieux)", closerRaw: 12, othersRaw: [9],
                        expected: 24, verdict: .doubled(lowerParticipantIDs: [Fx.bob], tiedParticipantIDs: [])),
        OfficialExample(label: "Alice −2, Bob −4 ⇒ −2 (négatif)", closerRaw: -2, othersRaw: [-4],
                        expected: -2, verdict: .negativeNeverDoubled),
        OfficialExample(label: "Alice 0, Bob −1 ⇒ 0 (zéro)", closerRaw: 0, othersRaw: [-1],
                        expected: 0, verdict: .zeroNeverDoubled),
        OfficialExample(label: "Alice −5, Bob −5 ⇒ −5 (négatif malgré égalité)", closerRaw: -5, othersRaw: [-5],
                        expected: -5, verdict: .negativeNeverDoubled),
    ]
}

@Suite("Calcul d'une manche (§3.2, cas §10 n° 2–4)")
struct RoundScoringTests {

    private func score(
        closer: UUID = Fx.alice,
        _ scores: [UUID: Int],
        rules: GameRules = .classic
    ) throws -> RoundScoring {
        try ScoreEngine.scoreRound(
            Fx.round(1, closer: closer, scores),
            participants: Fx.players(scores.count),
            rules: rules
        )
    }

    @Test("Tableau officiel §3.2", arguments: OfficialExample.all)
    func officialExamples(_ example: OfficialExample) throws {
        var scores = [Fx.alice: example.closerRaw]
        for (offset, raw) in example.othersRaw.enumerated() {
            scores[pid(UInt8(offset + 2))] = raw
        }
        let result = try score(scores)

        #expect(result.closingRawScore == example.closerRaw)
        #expect(result.closingEffectiveScore == example.expected)
        #expect(result.verdict == example.verdict)
        // Seul le clôturant peut être modifié.
        for entry in result.scores where !entry.isClosing {
            #expect(entry.effectiveScore == entry.rawScore)
        }
    }

    @Test("§10 n° 4 : un adversaire inférieur et un supérieur ⇒ doublement")
    func oneLowerOneHigher() throws {
        let result = try score([Fx.alice: 5, Fx.bob: 3, Fx.chloe: 8])
        #expect(result.closingEffectiveScore == 10)
        #expect(result.verdict == .doubled(lowerParticipantIDs: [Fx.bob], tiedParticipantIDs: []))
        #expect(result.score(for: Fx.bob)?.effectiveScore == 3)
        #expect(result.score(for: Fx.chloe)?.effectiveScore == 8)
    }

    @Test("Tous les adversaires sont comparés, y compris le dernier")
    func comparesEveryParticipant() throws {
        let doubled = try score([Fx.alice: 5, Fx.bob: 9, Fx.chloe: 12, Fx.david: 5])
        #expect(doubled.closingEffectiveScore == 10)
        #expect(doubled.verdict == .doubled(lowerParticipantIDs: [], tiedParticipantIDs: [Fx.david]))

        let notDoubled = try score([Fx.alice: 5, Fx.bob: 9, Fx.chloe: 12, Fx.david: 6])
        #expect(notDoubled.closingEffectiveScore == 5)
        #expect(notDoubled.verdict == .soleLowest)
    }

    @Test("Inférieurs et égalités sont tous deux rapportés, dans l'ordre d'affichage")
    func reportsLowerAndTied() throws {
        let result = try score([Fx.alice: 6, Fx.bob: 6, Fx.chloe: -1, Fx.david: 2])
        #expect(result.closingEffectiveScore == 12)
        #expect(result.verdict == .doubled(lowerParticipantIDs: [Fx.chloe, Fx.david], tiedParticipantIDs: [Fx.bob]))
    }

    @Test("Clôturant autre que le premier joueur")
    func closerNotFirst() throws {
        let result = try score(closer: Fx.bob, [Fx.alice: 3, Fx.bob: 7])
        #expect(result.closingParticipantID == Fx.bob)
        #expect(result.closingEffectiveScore == 14)
        #expect(result.score(for: Fx.alice)?.effectiveScore == 3)
        #expect(result.score(for: Fx.bob)?.isClosing == true)
    }

    @Test("Zéro et négatif jamais doublés, même face à des scores inférieurs")
    func zeroAndNegativeNeverDoubled() throws {
        #expect(try score([Fx.alice: 0, Fx.bob: 0]).closingEffectiveScore == 0)
        #expect(try score([Fx.alice: -1, Fx.bob: -10]).closingEffectiveScore == -1)
    }

    @Test("Règles par défaut : pénalité active, aucune règle maison")
    func defaultRulesAreOfficial() {
        #expect(GameRules().isCloserPenaltyActive)
        #expect(GameRules().isOfficial)
        #expect(GameRules().targetScore == 100)
        #expect(GameRules(houseRules: HouseRules()).isCloserPenaltyActive)
    }

    @Test("Règle maison : pénalité désactivée uniquement si explicitement demandée")
    func houseRuleDisablesPenalty() throws {
        let rules = GameRules(houseRules: HouseRules(isCloserPenaltyDisabled: true))
        #expect(!rules.isOfficial)

        let tie = try score([Fx.alice: 10, Fx.bob: 10], rules: rules)
        #expect(tie.closingEffectiveScore == 10)
        #expect(tie.verdict == .penaltyDisabledByHouseRules)

        let sole = try score([Fx.alice: 4, Fx.bob: 10], rules: rules)
        #expect(sole.verdict == .soleLowest)

        let negative = try score([Fx.alice: -3, Fx.bob: -3], rules: rules)
        #expect(negative.verdict == .negativeNeverDoubled)
    }

    @Test("Débordement lors du doublement ⇒ erreur, pas de crash")
    func doublingOverflow() {
        #expect(throws: ValidationError.arithmeticOverflow(participantID: Fx.alice)) {
            _ = try score([Fx.alice: Int.max, Fx.bob: Int.max])
        }
    }

    @Test("Valeurs extrêmes sans doublement acceptées")
    func extremeValuesWithoutDoubling() throws {
        let negative = try score([Fx.alice: Int.min, Fx.bob: Int.min])
        #expect(negative.closingEffectiveScore == Int.min)

        let sole = try score([Fx.alice: Int.max - 1, Fx.bob: Int.max])
        #expect(sole.closingEffectiveScore == Int.max - 1)
    }
}
