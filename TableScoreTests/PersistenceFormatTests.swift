import Foundation
import Testing
import TableScoreKit
@testable import TableScore

/// Gel du format JSON V1 (`PersistedFormatV1`) : octets de référence exacts (clés triées).
///
/// Si l'un de ces tests échoue après une modification, NE PAS mettre à jour les fixtures :
/// des parties déjà enregistrées utilisent ce format. Toute évolution ⇒ `formatVersion` 2,
/// conservation d'un décodeur V1 et nouvelles fixtures V2 à côté de celles-ci.
@Suite("Persistance : format JSON V1 figé")
struct PersistenceFormatTests {
    private typealias Fx = PersistenceFixtures

    private static let aliceID = "7A5C0000-0000-0000-0000-000000000001"
    private static let bobID = "7A5C0000-0000-0000-0000-000000000002"

    // MARK: Fixtures littérales

    static let pointsEntriesJSON = #"{"content":[{"method":"points","participantID":"7A5C0000-0000-0000-0000-000000000001","rawScore":-2},{"method":"points","participantID":"7A5C0000-0000-0000-0000-000000000002","rawScore":0}],"formatVersion":1}"#

    /// Colonne 7/7/7 (triplet), 1/2/3, colonne marquée retirée, 12/−2/0 ⇒ 16.
    static let cardEntriesJSON = #"{"content":[{"grid":{"columns":[{"bottom":7,"middle":7,"removed":false,"top":7},{"bottom":3,"middle":2,"removed":false,"top":1},{"removed":true},{"bottom":0,"middle":-2,"removed":false,"top":12}]},"method":"cards","participantID":"7A5C0000-0000-0000-0000-000000000001","rawScore":16},{"method":"points","participantID":"7A5C0000-0000-0000-0000-000000000002","rawScore":20}],"formatVersion":1}"#

    /// Lot 3 : triplet négatif −2/−2/−2, colonne marquée retirée dont les valeurs saisies (5/5/vide)
    /// restent mémorisées (annulation du retrait), 1/2/3, 12/0/−1 ⇒ 0 + 0 + 6 + 11 = 17.
    static let negativeTripletAndRemovedColumnJSON = #"{"content":[{"grid":{"columns":[{"bottom":-2,"middle":-2,"removed":false,"top":-2},{"middle":5,"removed":true,"top":5},{"bottom":3,"middle":2,"removed":false,"top":1},{"bottom":-1,"middle":0,"removed":false,"top":12}]},"method":"cards","participantID":"7A5C0000-0000-0000-0000-000000000001","rawScore":17},{"method":"points","participantID":"7A5C0000-0000-0000-0000-000000000002","rawScore":20}],"formatVersion":1}"#

    static let classicRulesJSON = #"{"content":{"edition":"classic","targetScore":100},"formatVersion":1}"#

    static let houseRulesJSON = #"{"content":{"closerPenaltyDisabled":true,"edition":"classic","targetScore":150},"formatVersion":1}"#

    // MARK: Valeurs attendues

    private func pointsRound() -> RoundInput {
        RoundInput(
            id: Fx.uuid(0x51),
            index: 1,
            closingParticipantID: Fx.alice,
            entries: [.points(Fx.alice, rawScore: -2), .points(Fx.bob, rawScore: 0)]
        )
    }

