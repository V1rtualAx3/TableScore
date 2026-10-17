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

/// Statut de cycle de vie d'une partie, modifié uniquement par une action explicite.
///
/// - `active` : la partie courante (une seule à la fois). Elle reste `active` même lorsque le moteur
///   indique qu'elle est terminée, afin de pouvoir corriger la dernière manche ; la fin de partie
///   affichée provient toujours de `SavedGame.computation.status`.
/// - `finished` : partie terminée (selon le moteur) et close par l'utilisateur (`finishGame`,
///   ou création d'une nouvelle partie) ; lecture seule, `reopenGame` permet une correction.
/// - `archived` : partie rangée ; « interrompue » si le moteur la considère encore en cours
///   (`SavedGame.isInterrupted`) ; lecture seule.
enum GameLifecycle: String, Sendable, Hashable, CaseIterable {
    case active
    case finished
    case archived
}

/// Motif précis d'une donnée persistée illisible ou incohérente.
///
/// Diagnostic local uniquement : ces valeurs ne sont **jamais** affichées telles quelles
/// (voir `GameRepositoryError.userFacingMessage`).
enum PersistedDataCorruption: Error, Sendable, Hashable {
    /// Charge utile concernée par une erreur de décodage.
    enum Payload: Sendable, Hashable {
        case rules
        case roundEntries(roundID: UUID)
    }

    /// Longueur maximale d'une valeur brute recopiée dans un diagnostic.
    static let maxEchoedValueLength = 32

    /// Valeur brute tronquée à `maxEchoedValueLength` caractères.
    case unknownLifecycle(String)
    case unreadablePayload(Payload)
    case unsupportedFormatVersion(Payload, version: Int)
    case payloadTooLarge(Payload, byteCount: Int)
    /// L'historique relu est refusé par le moteur (participants, manches, grilles, cumuls…).
    case invalidHistory(ValidationError)
    /// Statut `finished` alors que le moteur considère la partie en cours.
    case finishedGameNotOver
    /// Dates incompatibles avec le statut (active datée de fin ou d'archivage, terminée sans date
    /// de fin, archivée sans date d'archivage…).
    case inconsistentDates
    /// Titre stocké qui ne respecte pas `GameWritePlanner.validatedTitle`.
    case invalidTitle
    case duplicateGameID(UUID)
    case missingRoundRecord(roundID: UUID)
    case multipleActiveGames(count: Int)
    /// Filet de sécurité (non atteignable en pratique) pour une erreur d'un type imprévu.
    case unexpected(description: String)

    static func truncatedUnknownLifecycle(_ rawValue: String) -> PersistedDataCorruption {
        .unknownLifecycle(String(rawValue.prefix(maxEchoedValueLength)))
    }

    /// Conversion d'une erreur capturée. Volontairement fondée sur `any Error` : le code ne dépend
    /// pas de l'inférence du type d'erreur des blocs `catch` (typed throws).
    static func from(_ error: any Error) -> PersistedDataCorruption {
        if let corruption = error as? PersistedDataCorruption { return corruption }
        if let validationError = error as? ValidationError { return .invalidHistory(validationError) }
        return .unexpected(description: ErrorDiagnostics.summary(of: error))
    }
}

/// Résumé de diagnostic d'une erreur : type + domaine/code `NSError`, jamais sa description
/// (qui peut contenir un chemin de fichier ou une valeur saisie).
enum ErrorDiagnostics {
    static func summary(of error: any Error) -> String {
        let nsError = error as NSError
        return "\(type(of: error)) [\(nsError.domain) #\(nsError.code)]"
    }
}

/// Opération de stockage ayant échoué.
enum StorageOperation: String, Sendable, Hashable {
    case setup
    case read
    case write
    case encoding
}

/// Problème de titre de partie (texte libre facultatif).
enum GameTitleIssue: Sendable, Hashable {
    case tooLong(maxLength: Int)
    /// Caractère de contrôle, retour à la ligne ou séparateur de ligne.
    case invalidCharacters
}

