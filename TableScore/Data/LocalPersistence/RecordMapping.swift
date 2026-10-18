import Foundation
import TableScoreKit

/// Format JSON **V1** des charges utiles persistées (règles, entrées de manche).
///
/// Le format appartient à la couche de persistance (DTO explicites) et non au `Codable` du moteur :
/// une évolution du moteur ne peut pas rendre illisibles des parties déjà enregistrées. Le décodage
/// repasse toujours par les initialiseurs validants du moteur (`CardColumn`, `CardGrid`), puis
/// l'historique complet est revalidé par `ScoreEngine`.
///
/// FORMAT FIGÉ — fixtures d'octets exacts dans `PersistenceFormatTests`. Toute modification
/// (clé, type, sémantique) ⇒ `formatVersion` 2 + conservation d'un décodeur V1.
///
/// Enveloppe : `{"content":…,"formatVersion":1}` (JSON, clés triées).
/// - Règles : `{"closerPenaltyDisabled":true?,"edition":"classic","targetScore":100}`
///   (`closerPenaltyDisabled` absent = aucune règle maison).
/// - Entrées : `[{"grid":{…}?,"method":"points"|"cards","participantID":"UUID","rawScore":Int}]`,
///   grille = `{"columns":[{"bottom":Int?,"middle":Int?,"removed":Bool,"top":Int?}×4]}`.
enum PersistedFormatV1 {
    static let formatVersion = 1

    struct Envelope<Content: Codable>: Codable {
        let content: Content
        let formatVersion: Int
    }

    struct Rules: Codable, Equatable {
        let closerPenaltyDisabled: Bool?
        let edition: String
        let targetScore: Int
    }

    struct Entry: Codable, Equatable {
        let grid: Grid?
        let method: String
        let participantID: UUID
        let rawScore: Int
    }

    struct Grid: Codable, Equatable {
        let columns: [Column]
    }

    struct Column: Codable, Equatable {
        let bottom: Int?
        let middle: Int?
        let removed: Bool
        let top: Int?
    }

    static let pointsMethod = "points"
    static let cardsMethod = "cards"
}

/// En-tête lu avant le contenu, pour distinguer « version non prise en charge » de « illisible ».
private struct PersistedPayloadHeader: Decodable {
    let formatVersion: Int
}

enum PayloadCoding {
    /// Taille maximale d'une charge utile (écrite ou relue). Une manche de 8 joueurs en mode
    /// « cartes » occupe environ 2 Kio : la marge est large, le décodage reste borné.
    static let maxPayloadByteCount = 64 * 1024

    static func encode<Content: Codable>(_ content: Content) throws(GameRepositoryError) -> Data {
        let envelope = PersistedFormatV1.Envelope(content: content, formatVersion: PersistedFormatV1.formatVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw GameRepositoryError.storageFailure(.encoding, message: ErrorDiagnostics.summary(of: error))
        }
        // Ne jamais écrire ce qui ne pourrait pas être relu.
        guard data.count <= maxPayloadByteCount else {
            throw GameRepositoryError.storageFailure(.encoding, message: "Charge utile trop volumineuse.")
        }
        return data
    }

    static func decode<Content: Codable>(
        _ type: Content.Type,
        from data: Data,
        payload: PersistedDataCorruption.Payload
    ) throws(PersistedDataCorruption) -> Content {
        guard data.count <= maxPayloadByteCount else {
            throw PersistedDataCorruption.payloadTooLarge(payload, byteCount: data.count)
        }
        let decoder = JSONDecoder()
        let header: PersistedPayloadHeader
        do {
            header = try decoder.decode(PersistedPayloadHeader.self, from: data)
        } catch {
            throw PersistedDataCorruption.unreadablePayload(payload)
        }
        guard header.formatVersion == PersistedFormatV1.formatVersion else {
            throw PersistedDataCorruption.unsupportedFormatVersion(payload, version: header.formatVersion)
        }
        do {
            return try decoder.decode(PersistedFormatV1.Envelope<Content>.self, from: data).content
        } catch {
            throw PersistedDataCorruption.unreadablePayload(payload)
        }
    }
}

