import Foundation
import Testing
import TableScoreKit

@Suite("Noms de joueurs : longueur et caractères (audit M2)")
struct ParticipantNameTests {

    private func players(bobName: String) -> [Participant] {
        var players = Fx.players(3)
        players[1].displayName = bobName
        return players
    }

    @Test("24 caractères acceptés, 25 refusés")
    func lengthLimit() throws {
        #expect(Participant.maxDisplayNameLength == 24)
        try ScoreEngine.validate(participants: players(bobName: String(repeating: "a", count: 24)))
        #expect(throws: ValidationError.participantNameTooLong(participantID: Fx.bob, maxLength: 24)) {
            try ScoreEngine.validate(participants: players(bobName: String(repeating: "a", count: 25)))
        }
    }

    @Test("La limite porte sur le nom sans espaces de bordure")
    func lengthIgnoresBorderWhitespace() throws {
        try ScoreEngine.validate(participants: players(bobName: "   " + String(repeating: "b", count: 24) + "  "))
    }

    @Test("Graphèmes : un émoji composé compte pour un caractère")
    func graphemesCountAsOne() throws {
        let family = "👨‍👩‍👧"
        #expect(family.count == 1)
        try ScoreEngine.validate(participants: players(bobName: String(repeating: family, count: 24)))
        #expect(throws: ValidationError.participantNameTooLong(participantID: Fx.bob, maxLength: 24)) {
            try ScoreEngine.validate(participants: players(bobName: String(repeating: family, count: 25)))
        }
    }

    @Test("Retour à la ligne, tabulation, NUL et séparateur de ligne refusés", arguments: [
        "Al\nice", "Al\r\nice", "Al\tice", "\u{0000}Bob", "Bo\u{0000}b", "Bo\u{2028}b", "Bo\u{001B}b",
    ])
    func controlCharactersRejected(name: String) {
        #expect(throws: ValidationError.participantNameHasInvalidCharacters(participantID: Fx.bob)) {
            try ScoreEngine.validate(participants: players(bobName: name))
        }
    }

    @Test("Accents, espaces internes et émojis acceptés")
    func ordinaryNamesAccepted() throws {
        try ScoreEngine.validate(participants: players(bobName: "Zoé-Marie 🦊 O'Neil"))
        #expect(!Participant.containsDisallowedCharacters("Zoé-Marie 🦊 O'Neil"))
        #expect(Participant.containsDisallowedCharacters("a\nb"))
    }

    @Test("Un nom vide reste signalé comme vide (pas comme caractère interdit)")
    func emptyNameKeepsItsError() {
        #expect(throws: ValidationError.emptyParticipantName(participantID: Fx.bob)) {
            try ScoreEngine.validate(participants: players(bobName: " \n\t "))
        }
    }
}
