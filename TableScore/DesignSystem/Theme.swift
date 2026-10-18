import SwiftUI
import UIKit

/// Jetons visuels minimaux (docs/ux/lot2-parcours.md §4). Une couleur n'est jamais seule porteuse
/// d'information : toujours un texte et/ou un symbole à côté.
///
/// Contraste (audit `performAccessibilityAudit`, cahier §10 n° 16) : tout **texte** (et symbole
/// porteur de sens) est ≥ 4,5:1 sur les fonds de l'app, dans les deux thèmes. Les couleurs système
/// `.secondary`/`.tertiary`/`secondaryLabel` (≈ 3,1–3,4:1 en clair sur `systemGroupedBackground`),
/// `.orange`, `.green` et `.red` (≈ 2–3,6:1 en clair) ne servent donc **jamais** de couleur de texte :
/// utiliser les jetons ci-dessous. Ratios WCAG (luminance relative sRGB linéarisée,
/// ratio = (L1 + 0,05) / (L2 + 0,05)) mesurés sur blanc, `#F2F2F7`, `tertiarySystemFill` (clair) et
/// noir, `#1C1C1E`, `#2C2C2E`, `tertiarySystemFill` (sombre) : minimum indiqué pour chaque jeton.
enum Theme {
    /// Langue des textes d'interface (app française) : dates, durées relatives et listes
    /// ne dépendent pas de la région de l'appareil.
    static let locale = Locale(identifier: "fr_FR")

    enum Palette {
        /// Teinte de l'app (`AccentColor`) : clair `#1A626A` (texte sur fonds ≥ 5,5:1, texte blanc
        /// des boutons proéminents 7,0:1) ; sombre `#58BEC9` (texte sur fonds ≥ 4,8:1 sur le
        /// remplissage le plus clair des lignes de formulaire en feuille `#3E3E42` ; texte **noir** des boutons proéminents ≈ 9,6:1,
        /// voir `onAccent`). L'ancienne teinte sombre `#1B7A84` tombait à 3,4:1 sur `#1C1C1E`.
        static var accent: Color { .accentColor }
        /// Libellé posé sur la teinte (boutons `.borderedProminent`) : blanc en clair, noir en sombre.
        /// Appliqué par `onAccentForeground()` (`PrimaryActionButton.swift`).
        static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x000000)
        /// Texte secondaire (légendes, notes, en-têtes et pieds de section, champs vides) :
        /// clair `#5C5C61` ≥ 5,2:1 ; sombre `#AEAEB2` ≥ 4,8:1. Contraste accru : plus marqué.
        static let secondaryText = adaptive(
            light: 0x5C5C61,
            dark: 0xAEAEB2,
            increasedContrastLight: 0x3A3A3C,
            increasedContrastDark: 0xD1D1D6
        )
        /// Toujours accompagné de « En tête » + `Theme.Symbol.leader`.
        /// Vert : clair `#18692C` ≥ 5,3:1 ; sombre `#30D158` ≥ 5,2:1.
        static let leader = adaptive(light: 0x18692C, dark: 0x30D158)
        /// Toujours accompagné de « ×2 Doublé » + `Theme.Symbol.doubled`.
        /// Orange : clair `#9C4500` ≥ 5,0:1 ; sombre `#FF9F0A` ≥ 5,1:1.
        static let doubled = adaptive(light: 0x9C4500, dark: 0xFF9F0A)
        /// Toujours accompagné d'un texte + `Theme.Symbol.warning` (même orange que `doubled`).
        static let warning = adaptive(light: 0x9C4500, dark: 0xFF9F0A)
        /// Texte des actions destructives visibles dans l'écran (pas des menus ni des boîtes de
        /// dialogue système) : clair `#B3261E` ≥ 5,1:1 ; sombre `#FF6961` ≥ 4,5:1 sur les fonds
        /// des listes (`systemRed` : 3,6:1 en clair).
        static let destructive = adaptive(light: 0xB3261E, dark: 0xFF6961)
        static var background: Color { Color(.systemGroupedBackground) }
        static var surface: Color { Color(.secondarySystemGroupedBackground) }

        /// Couleur dynamique (thème clair/sombre, contraste accru) à partir de valeurs sRGB `0xRRGGBB`.
        private static func adaptive(
            light: UInt32,
            dark: UInt32,
            increasedContrastLight: UInt32? = nil,
            increasedContrastDark: UInt32? = nil
        ) -> Color {
            Color(uiColor: UIColor { traits in
                let isDark = traits.userInterfaceStyle == .dark
                let isIncreased = traits.accessibilityContrast == .high
                let value: UInt32
                switch (isDark, isIncreased) {
                case (false, false): value = light
                case (true, false): value = dark
                case (false, true): value = increasedContrastLight ?? light
                case (true, true): value = increasedContrastDark ?? dark
                }
                return UIColor(
                    red: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: 1
                )
            })
        }
    }

    /// Styles Dynamic Type uniquement (aucune taille fixe).
    enum Typography {
        /// Totaux du tableau des scores. Style de texte système direct (`.largeTitle`), sans
        /// `design: .rounded` : la police arrondie, recréée hors du style de texte, est la cause
        /// suspectée des « Dynamic Type partially unsupported » de l'audit sur le tableau (07).
        static var total: Font { .largeTitle.monospacedDigit().bold() }
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
