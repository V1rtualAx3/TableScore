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

    @Test("Graphèmes : une lettre + accent combinant compte pour un caractère")
    func graphemesCountAsOne() throws {
        // « e » + U+0301 : 1 graphème, 3 octets UTF-8 ⇒ 24 × 3 = 72 octets (< 256).
        let accented = "e\u{0301}"
        #expect(accented.count == 1)
        #expect(accented.utf8.count == 3)
        try ScoreEngine.validate(participants: players(bobName: String(repeating: accented, count: 24)))
        #expect(throws: ValidationError.participantNameTooLong(participantID: Fx.bob, maxLength: 24)) {
            try ScoreEngine.validate(participants: players(bobName: String(repeating: accented, count: 25)))
        }

        // Drapeau : 2 indicateurs régionaux de 4 octets = 8 octets, 1 graphème ⇒ 24 × 8 = 192 octets.
        let flag = "🇫🇷"
        #expect(flag.count == 1)
        #expect(flag.utf8.count == 8)
        try ScoreEngine.validate(participants: players(bobName: String(repeating: flag, count: 24)))
        #expect(throws: ValidationError.participantNameTooLong(participantID: Fx.bob, maxLength: 24)) {
            try ScoreEngine.validate(participants: players(bobName: String(repeating: flag, count: 25)))
        }
    }

    @Test("Émoji famille : 1 graphème mais 18 octets ⇒ la borne en octets s'applique avant 24 graphèmes")
    func familyEmojiHitsByteLimit() throws {
        // U+1F468 (4) + U+200D (3) + U+1F469 (4) + U+200D (3) + U+1F467 (4) = 18 octets.
        let family = "👨\u{200D}👩\u{200D}👧"
        #expect(family.count == 1)
        #expect(family.unicodeScalars.count == 5)
        #expect(family.utf8.count == 18)

        // 14 × 18 = 252 octets ≤ 256 et 14 graphèmes ≤ 24 ⇒ accepté.
        let fourteen = String(repeating: family, count: 14)
        #expect(fourteen.count == 14)
        #expect(fourteen.utf8.count == 252)
        try ScoreEngine.validate(participants: players(bobName: fourteen))

        // 15 × 18 = 270 octets > 256, alors que 15 graphèmes ≤ 24 ⇒ refusé pour cause d'octets.
        let fifteen = String(repeating: family, count: 15)
        #expect(fifteen.count == 15)
        #expect(fifteen.utf8.count == 270)
        #expect(throws: ValidationError.participantNameTooLong(participantID: Fx.bob, maxLength: 24)) {
            try ScoreEngine.validate(participants: players(bobName: fifteen))
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

    @Test("Zalgo : un seul graphème mais plus de 256 octets UTF-8 ⇒ refusé")
    func zalgoNameRejectedByByteCount() throws {
        let zalgo = "a" + String(repeating: "\u{0301}", count: 200)
        #expect(zalgo.count == 1)
        #expect(zalgo.utf8.count > Participant.maxDisplayNameByteCount)
        #expect(throws: ValidationError.participantNameTooLong(participantID: Fx.bob, maxLength: 24)) {
            try ScoreEngine.validate(participants: players(bobName: zalgo))
        }
        // Quelques accents combinants restent acceptés.
        try ScoreEngine.validate(participants: players(bobName: "Zoe\u{0301}"))
    }

    @Test("Nom fait uniquement de caractères invisibles ⇒ nom vide", arguments: [
        "\u{200B}", "\u{2060}", "\u{FEFF}", " \u{200B}\u{2060} ", "\u{200D}",
    ])
    func invisibleOnlyNameIsEmpty(name: String) {
        #expect(throws: ValidationError.emptyParticipantName(participantID: Fx.bob)) {
            try ScoreEngine.validate(participants: players(bobName: name))
        }
    }

    @Test("Contrôles bidirectionnels refusés", arguments: [
        "Bob\u{202E}", "\u{202A}Bob", "Bo\u{202C}b", "\u{2066}Bob\u{2069}", "Bob\u{2067}", "Bob\u{2068}",
    ])
    func bidiControlsRejected(name: String) {
        #expect(throws: ValidationError.participantNameHasInvalidCharacters(participantID: Fx.bob)) {
            try ScoreEngine.validate(participants: players(bobName: name))
        }
    }

    @Test("Liant U+200D et sélecteur U+FE0F conservés dans les émojis")
    func emojiJoinersAccepted() throws {
        try ScoreEngine.validate(participants: players(bobName: "👍\u{FE0F} Bob"))
        try ScoreEngine.validate(participants: players(bobName: "🧑\u{200D}🍳 Bob"))
        #expect(!Participant.containsDisallowedCharacters("🧑\u{200D}🍳\u{FE0F}"))
        #expect(Participant.hasVisibleContent("🧑\u{200D}🍳"))
        #expect(!Participant.hasVisibleContent("\u{200B} \u{2060}"))
    }

    @Test("Un nom vide reste signalé comme vide (pas comme caractère interdit)")
    func emptyNameKeepsItsError() {
        #expect(throws: ValidationError.emptyParticipantName(participantID: Fx.bob)) {
            try ScoreEngine.validate(participants: players(bobName: " \n\t "))
        }
    }
}