/// Correspondance explicite enregistrements SwiftData ⇄ valeurs du moteur. Aucun force-unwrap :
/// toute valeur inattendue produit une `PersistedDataCorruption`, puis le moteur revalide
/// l'ensemble (participants, indices continus, clôturant, grilles cohérentes, débordements).
enum RecordMapper {

    static func savedGame(from record: GameRecord) throws(PersistedDataCorruption) -> SavedGame {
        guard let lifecycle = GameLifecycle(rawValue: record.lifecycleRaw) else {
            throw PersistedDataCorruption.truncatedUnknownLifecycle(record.lifecycleRaw)
        }
        let rules = try decodeRules(record.rulesPayload)

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
        var roundInfo: [UUID: SavedRoundInfo] = [:]
        rounds.reserveCapacity(record.rounds.count)
        for roundRecord in record.rounds {
            rounds.append(try roundInput(from: roundRecord))
            roundInfo[roundRecord.roundID] = SavedRoundInfo(
                createdAt: roundRecord.createdAt,
                modifiedAt: roundRecord.modifiedAt
            )
        }

        let game: SavedGame
        do {
            game = try SavedGame(
                id: record.gameID,
                title: record.title,
                lifecycle: lifecycle,
                rules: rules,
                participants: participants,
                rounds: rounds,
                roundInfo: roundInfo,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                finishedAt: record.finishedAt,
                archivedAt: record.archivedAt
            )
        } catch {
            throw PersistedDataCorruption.from(error)
        }
        // Invariant : une partie close comme terminée l'est aussi selon le moteur.
        guard lifecycle != .finished || game.isOver else {
            throw PersistedDataCorruption.finishedGameNotOver
        }
        guard datesMatchLifecycle(lifecycle, finishedAt: record.finishedAt, archivedAt: record.archivedAt) else {
            throw PersistedDataCorruption.inconsistentDates
        }
        // Le titre stocké doit respecter les mêmes règles qu'à la création.
        guard isValidStoredTitle(record.title) else {
            throw PersistedDataCorruption.invalidTitle
        }
        return game
    }

    /// Dates attendues selon le statut (toujours produites ainsi par `GameWritePlanner`) :
    /// active ⇒ ni fin ni archivage ; terminée ⇒ date de fin, pas d'archivage ;
    /// archivée ⇒ date d'archivage (date de fin facultative : partie terminée ou interrompue).
    static func datesMatchLifecycle(_ lifecycle: GameLifecycle, finishedAt: Date?, archivedAt: Date?) -> Bool {
        switch lifecycle {
        case .active: return finishedAt == nil && archivedAt == nil
        case .finished: return finishedAt != nil && archivedAt == nil
        case .archived: return archivedAt != nil
        }
    }

    private static func isValidStoredTitle(_ title: String?) -> Bool {
        do {
            return try GameWritePlanner.validatedTitle(title) == title
        } catch {
            return false
        }
    }

    static func roundInput(from record: RoundRecord) throws(PersistedDataCorruption) -> RoundInput {
        RoundInput(
            id: record.roundID,
            index: record.roundIndex,
            closingParticipantID: record.closingParticipantID,
            entries: try decodeEntries(record.entriesPayload, roundID: record.roundID)
        )
    }

    // MARK: Règles

    static func rulesPayload(of rules: GameRules) throws(GameRepositoryError) -> Data {
        let dto = PersistedFormatV1.Rules(
            closerPenaltyDisabled: rules.houseRules?.isCloserPenaltyDisabled,
            edition: rules.edition.rawValue,
            targetScore: rules.targetScore
        )
        return try PayloadCoding.encode(dto)
    }

