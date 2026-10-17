import Foundation
import TableScoreKit

/// Enveloppe JSON versionnée des charges utiles persistées (règles, entrées de manche).
///
/// Le contenu utilise le `Codable` du moteur, dont le décodage valide déjà formes et plages
/// (grille 4 colonnes, cartes −2…12, normalisation des règles maison). `formatVersion` permet de
/// faire évoluer le format sans ambiguïté ; une version inconnue est une corruption typée.
struct PersistedPayload<Content: Codable>: Codable {
    static var currentFormatVersion: Int { 1 }

    let formatVersion: Int
    let content: Content
}

/// En-tête lu avant le contenu, pour distinguer « version non prise en charge » de « illisible ».
private struct PersistedPayloadHeader: Decodable {
    let formatVersion: Int
}

enum PayloadCoding {

    static func encode<Content: Codable>(_ content: Content) throws(GameRepositoryError) -> Data {
        let payload = PersistedPayload(
            formatVersion: PersistedPayload<Content>.currentFormatVersion,
            content: content
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(payload)
        } catch {
            throw GameRepositoryError.storageFailure(.encoding, message: String(describing: error))
        }
    }

    static func decode<Content: Codable>(
        _ type: Content.Type,
        from data: Data,
        payload: PersistedDataCorruption.Payload
    ) throws(PersistedDataCorruption) -> Content {
        let decoder = JSONDecoder()
        let header: PersistedPayloadHeader
        do {
            header = try decoder.decode(PersistedPayloadHeader.self, from: data)
        } catch {
            throw PersistedDataCorruption.unreadablePayload(payload)
        }
        guard header.formatVersion == PersistedPayload<Content>.currentFormatVersion else {
            throw PersistedDataCorruption.unsupportedFormatVersion(payload, version: header.formatVersion)
        }
        do {
            return try decoder.decode(PersistedPayload<Content>.self, from: data).content
        } catch {
            throw PersistedDataCorruption.unreadablePayload(payload)
        }
    }
}

/// Correspondance explicite enregistrements SwiftData → valeurs du moteur. Aucun force-unwrap :
/// toute valeur inattendue produit une `PersistedDataCorruption`, puis le moteur revalide
/// l'ensemble (participants, indices continus, clôturant, grilles cohérentes, débordements).
enum RecordMapper {

    static func savedGame(from record: GameRecord) throws(PersistedDataCorruption) -> SavedGame {
        guard let lifecycle = GameLifecycle(rawValue: record.lifecycleRaw) else {
            throw PersistedDataCorruption.unknownLifecycle(record.lifecycleRaw)
        }
        let rules = try PayloadCoding.decode(GameRules.self, from: record.rulesPayload, payload: .rules)

        var participants: [Participant] = []
        participants.reserveCapacity(record.participants.count)
        for participantRecord in record.participants {
            participants.append(Participant(
                id: participantRecord.participantID,
                displayName: participantRecord.displayName,
                displayOrder: participantRecord.displayOrder
            ))
        }

        var rounds: [RoundInput] = []
        rounds.reserveCapacity(record.rounds.count)
        for roundRecord in record.rounds {
            rounds.append(try roundInput(from: roundRecord))
        }

        do {
            return try SavedGame(
                id: record.gameID,
                title: record.title,
                lifecycle: lifecycle,
                rules: rules,
                participants: participants,
                rounds: rounds,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                finishedAt: record.finishedAt,
                archivedAt: record.archivedAt
            )
        } catch {
            throw PersistedDataCorruption.from(error)
        }
    }

    static func roundInput(from record: RoundRecord) throws(PersistedDataCorruption) -> RoundInput {
        let entries = try PayloadCoding.decode(
            [RoundEntry].self,
            from: record.entriesPayload,
            payload: .roundEntries(roundID: record.roundID)
        )
        return RoundInput(
            id: record.roundID,
            index: record.roundIndex,
            closingParticipantID: record.closingParticipantID,
            entries: entries
        )
    }

    // MARK: Écriture des champs

    static func apply(_ game: SavedGame, toHeaderOf record: GameRecord) {
        record.lifecycleRaw = game.lifecycle.rawValue
        record.updatedAt = game.updatedAt
        record.finishedAt = game.finishedAt
        record.archivedAt = game.archivedAt
    }

    static func entriesPayload(of round: RoundInput) throws(GameRepositoryError) -> Data {
        try PayloadCoding.encode(round.entries)
    }

    static func rulesPayload(of rules: GameRules) throws(GameRepositoryError) -> Data {
        try PayloadCoding.encode(rules)
    }
}
