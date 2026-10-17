import Foundation
import SwiftData

// Schéma de persistance locale, version 1.
//
// Ne stocke que la source de vérité : participants, règles, manches (scores bruts, clôturant,
// mode de saisie, grille éventuelle), statut et dates. Aucun score retenu, cumul, classement ni
// vainqueur n'est persisté : tout est recalculé par `ScoreEngine` à la lecture.
//
// Règles et entrées de manche sont stockées en JSON (Codable du moteur) dans une enveloppe
// versionnée (`PersistedPayload`) plutôt qu'en attributs composites SwiftData : format explicite,
// décodage validé par le moteur, évolution maîtrisée par `formatVersion`.
//
// Évolution : toute modification de ces modèles exige un `TableScoreSchemaV2` (copie complète des
// classes), une étape dans `TableScoreMigrationPlan` et la mise à jour des alias ci-dessous.
// Aucune contrainte `.unique` : elle impose une sémantique d'« upsert » silencieux ; l'unicité est
// garantie par le dépôt (écrivain unique, contrôles explicites, relecture validée).

enum TableScoreSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [GameRecord.self, ParticipantRecord.self, RoundRecord.self]
    }
}

extension TableScoreSchemaV1 {

    @Model
    final class GameRecord {
        var gameID: UUID
        var title: String?
        /// `GameLifecycle.rawValue` ; une valeur inconnue est signalée comme corruption.
        var lifecycleRaw: String
        /// `GameRules` encodé dans `PersistedPayload`.
        var rulesPayload: Data
        var createdAt: Date
        var updatedAt: Date
        var finishedAt: Date?
        var archivedAt: Date?

        @Relationship(deleteRule: .cascade, inverse: \ParticipantRecord.game)
        var participants: [ParticipantRecord] = []

        @Relationship(deleteRule: .cascade, inverse: \RoundRecord.game)
        var rounds: [RoundRecord] = []

        init(
            gameID: UUID,
            title: String?,
            lifecycleRaw: String,
            rulesPayload: Data,
            createdAt: Date,
            updatedAt: Date,
            finishedAt: Date?,
            archivedAt: Date?
        ) {
            self.gameID = gameID
            self.title = title
            self.lifecycleRaw = lifecycleRaw
            self.rulesPayload = rulesPayload
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.finishedAt = finishedAt
            self.archivedAt = archivedAt
        }
    }

    @Model
    final class ParticipantRecord {
        var participantID: UUID
        var displayName: String
        var displayOrder: Int
        var game: GameRecord?

        init(participantID: UUID, displayName: String, displayOrder: Int) {
            self.participantID = participantID
            self.displayName = displayName
            self.displayOrder = displayOrder
        }
    }

    @Model
    final class RoundRecord {
        /// Identifiant du brouillon de saisie, clé d'idempotence.
        var roundID: UUID
        var roundIndex: Int
        var closingParticipantID: UUID
        /// `[RoundEntry]` (scores bruts, mode de saisie, grille) encodé dans `PersistedPayload`.
        var entriesPayload: Data
        var createdAt: Date
        var modifiedAt: Date
        var game: GameRecord?

        init(
            roundID: UUID,
            roundIndex: Int,
            closingParticipantID: UUID,
            entriesPayload: Data,
            createdAt: Date,
            modifiedAt: Date
        ) {
            self.roundID = roundID
            self.roundIndex = roundIndex
            self.closingParticipantID = closingParticipantID
            self.entriesPayload = entriesPayload
            self.createdAt = createdAt
            self.modifiedAt = modifiedAt
        }
    }
}

/// Plan de migration ; une seule version pour l'instant, prêt pour les suivantes.
enum TableScoreMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [TableScoreSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}

// Alias vers la version courante : le reste du code ne dépend pas du numéro de version.
typealias GameRecord = TableScoreSchemaV1.GameRecord
typealias ParticipantRecord = TableScoreSchemaV1.ParticipantRecord
typealias RoundRecord = TableScoreSchemaV1.RoundRecord
