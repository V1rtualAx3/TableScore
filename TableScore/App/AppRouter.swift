import Foundation
import Observation

/// Destinations poussées dans l'unique `NavigationStack` (docs/ux/lot2-parcours.md §1).
enum Route: Hashable, Sendable {
    /// Tableau des scores ; bascule sur la fin de partie si le moteur la considère terminée.
    case game(UUID)
    case history(UUID)
    case finishedGames
    case rules
    case settings
}

/// Mode du formulaire de manche : ajout ou correction d'une manche existante.
enum RoundEntryMode: Hashable, Sendable {
    case new
    case edit(roundID: UUID)
}

/// Feuilles modales, présentées une seule à la fois par `RootView`.
enum AppSheet: Hashable, Sendable, Identifiable {
    case newGame
    case roundEntry(gameID: UUID, mode: RoundEntryMode)

    var id: Self { self }
}

/// État de navigation de l'application (aucune donnée de score).
///
/// Contrat pour les écrans :
/// - pousser : `router.show(.history(id))` ou `NavigationLink(value: Route…)` ;
/// - feuille : `router.present(.roundEntry(gameID:mode:))`, fermeture par `router.dismissSheet()`
///   ou `dismiss()` (équivalents : la feuille est liée à `sheet`) ;
/// - après **toute écriture réussie** dans le dépôt : `router.notifyDataChanged()` ; les écrans
///   qui affichent des données du dépôt se rechargent sur `.task(id: router.dataRevision)`.
/// - Aucune restauration automatique du chemin après relance (évite un état fantôme).
@Observable
@MainActor
final class AppRouter {
    var path: [Route]
    var sheet: AppSheet?
    /// Incrémenté après chaque écriture réussie ; sert de déclencheur de rechargement.
    private(set) var dataRevision = 0

    init(path: [Route] = [], sheet: AppSheet? = nil) {
        self.path = path
        self.sheet = sheet
    }

    func show(_ route: Route) {
        path.append(route)
    }

    func present(_ sheet: AppSheet) {
        self.sheet = sheet
    }

    func dismissSheet() {
        sheet = nil
    }

    /// Ouvre une partie à la racine : création (« Commencer »), « Rejouer », « Reprendre ».
    /// Ferme la feuille éventuelle et remplace tout le chemin par `[.game(id)]`.
    func openGame(_ gameID: UUID) {
        sheet = nil
        path = [.game(gameID)]
    }

    /// Retour à l'accueil (abandon de partie, bouton « Accueil » de fin de partie).
    func popToRoot() {
        sheet = nil
        path.removeAll()
    }

    func notifyDataChanged() {
        dataRevision &+= 1
    }

    /// Clé de rechargement d'un écran affichant la partie `gameID` : change avec la partie
    /// **et** avec `dataRevision` (`.task(id: router.reloadKey(for: gameID))`).
    func reloadKey(for gameID: UUID) -> DataReloadKey {
        DataReloadKey(gameID: gameID, revision: dataRevision)
    }
}

/// Déclencheur de rechargement : partie affichée + révision des données. Inclure la partie évite
/// qu'un écran réutilisé par la navigation pour une autre partie (« Rejouer » remplace
/// `[.game(ancienne)]` par `[.game(nouvelle)]` à la même position) garde l'ancienne.
struct DataReloadKey: Hashable, Sendable {
    let gameID: UUID
    let revision: Int
}
