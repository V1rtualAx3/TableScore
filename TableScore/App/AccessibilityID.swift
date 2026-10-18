import Foundation

/// Identifiants d'accessibilité (tests UI) — **liste unique** de l'application.
///
/// Source : docs/ux/lot2-parcours.md §3.1, complétée (« Complément T0 ») des identifiants
/// nécessaires aux tests prévus au §5. Un écran n'utilise jamais un identifiant littéral :
/// tout nouvel identifiant est ajouté ici (et figé par `AccessibilityIDTests`).
///
/// Conventions d'indice (jamais le nom du joueur : doublons, caractères spéciaux) :
/// - `position` : rang **0-based** du participant trié par `displayOrder` (= `displayOrder`,
///   attribué 0, 1, 2… à la création) ou rang 0-based d'une ligne de liste ;
/// - `number` : numéro **1-based** affiché à l'utilisateur (« Prénom du joueur 1 ») ;
/// - `index` : indice de manche du moteur (`RoundInput.index`, 1-based).
///
/// Les tests UI (cible séparée) utilisent les mêmes chaînes en littéral.
enum AccessibilityID {
    enum Home {
        static let resume = "home.resume"
        static let newGame = "home.newGame"
        // Complément T0
        static let finishedGames = "home.finishedGames"
        static let rules = "home.rules"
        static let settings = "home.settings"
    }

    enum Setup {
        static func player(number: Int) -> String { "setup.player.\(number)" }
        static let addPlayer = "setup.addPlayer"
        static let start = "setup.start"
        // Complément T0
        static let cancel = "setup.cancel"
        static let houseRules = "setup.houseRules"
        /// Raison affichée au-dessus de « Commencer » tant que la création est impossible.
        static let startBlockReason = "setup.startBlockReason"
        static let targetScore = "setup.targetScore"
    }

    enum Game {
        static func player(position: Int) -> String { "game.player.\(position)" }
        static let addRound = "game.addRound"
        // Complément T0
        static let menu = "game.menu"
        static let menuHistory = "game.menu.history"
        static let menuRules = "game.menu.rules"
        static let menuAbandon = "game.menu.abandon"
        static let historyLink = "game.historyLink"
        static let banner = "game.banner"
    }

    enum Round {
        static func score(position: Int) -> String { "round.score.\(position)" }
        static func sign(position: Int) -> String { "round.sign.\(position)" }
        static func closer(position: Int) -> String { "round.closer.\(position)" }
        static let save = "round.save"
        // Complément T0
        static func preview(position: Int) -> String { "round.preview.\(position)" }
        static let cancel = "round.cancel"
        static let blockingReasons = "round.blockingReasons"
        /// Pénalité du clôturant affichée au-dessus de « Enregistrer » (saisie complète).
        static let closerPreview = "round.closerPreview"
        /// Barre du clavier : « Suivant » et « OK » (fermeture du clavier).
        static let keyboardNext = "round.keyboardNext"
        static let keyboardDone = "round.keyboardDone"
        // Lot 3 (saisie par cartes)
        /// Sélecteur « Points | Cartes » du joueur (contrôle segmenté).
        static func inputMethod(position: Int) -> String { "round.inputMethod.\(position)" }
        /// Information après une bascule cartes → points (grille incomplète, score manuel conservé).
        static func cardsNotice(position: Int) -> String { "round.cardsNotice.\(position)" }
    }

    enum GameOver {
        static let title = "gameOver.title"
        static let replay = "gameOver.replay"
        // Complément T0
        static let winners = "gameOver.winners"
        static let history = "gameOver.history"
        static let home = "gameOver.home"
    }

    enum History {
        static func round(index: Int) -> String { "history.round.\(index)" }
        // Complément T0
        static let deleteLastRound = "history.deleteLastRound"
        static let undoDeletion = "history.undoDeletion"
        // Lot 3 (saisie par cartes)
        /// Ligne « Voir les cartes de la manche n » (consultation des grilles en lecture seule).
        static func viewCards(index: Int) -> String { "history.viewCards.\(index)" }
    }

    // Complément T0
    enum FinishedGames {
        static func game(position: Int) -> String { "finishedGames.game.\(position)" }
    }

    // Complément T0
    enum Settings {
        static let haptics = "settings.haptics"
        static let deleteAllData = "settings.deleteAllData"
    }

    // Complément T0
    enum StorageError {
        static let retry = "storageError.retry"
    }

    /// Lot 3 — saisie par cartes. `position` : rang 0-based du participant ; `column` et `row`
    /// sont **0-based** comme `CardGrid` (`row: 0` = rangée du haut) ; `value` : −2…12
    /// (« cards.valuePicker.-2 »).
    enum Cards {
        static func cell(position: Int, column: Int, row: Int) -> String {
            "cards.cell.\(position).\(column).\(row)"
        }
        static func removeColumn(position: Int, column: Int) -> String {
            "cards.removeColumn.\(position).\(column)"
        }
        static func total(position: Int) -> String { "cards.total.\(position)" }
        static func valuePicker(value: Int) -> String { "cards.valuePicker.\(value)" }
        /// Sélecteur de valeur : « Effacer » (case vide) et « OK » (fermeture).
        static let valuePickerClear = "cards.valuePicker.clear"
        static let valuePickerDone = "cards.valuePicker.done"
        /// Sélecteur de valeur : « Colonne N retirée » (colonne de la case courante).
        static let valuePickerRemoveColumn = "cards.valuePicker.removeColumn"
    }
}
