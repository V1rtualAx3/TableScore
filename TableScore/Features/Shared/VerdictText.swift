import Foundation
import TableScoreKit

/// Libellés français partagés (aperçu de saisie, historique, fin de partie) :
/// docs/ux/lot2-parcours.md §3.2.
///
/// **Mise en forme uniquement** : la décision (doublé ou non, joueurs ayant fait moins ou à
/// égalité) provient toujours de `ScoreEngine` via `CloserVerdict`. Aucune comparaison ici.
///
/// Typographie française : U+00A0 (espace insécable) avant « : », U+202F (fine insécable)
/// avant « ; ! ? ». Textes indépendants de la langue de l'appareil (application en français).
enum VerdictText {
    /// Espace insécable (avant « : » et à l'intérieur des guillemets).
    static let nbsp = "\u{00A0}"
    /// Espace fine insécable (avant « ; ! ? »).
    static let narrowNbsp = "\u{202F}"

    /// Raison du verdict, en minuscules :
    /// - « score doublé : Bob a fait moins » (prioritaire en cas mixte égalité + plus petit) ;
    /// - « score doublé : égalité avec Chloé » ;
    /// - « seul plus petit score, pas de pénalité » ;
    /// - « zéro n'est jamais doublé » ;
    /// - « score négatif, jamais doublé » ;
    /// - « pas de doublement : règle maison ».
    ///
    /// `nameOf` fournit le prénom d'un participant (identifiants dans l'ordre d'affichage).
    static func reason(for verdict: CloserVerdict, nameOf: (UUID) -> String) -> String {
        switch verdict {
        case .doubled(let lowerIDs, let tiedIDs):
            return "score doublé\(nbsp): " + doublingCause(lowerIDs: lowerIDs, tiedIDs: tiedIDs, nameOf: nameOf)
        case .soleLowest:
            return "seul plus petit score, pas de pénalité"
        case .zeroNeverDoubled:
            return "zéro n'est jamais doublé"
        case .negativeNeverDoubled:
            return "score négatif, jamais doublé"
        case .penaltyDisabledByHouseRules:
            return "pas de doublement\(nbsp): règle maison"
        }
    }

    /// « Bob a fait moins », « Bob et Chloé ont fait moins », « égalité avec Chloé ».
    static func doublingCause(lowerIDs: [UUID], tiedIDs: [UUID], nameOf: (UUID) -> String) -> String {
        if !lowerIDs.isEmpty {
            let names = frenchList(lowerIDs.map(nameOf))
            return lowerIDs.count == 1 ? "\(names) a fait moins" : "\(names) ont fait moins"
        }
        return "égalité avec \(frenchList(tiedIDs.map(nameOf)))"
    }

    /// « Alice », « Alice et Bob », « Alice, Bob et Chloé » ; liste vide ⇒ chaîne vide.
    static func frenchList(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " et " + last
    }

    /// Complément du nom avec élision : « d'Alice », « d'Élodie », « de Bob ».
    /// Élision seulement devant une voyelle (un « h » initial garde « de », faute de savoir s'il
    /// est muet ou aspiré).
    static func ofName(_ name: String) -> String {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y", "œ", "æ"]
        let initial = name.first
            .map { String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
            .flatMap(\.first)
        if let initial, vowels.contains(initial) {
            return "d'\(name)"
        }
        return "de \(name)"
    }

    /// Première lettre en majuscule (début de phrase), le reste inchangé.
    static func sentenceCase(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Libellés des manches jouées après la fin de partie (§4.6), communs à l'historique et à la
/// saisie. `indices` : indices de manche triés, contigus, non vides (garanti par le moteur).
enum LaterRoundsText {
    /// « la manche 3 », « les manches 3 et 4 », « les manches 3 à 5 ».
    static func range(_ indices: [Int]) -> String {
        guard let first = indices.first, let last = indices.last else { return "" }
        switch indices.count {
        case 1: return "la manche \(first)"
        case 2: return "les manches \(first) et \(last)"
        default: return "les manches \(first) à \(last)"
        }
    }

    /// « La manche 3 a été jouée ensuite. » / « Les manches 3 à 5 ont été jouées ensuite. »
    static func playedAfterSentence(_ indices: [Int]) -> String {
        let verb = indices.count > 1 ? "ont été jouées" : "a été jouée"
        return VerdictText.sentenceCase(range(indices)) + " \(verb) ensuite."
    }

    /// Seconde confirmation : « Supprimer définitivement 3 manches ? » /
    /// « Supprimer définitivement la manche 3 ? ».
    static func deletionTitle(_ indices: [Int]) -> String {
        let object = indices.count > 1 ? "\(indices.count) manches" : range(indices)
        return "Supprimer définitivement \(object)\(VerdictText.narrowNbsp)?"
    }

    /// « Les manches 3 et 4 seront effacées. Cette action ne peut pas être annulée. »
    static func deletionMessage(_ indices: [Int]) -> String {
        let verb = indices.count > 1 ? "seront effacées" : "sera effacée"
        return VerdictText.sentenceCase(range(indices)) + " \(verb). Cette action ne peut pas être annulée."
    }

    /// Bouton destructif de la seconde confirmation : « Supprimer 3 manches » / « Supprimer la manche 3 ».
    static func deletionButton(_ indices: [Int]) -> String {
        indices.count > 1 ? "Supprimer \(indices.count) manches" : "Supprimer \(range(indices))"
    }
}

/// Messages communs à la correction d'une manche (historique et feuille de saisie).
enum CorrectionText {
    /// Une partie terminée ne peut être rouverte pour correction que si aucune autre n'est en cours.
    static let anotherGameActive =
        "Une autre partie est en cours. Terminez-la ou abandonnez-la avant de corriger celle-ci."
}