    static func decodeRules(_ data: Data) throws(PersistedDataCorruption) -> GameRules {
        let dto = try PayloadCoding.decode(PersistedFormatV1.Rules.self, from: data, payload: .rules)
        guard let edition = GameEdition(rawValue: dto.edition) else {
            throw PersistedDataCorruption.unreadablePayload(.rules)
        }
        let houseRules = dto.closerPenaltyDisabled.map { HouseRules(isCloserPenaltyDisabled: $0) }
        return GameRules(edition: edition, targetScore: dto.targetScore, houseRules: houseRules)
    }

    // MARK: Entrées de manche

    static func entriesPayload(of round: RoundInput) throws(GameRepositoryError) -> Data {
        var dtos: [PersistedFormatV1.Entry] = []
        dtos.reserveCapacity(round.entries.count)
        for entry in round.entries {
            dtos.append(entryDTO(entry))
        }
        return try PayloadCoding.encode(dtos)
    }

    static func decodeEntries(_ data: Data, roundID: UUID) throws(PersistedDataCorruption) -> [RoundEntry] {
        let payload = PersistedDataCorruption.Payload.roundEntries(roundID: roundID)
        let dtos = try PayloadCoding.decode([PersistedFormatV1.Entry].self, from: data, payload: payload)
        var entries: [RoundEntry] = []
        entries.reserveCapacity(dtos.count)
        for dto in dtos {
            entries.append(try entry(from: dto, payload: payload))
        }
        return entries
    }

    private static func entryDTO(_ entry: RoundEntry) -> PersistedFormatV1.Entry {
        switch entry.source {
        case .points:
            return PersistedFormatV1.Entry(
                grid: nil,
                method: PersistedFormatV1.pointsMethod,
                participantID: entry.participantID,
                rawScore: entry.rawScore
            )
        case .cards(let grid):
            let columns = grid.columns.map {
                PersistedFormatV1.Column(bottom: $0.bottom, middle: $0.middle, removed: $0.isMarkedRemoved, top: $0.top)
            }
            return PersistedFormatV1.Entry(
                grid: PersistedFormatV1.Grid(columns: columns),
                method: PersistedFormatV1.cardsMethod,
                participantID: entry.participantID,
                rawScore: entry.rawScore
            )
        }
    }

    private static func entry(
        from dto: PersistedFormatV1.Entry,
        payload: PersistedDataCorruption.Payload
    ) throws(PersistedDataCorruption) -> RoundEntry {
        switch dto.method {
        case PersistedFormatV1.pointsMethod:
            guard dto.grid == nil else { throw PersistedDataCorruption.unreadablePayload(payload) }
            return RoundEntry(participantID: dto.participantID, rawScore: dto.rawScore, source: .points)
        case PersistedFormatV1.cardsMethod:
            guard let gridDTO = dto.grid else { throw PersistedDataCorruption.unreadablePayload(payload) }
            let grid = try cardGrid(from: gridDTO, payload: payload)
            return RoundEntry(participantID: dto.participantID, rawScore: dto.rawScore, source: .cards(grid))
        default:
            throw PersistedDataCorruption.unreadablePayload(payload)
        }
    }

    /// Plages de valeurs et forme (4 colonnes) validées par les initialiseurs du moteur.
    private static func cardGrid(
        from dto: PersistedFormatV1.Grid,
        payload: PersistedDataCorruption.Payload
    ) throws(PersistedDataCorruption) -> CardGrid {
        do {
            var columns: [CardColumn] = []
            for column in dto.columns {
                columns.append(try CardColumn(
                    top: column.top,
                    middle: column.middle,
                    bottom: column.bottom,
                    isMarkedRemoved: column.removed
                ))
            }
            return try CardGrid(columns: columns)
        } catch {
            throw PersistedDataCorruption.unreadablePayload(payload)
        }
    }

    // MARK: En-tête de partie

    static func apply(_ game: SavedGame, toHeaderOf record: GameRecord) {
        record.lifecycleRaw = game.lifecycle.rawValue
        record.updatedAt = game.updatedAt
        record.finishedAt = game.finishedAt
        record.archivedAt = game.archivedAt
    }
}
