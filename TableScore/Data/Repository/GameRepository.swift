import Foundation
import TableScoreKit

// Contrat de persistance consommé par les futurs view models (`@Observable @MainActor`).
//
// Isolation : `@MainActor`, API synchrone.
// - SwiftData : `ModelContext` n'est pas `Sendable` ; le garder sur l'acteur principal évite tout
//   transfert d'objets modèles entre domaines d'isolation.
// - Volume minuscule (≤ 8 joueurs, quelques centaines de manches) : une transaction SQLite locale
//   prend quelques millisecondes ; un `actor`/`@ModelActor` imposerait de l'asynchrone partout
//   sans bénéfice mesurable.
// - Atomicité naturelle : une opération synchrone sur l'acteur principal ne peut pas être
//   entrelacée avec une autre (double tap ⇒ deux appels successifs, le second idempotent).
// Si un jour le volume le justifie, une implémentation `actor` pourra être ajoutée derrière un
// protocole asynchrone sans toucher au moteur.

/// Statut de cycle de vie d'une partie, choisi par l'utilisateur (jamais déduit en silence).
///
/// - `active` : la partie courante (une seule à la fois). Elle reste `active` même lorsque le moteur
///   indique qu'elle est terminée, afin de pouvoir corriger la dernière manche ; la fin de partie
///   affichée provient toujours de `SavedGame.computation.status`.
/// - `finished` : partie terminée (selon le moteur) et close ; lecture seule.
/// - `archived` : partie rangée ; « interrompue » si le moteur la considère encore en cours
///   (`SavedGame.isInterrupted`) ; lecture seule.
enum GameLifecycle: String, Sendable, Hashable, CaseIterable {
    case active
    case finished
    case archived
}

/// Motif précis d'une donnée persistée illisible ou incohérente.
enum PersistedDataCorruption: Error, Sendable, Hashable {
    /// Charge utile concernée par une erreur de décodage.
    enum Payload: Sendable, Hashable {
        case rules
        case roundEntries(roundID: UUID)
    }

    case unknownLifecycle(String)
    case unreadablePayload(Payload)
    case unsupportedFormatVersion(Payload, version: Int)
    /// L'historique relu est refusé par le moteur (participants, manches, grilles, cumuls…).
    case invalidHistory(ValidationError)
    case duplicateGameID(UUID)
    case missingRoundRecord(roundID: UUID)
    case multipleActiveGames(count: Int)
    /// Filet de sécurité (non atteignable en pratique) pour une erreur d'un type imprévu.
    case unexpected(description: String)

    /// Conversion d'une erreur capturée. Volontairement fondée sur `any Error` : le code ne dépend
    /// pas de l'inférence du type d'erreur des blocs `catch` (typed throws).
    static func from(_ error: any Error) -> PersistedDataCorruption {
        if let corruption = error as? PersistedDataCorruption { return corruption }
        if let validationError = error as? ValidationError { return .invalidHistory(validationError) }
        return .unexpected(description: String(describing: error))
    }
}

/// Opération de stockage ayant échoué.
enum StorageOperation: String, Sendable, Hashable {
    case setup
    case read
    case write
    case encoding
}

/// Erreurs remontées par le dépôt. Aucune n'est silencieuse ; aucune ne simule un succès.
enum GameRepositoryError: Error, Sendable, Hashable {
    /// Saisie ou historique refusé par `ScoreEngine` (rien n'a été écrit).
    case validation(ValidationError)
    case gameNotFound(UUID)
    /// Modification refusée : seule la partie `active` est modifiable.
    case gameNotActive(id: UUID, lifecycle: GameLifecycle)
    /// `finishGame` demandé alors que le moteur considère la partie en cours.
    case gameNotOver(UUID)
    case noRoundToDelete(gameID: UUID)
    /// Même identifiant (partie ou manche) déjà utilisé pour un contenu différent ou une autre partie.
    case identifierConflict(UUID)
    /// Données persistées illisibles : jamais de crash, jamais de valeur inventée.
    case corruptedData(gameID: UUID?, PersistedDataCorruption)
    /// Échec technique du stockage (transaction annulée). `message` sert au diagnostic local,
    /// il n'est pas destiné à l'affichage tel quel.
    case storageFailure(StorageOperation, message: String)

    /// Conversion d'une erreur capturée (même principe que `PersistedDataCorruption.from`) :
    /// erreur du dépôt conservée, refus du moteur ⇒ `.validation`, autre ⇒ échec technique.
    static func from(_ error: any Error, operation: StorageOperation) -> GameRepositoryError {
        if let repositoryError = error as? GameRepositoryError { return repositoryError }
        if let validationError = error as? ValidationError { return .validation(validationError) }
        return .storageFailure(operation, message: String(describing: error))
    }
}

/// Résultat d'un ajout de manche.
enum AppendRoundOutcome: Sendable, Hashable {
    /// Manche enregistrée.
    case inserted(SavedGame)
    /// Même identifiant et même contenu déjà enregistrés (double soumission) : rien n'a été écrit.
    case alreadySaved(SavedGame)

    var game: SavedGame {
        switch self {
        case .inserted(let game), .alreadySaved(let game): game
        }
    }
}