/// Erreurs remontées par le dépôt. Aucune n'est silencieuse ; aucune ne simule un succès.
///
/// Les valeurs associées (`message`, motifs de corruption) servent au diagnostic local et aux
/// tests ; elles ne sont **jamais** affichées. L'interface utilise `userFacingMessage`.
enum GameRepositoryError: Error, Sendable, Hashable {
    /// Saisie ou historique refusé par `ScoreEngine` (rien n'a été écrit).
    case validation(ValidationError)
    case invalidTitle(GameTitleIssue)
    case gameNotFound(UUID)
    /// Modification refusée : seule la partie `active` est modifiable.
    case gameNotActive(id: UUID, lifecycle: GameLifecycle)
    /// Changement de statut impossible depuis `from` (ex. rouvrir une partie archivée).
    case invalidLifecycleTransition(id: UUID, from: GameLifecycle)
    /// Une autre partie est déjà active (identifiant fourni).
    case anotherGameActive(UUID)
    /// `finishGame` demandé alors que le moteur considère la partie en cours.
    case gameNotOver(UUID)
    case noRoundToDelete(gameID: UUID)
    /// Même identifiant (partie ou manche) déjà utilisé pour un contenu différent ou une autre partie.
    case identifierConflict(UUID)
    /// Données persistées illisibles : jamais de crash, jamais de valeur inventée.
    case corruptedData(gameID: UUID?, PersistedDataCorruption)
    /// Échec technique du stockage (transaction annulée). `message` = `ErrorDiagnostics.summary`.
    case storageFailure(StorageOperation, message: String)

    /// Conversion d'une erreur capturée (même principe que `PersistedDataCorruption.from`) :
    /// erreur du dépôt conservée, refus du moteur ⇒ `.validation`, autre ⇒ échec technique.
    static func from(_ error: any Error, operation: StorageOperation) -> GameRepositoryError {
        if let repositoryError = error as? GameRepositoryError { return repositoryError }
        if let validationError = error as? ValidationError { return .validation(validationError) }
        return .storageFailure(operation, message: ErrorDiagnostics.summary(of: error))
    }

    /// Message générique en français, sans nom de joueur, identifiant ni chemin de fichier.
    /// Les view models peuvent préciser un refus de saisie à partir de `ValidationError`.
    var userFacingMessage: String {
        switch self {
        case .validation:
            String(localized: "Les informations saisies ne sont pas valides.")
        case .invalidTitle:
            String(localized: "Le titre de la partie n'est pas valide.")
        case .gameNotFound:
            String(localized: "Cette partie n'existe plus.")
        case .gameNotActive:
            String(localized: "Cette partie est close : elle ne peut plus être modifiée.")
        case .invalidLifecycleTransition:
            String(localized: "Cette action n'est pas possible pour cette partie.")
        case .anotherGameActive:
            String(localized: "Une autre partie est en cours.")
        case .gameNotOver:
            String(localized: "La partie n'est pas encore terminée.")
        case .noRoundToDelete:
            String(localized: "Aucune manche à supprimer.")
        case .identifierConflict:
            String(localized: "Cette action entre en conflit avec une saisie déjà enregistrée.")
        case .corruptedData:
            String(localized: "Certaines données enregistrées sont illisibles.")
        case .storageFailure(.setup, _), .storageFailure(.read, _):
            String(localized: "Impossible de lire les données enregistrées.")
        case .storageFailure(.write, _), .storageFailure(.encoding, _):
            String(localized: "L'enregistrement a échoué. Aucune modification n'a été faite.")
        }
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
    /// Correction enregistrée. `removedRounds` liste les manches supprimées sur décision explicite.
    case saved(SavedGame, removedRounds: [RoundInput])
    /// Correction identique à l'existant : aucune écriture, manche non marquée corrigée.
    case unchanged(SavedGame)
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
///
/// Aucun changement de statut n'est déclenché implicitement par l'ajout ou la correction d'une
/// manche : `finishGame`, `reopenGame` et `archiveGame` ne sont appelés que sur action explicite
/// de l'utilisateur (seule exception documentée : `createGame` clôt l'ancienne partie active).
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
    /// des espaces de bordure ; titre ≤ `GameWritePlanner.maxTitleLength` caractères.
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

    /// Rouvre une partie `finished` pour correction (§4.6) : elle redevient `active`, `finishedAt`
    /// est effacé. Refusé si une autre partie est active ou si la partie est archivée ;
    /// idempotent si elle est déjà active.
    func reopenGame(id: UUID) throws(GameRepositoryError) -> SavedGame

    /// Range la partie (idempotent si déjà `archived`). L'historique est conservé.
    func archiveGame(id: UUID) throws(GameRepositoryError) -> SavedGame

    /// Suppression définitive (la confirmation est de la responsabilité de l'interface).
    /// Renvoie `false` si la partie n'existait pas (appel idempotent).
    @discardableResult
    func deleteGame(id: UUID) throws(GameRepositoryError) -> Bool

    /// Supprime **toutes** les parties (active, terminées, archivées, illisibles) en une seule
    /// transaction : en cas d'échec, rien n'est supprimé et `storageFailure` est levée.
    /// Idempotent (aucune partie ⇒ aucune écriture). La double confirmation est du ressort de l'interface.
    func deleteAllGames() throws(GameRepositoryError)
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
