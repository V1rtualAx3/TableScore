import Foundation
import TableScoreKit

/// Identifiant déterministe pour les tests.
func pid(_ n: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n))
}

enum Fx {
    static let alice = pid(1)
    static let bob = pid(2)
    static let chloe = pid(3)
    static let david = pid(4)

    private static let names = ["Alice", "Bob", "Chloé", "David", "Emma", "Farid", "Gaëlle", "Hugo", "Inès"]

    /// `count` joueurs : Alice = pid(1), Bob = pid(2), Chloé = pid(3)…
    static func players(_ count: Int) -> [Participant] {
        (0..<count).map { offset in
            Participant(
                id: pid(UInt8(offset + 1)),
                displayName: offset < names.count ? names[offset] : "Joueur \(offset + 1)",
                displayOrder: offset
            )
        }
    }

    /// Manche saisie en points. Entrées triées pour une construction reproductible.
    static func round(_ index: Int, closer: UUID, _ scores: [UUID: Int], id: UUID = UUID()) -> RoundInput {
        let entries = scores
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { RoundEntry.points($0.key, rawScore: $0.value) }
        return RoundInput(id: id, index: index, closingParticipantID: closer, entries: entries)
    }
}