/// Décision explicite de l'utilisateur face à une fin anticipée révélée par une correction (§4.6).
enum EarlyEndResolution: Sendable, Hashable {
    /// Défaut : ne rien écrire et renvoyer `RoundReplacementOutcome.requiresDecision`.
    case rejectIfEarlyEnd
    /// Correction + suppression des manches postérieures, dans une seule transaction.
    /// Les identifiants confirmés doivent correspondre exactement à ceux calculés par le moteur,
    /// sinon rien n'est écrit et une nouvelle décision est demandée.
    case deleteRoundsAfterEarlyEnd(confirmedRoundIDs: [UUID])
}

/// Information nécessaire à l'interface pour demander la décision (rien n'a été écrit).
struct EarlyEndConflict: Sendable, Hashable {
    let inconsistency: EarlyEndInconsistency
    /// Recalcul complet avec la correction appliquée (manches postérieures incluses).
    let preview: GameComputation
}

/// Résultat d'une correction de manche.
enum RoundReplacementOutcome: Sendable, Hashable {
    /// Correction enregistrée (ou identique à l'existant : aucune écriture). `removedRounds` liste
    /// les manches supprimées sur décision explicite (vide sinon).
    case saved(SavedGame, removedRounds: [RoundInput])
    /// Fin anticipée : rien n'a été écrit, l'interface doit faire choisir l'utilisateur.
    case requiresDecision(EarlyEndConflict)
}

/// Résultat de la suppression de la dernière manche ; `deletedRound` permet l'annulation
/// (ré-ajout de la même manche, même identifiant, via `appendRound`).
struct RoundDeletion: Sendable, Hashable {
    let deletedRound: RoundInput
    let game: SavedGame
}

/// Élément de la liste des parties closes ; une partie illisible reste listée (et supprimable).
enum GameListing: Sendable, Hashable, Identifiable {
    case readable(SavedGame)
    case corrupted(id: UUID, updatedAt: Date, reason: PersistedDataCorruption)

    var id: UUID {
        switch self {
        case .readable(let game): game.id
        case .corrupted(let id, _, _): id
        }
    }

    var updatedAt: Date {
        switch self {
        case .readable(let game): game.updatedAt
        case .corrupted(_, let updatedAt, _): updatedAt
        }
    }
}

/// Source de vérité unique des parties. Toute validation et tout calcul passent par `ScoreEngine` ;
/// toute écriture est atomique (tout ou rien) et toute erreur est remontée.
@MainActor
protocol GameRepository: AnyObject {
    /// Partie courante, ou `nil` s'il n'y en a pas.
    func activeGame() throws(GameRepositoryError) -> SavedGame?

    func game(id: UUID) throws(GameRepositoryError) -> SavedGame

    /// Parties `finished` et `archived`, de la plus récemment modifiée à la plus ancienne.
    func closedGames() throws(GameRepositoryError) -> [GameListing]

    /// Crée la partie `id` (identifiant de brouillon : un second appel identique est idempotent).
    /// L'éventuelle partie active précédente est close dans la même transaction : `finished` si le
    /// moteur la considère terminée, sinon `archived` (« interrompue »). Noms et titre sont nettoyés
    /// des espaces de bordure.
    func createGame(
        id: UUID,
        participants: [Participant],
        rules: GameRules,
        title: String?
    ) throws(GameRepositoryError) -> SavedGame

    /// Ajoute une manche validée par `ScoreEngine.computeAppending`. Idempotent par identifiant de
    /// manche (même contenu ⇒ `.alreadySaved`, contenu différent ⇒ `.identifierConflict`).
    func appendRound(_ round: RoundInput, toGame gameID: UUID) throws(GameRepositoryError) -> AppendRoundOutcome

    /// Corrige une manche existante (même identifiant, même indice) via `ScoreEngine.computeReplacing`.
    func replaceRound(
        _ round: RoundInput,
        inGame gameID: UUID,
        resolution: EarlyEndResolution
    ) throws(GameRepositoryError) -> RoundReplacementOutcome

    func deleteLastRound(ofGame gameID: UUID) throws(GameRepositoryError) -> RoundDeletion

    /// Clôt la partie active si le moteur la considère terminée (idempotent si déjà `finished`).
    func finishGame(id: UUID) throws(GameRepositoryError) -> SavedGame

    /// Range la partie (idempotent si déjà `archived`). L'historique est conservé.
    func archiveGame(id: UUID) throws(GameRepositoryError) -> SavedGame

    /// Suppression définitive (la confirmation est de la responsabilité de l'interface).
    /// Renvoie `false` si la partie n'existait pas (appel idempotent).
    @discardableResult
    func deleteGame(id: UUID) throws(GameRepositoryError) -> Bool
}

@MainActor
extension GameRepository {
    func createGame(id: UUID, participants: [Participant], rules: GameRules) throws(GameRepositoryError) -> SavedGame {
        try createGame(id: id, participants: participants, rules: rules, title: nil)
    }

    /// Correction sans décision préalable : une fin anticipée est renvoyée sans rien écrire.
    func replaceRound(_ round: RoundInput, inGame gameID: UUID) throws(GameRepositoryError) -> RoundReplacementOutcome {
        try replaceRound(round, inGame: gameID, resolution: .rejectIfEarlyEnd)
    }
}
