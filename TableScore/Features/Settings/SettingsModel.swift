import Foundation
import Observation

/// État de l'écran Paramètres : double confirmation de la suppression globale et version.
/// La préférence haptique est un simple réglage local (`@AppStorage`) lu par la vue.
@Observable
@MainActor
final class SettingsModel {
    /// Étapes de la suppression de toutes les données ; rien n'est supprimé avant `.lastConfirmation` confirmée.
    enum DeletionStep: Equatable {
        case idle
        /// Première question (boîte de dialogue).
        case first
        /// Dernière confirmation explicite (alerte).
        case lastConfirmation
    }

    private(set) var deletionStep: DeletionStep = .idle
    private(set) var errorMessage: String?
    /// Vrai après une suppression réussie (message de confirmation affiché, annoncé à VoiceOver).
    private(set) var didDeleteAll = false

    private let repository: any GameRepository

    init(repository: any GameRepository) {
        self.repository = repository
    }

    var hasError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    // MARK: Double confirmation

    func beginDeletion() {
        didDeleteAll = false
        deletionStep = .first
    }

    /// Passe à la dernière confirmation (uniquement depuis la première).
    func continueDeletion() {
        guard deletionStep == .first else { return }
        deletionStep = .lastConfirmation
    }

    func cancelDeletion() {
        deletionStep = .idle
    }

    /// Supprime toutes les parties en une transaction. Sans avoir franchi les deux étapes : aucun
    /// effet. Renvoie `true` si le dépôt a été vidé (l'appelant notifie alors le routeur).
    @discardableResult
    func confirmDeleteAll() -> Bool {
        guard deletionStep == .lastConfirmation else { return false }
        deletionStep = .idle
        do {
            try repository.deleteAllGames()
            errorMessage = nil
            didDeleteAll = true
            return true
        } catch {
            errorMessage = GameRepositoryError.from(error, operation: .write).userFacingMessage
            didDeleteAll = false
            return false
        }
    }

    // MARK: Version

    /// « 1.0 (12) » ; build omis s'il est absent ou identique ; « Inconnue » sans information.
    static func versionText(shortVersion: String?, build: String?) -> String {
        let version = shortVersion?.trimmingCharacters(in: .whitespaces) ?? ""
        let buildNumber = build?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !version.isEmpty else { return "Inconnue" }
        guard !buildNumber.isEmpty, buildNumber != version else { return version }
        return "\(version) (\(buildNumber))"
    }

    static var currentVersionText: String {
        versionText(
            shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }
}
