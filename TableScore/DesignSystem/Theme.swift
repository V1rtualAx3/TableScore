import SwiftUI

/// Jetons visuels minimaux (docs/ux/lot2-parcours.md §4). Couleurs système uniquement : elles
/// s'adaptent au mode sombre et au contraste accru. Une couleur n'est jamais seule porteuse
/// d'information : toujours un texte et/ou un symbole à côté.
enum Theme {
    /// Langue des textes d'interface (app française) : dates, durées relatives et listes
    /// ne dépendent pas de la région de l'appareil.
    static let locale = Locale(identifier: "fr_FR")

    enum Palette {
        /// Teinte de l'app (`AccentColor`). Contraste WCAG avec le texte blanc des boutons
        /// proéminents : clair `#1F6F78` = 5,83:1 ; sombre `#1B7A84` = 5,04:1 (≥ 4,5:1).
        /// (Luminance relative sRGB : L = 0,2126 R + 0,7152 G + 0,0722 B linéarisés ; ratio = 1,05 / (L + 0,05).)
        static var accent: Color { .accentColor }
        /// Toujours accompagné de « En tête » + `Theme.Symbol.leader`.
        static var leader: Color { .green }
        /// Toujours accompagné de « ×2 Doublé » + `Theme.Symbol.doubled`.
        static var doubled: Color { .orange }
        /// Toujours accompagné d'un texte + `Theme.Symbol.warning`.
        static var warning: Color { .orange }
        static var background: Color { Color(.systemGroupedBackground) }
        static var surface: Color { Color(.secondarySystemGroupedBackground) }
    }

    /// Styles Dynamic Type uniquement (aucune taille fixe).
    enum Typography {
        /// Totaux du tableau des scores.
        static var total: Font { .system(.largeTitle, design: .rounded).monospacedDigit().bold() }
        /// Champs de saisie d'une manche.
        static var entryScore: Font { .title2.monospacedDigit() }
        static var playerName: Font { .title3 }
        static var detail: Font { .subheadline }
    }

    /// Grille 4/8 pt.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let row: CGFloat = 12
        static let card: CGFloat = 16
    }

    enum Size {
        /// Cible tactile minimale (HIG).
        static let minTapTarget: CGFloat = 44
    }

    /// Symboles SF partagés (aucun visuel de la marque du jeu).
    enum Symbol {
        static let leader = "crown.fill"
        static let doubled = "multiply.circle.fill"
        static let warning = "exclamationmark.triangle.fill"
        static let closer = "flag.checkered"
        static let selected = "checkmark.circle.fill"
        static let sign = "plusminus"
    }
}