    private func cardsRound() throws -> RoundInput {
        RoundInput(
            id: Fx.uuid(0x52),
            index: 1,
            closingParticipantID: Fx.bob,
            entries: [try RoundEntry.cards(Fx.alice, grid: try Fx.cardGrid()), .points(Fx.bob, rawScore: 20)]
        )
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    @Test("Identifiants de référence")
    func referenceIdentifiers() {
        #expect(Fx.alice.uuidString == Self.aliceID)
        #expect(Fx.bob.uuidString == Self.bobID)
        #expect(PersistedFormatV1.formatVersion == 1)
    }

    // MARK: Entrées

    @Test("Entrées « points » : encodage exact et décodage")
    func pointsEntries() throws {
        let round = pointsRound()
        #expect(text(try RecordMapper.entriesPayload(of: round)) == Self.pointsEntriesJSON)
        #expect(try RecordMapper.decodeEntries(Data(Self.pointsEntriesJSON.utf8), roundID: round.id) == round.entries)
    }

    @Test("Entrées « cartes » (triplet, colonne retirée) : encodage exact et décodage")
    func cardEntries() throws {
        let round = try cardsRound()
        #expect(text(try RecordMapper.entriesPayload(of: round)) == Self.cardEntriesJSON)
        let decoded = try RecordMapper.decodeEntries(Data(Self.cardEntriesJSON.utf8), roundID: round.id)
        #expect(decoded == round.entries)
        #expect(decoded.first?.cardGrid?.columns[2].isMarkedRemoved == true)
        #expect(decoded.first?.rawScore == 16)
    }

    @Test("Entrées « cartes » (triplet négatif, colonne retirée avec valeurs conservées) : encodage exact et décodage")
    func cardEntriesWithNegativeTripletAndRemovedValues() throws {
        let grid = try CardGrid(columns: [
            CardColumn(top: -2, middle: -2, bottom: -2),
            CardColumn(top: 5, middle: 5, bottom: nil, isMarkedRemoved: true),
            CardColumn(top: 1, middle: 2, bottom: 3),
            CardColumn(top: 12, middle: 0, bottom: -1),
        ])
        let round = RoundInput(
            id: Fx.uuid(0x53),
            index: 1,
            closingParticipantID: Fx.bob,
            entries: [try RoundEntry.cards(Fx.alice, grid: grid), .points(Fx.bob, rawScore: 20)]
        )
        #expect(text(try RecordMapper.entriesPayload(of: round)) == Self.negativeTripletAndRemovedColumnJSON)
        let decoded = try RecordMapper.decodeEntries(Data(Self.negativeTripletAndRemovedColumnJSON.utf8), roundID: round.id)
        #expect(decoded == round.entries)
        #expect(decoded.first?.rawScore == 17)
        #expect(decoded.first?.cardGrid?.columns[1].values == [5, 5, nil])
        #expect(decoded.first?.cardGrid?.evaluate().columns[0] == .identicalCards(value: -2))
    }

    // MARK: Règles

    @Test("Règles classiques : encodage exact et décodage")
    func classicRules() throws {
        #expect(text(try RecordMapper.rulesPayload(of: .classic)) == Self.classicRulesJSON)
        #expect(try RecordMapper.decodeRules(Data(Self.classicRulesJSON.utf8)) == .classic)
    }

    @Test("Règles maison : encodage exact et décodage")
    func houseRules() throws {
        let rules = GameRules(targetScore: 150, houseRules: HouseRules(isCloserPenaltyDisabled: true))
        #expect(text(try RecordMapper.rulesPayload(of: rules)) == Self.houseRulesJSON)
        #expect(try RecordMapper.decodeRules(Data(Self.houseRulesJSON.utf8)) == rules)
    }

    @Test("Règles maison vides : normalisées en règles officielles, même encodage")
    func emptyHouseRulesAreNormalized() throws {
        let rules = GameRules(houseRules: HouseRules())
        #expect(text(try RecordMapper.rulesPayload(of: rules)) == Self.classicRulesJSON)
    }

    // MARK: Robustesse du décodage

    @Test("Entrées mal formées rejetées (méthode inconnue, grille absente ou en trop, forme, plage)", arguments: [
        #"{"content":[{"method":"telepathy","participantID":"7A5C0000-0000-0000-0000-000000000001","rawScore":1}],"formatVersion":1}"#,
        #"{"content":[{"method":"cards","participantID":"7A5C0000-0000-0000-0000-000000000001","rawScore":1}],"formatVersion":1}"#,
        #"{"content":[{"grid":{"columns":[]},"method":"points","participantID":"7A5C0000-0000-0000-0000-000000000001","rawScore":1}],"formatVersion":1}"#,
        #"{"content":[{"grid":{"columns":[{"removed":true},{"removed":true},{"removed":true}]},"method":"cards","participantID":"7A5C0000-0000-0000-0000-000000000001","rawScore":0}],"formatVersion":1}"#,
        #"{"content":[{"grid":{"columns":[{"removed":true},{"removed":true},{"removed":true},{"bottom":0,"middle":0,"removed":false,"top":13}]},"method":"cards","participantID":"7A5C0000-0000-0000-0000-000000000001","rawScore":13}],"formatVersion":1}"#,
        #"{"content":[{"grid":{"columns":[{"top":1},{"removed":true},{"removed":true},{"removed":true}]},"method":"cards","participantID":"7A5C0000-0000-0000-0000-000000000001","rawScore":1}],"formatVersion":1}"#,
        #"{"content":[{"method":"points","participantID":"pas-un-uuid","rawScore":1}],"formatVersion":1}"#,
        #"{"content":[{"method":"points","participantID":"7A5C0000-0000-0000-0000-000000000001","rawScore":1.5}],"formatVersion":1}"#,
        #"{"formatVersion":1}"#,
        #"[]"#,
    ])
    func malformedEntriesRejected(json: String) {
        let roundID = Fx.uuid(0x53)
        #expect(throws: PersistedDataCorruption.unreadablePayload(.roundEntries(roundID: roundID))) {
            _ = try RecordMapper.decodeEntries(Data(json.utf8), roundID: roundID)
        }
    }

    @Test("Édition inconnue rejetée")
    func unknownEditionRejected() {
        let json = #"{"content":{"edition":"action","targetScore":100},"formatVersion":1}"#
        #expect(throws: PersistedDataCorruption.unreadablePayload(.rules)) {
            _ = try RecordMapper.decodeRules(Data(json.utf8))
        }
    }

    @Test("Version de format future signalée comme telle")
    func futureVersionReported() {
        let json = #"{"content":{"edition":"classic","targetScore":100},"formatVersion":2}"#
        #expect(throws: PersistedDataCorruption.unsupportedFormatVersion(.rules, version: 2)) {
            _ = try RecordMapper.decodeRules(Data(json.utf8))
        }
    }
}
