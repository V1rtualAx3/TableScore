import Foundation
import TableScoreKit

/// Libellés français de l'aperçu d'une manche (docs/ux/lot2-parcours.md §3.2, cahier §4.4).
///
/// **Mise en forme uniquement** : la décision (doublé ou non, score retenu, joueurs ayant fait
/// moins ou égalité) provient toujours de `ScoreEngine` via `CloserVerdict` et `RoundScoring`.
/// Aucune multiplication, aucune comparaison de scores ici.
enum PenaltyPreviewFormatter {
    /// Texte visible et texte lu par VoiceOver (sans flèche, nombres négatifs lus « moins 3 »).
    struct Description: Equatable, Sendable {
        /// Libellé complet du cahier : « Alice : 10 → 20 (score doublé : égalité avec Chloé) ».
        let text: String
        /// Même libellé sans le prénom (affiché sous le nom dans la ligne d'aperçu).
        let detail: String
        let spoken: String
    }

    /// Libellé du clôturant à partir du verdict du moteur.
    ///
    /// - Doublé : « Bob a fait moins » est prioritaire sur l'égalité (cas mixte, §6 point 3).
    /// - `nameOf` fournit le prénom d'un participant (identifiants dans l'ordre d'affichage).
    static func closerDescription(
        name: String,
        rawScore: Int,
        effectiveScore: Int,
        verdict: CloserVerdict,
        nameOf: (UUID) -> String
    ) -> Description {
        let raw = ScoreFormat.display(rawScore)
        let spokenRaw = ScoreFormat.spoken(rawScore)
        let detail: String
        let spoken: String

        switch verdict {
        case .doubled(let lowerIDs, let tiedIDs):
            let reason = doublingReason(lowerIDs: lowerIDs, tiedIDs: tiedIDs, nameOf: nameOf)
            let effective = ScoreFormat.display(effectiveScore)
            detail = "\(raw) → \(effective) (score doublé : \(reason))"
            spoken = "\(name) a terminé la manche : \(spokenRaw), doublé à "
                + "\(ScoreFormat.spoken(effectiveScore)). Score doublé : \(reason)."
        case .soleLowest:
            detail = "\(raw) (seul plus petit score, pas de pénalité)"
            spoken = "\(name) a terminé la manche : \(spokenRaw). Seul plus petit score, pas de pénalité."
        case .zeroNeverDoubled:
            detail = "\(raw) (zéro n'est jamais doublé)"
            spoken = "\(name) a terminé la manche : \(spokenRaw). Zéro n'est jamais doublé."
        case .negativeNeverDoubled:
            detail = "\(raw) (score négatif, jamais doublé)"
            spoken = "\(name) a terminé la manche : \(spokenRaw). Score négatif, jamais doublé."
        case .penaltyDisabledByHouseRules:
            detail = "\(raw) (pas de doublement : règle maison)"
            spoken = "\(name) a terminé la manche : \(spokenRaw). Pas de doublement : règle maison."
        }
        return Description(text: "\(name) : \(detail)", detail: detail, spoken: spoken)
    }

    /// « Bob a fait moins », « Bob et Chloé ont fait moins », « égalité avec Chloé ».
    static func doublingReason(lowerIDs: [UUID], tiedIDs: [UUID], nameOf: (UUID) -> String) -> String {
        if !lowerIDs.isEmpty {
            let names = joinedNames(lowerIDs.map(nameOf))
            return lowerIDs.count == 1 ? "\(names) a fait moins" : "\(names) ont fait moins"
        }
        return "égalité avec \(joinedNames(tiedIDs.map(nameOf)))"
    }

    /// Liste française : « A », « A et B », « A, B et C ». Indépendante de la langue de l'appareil
    /// (les textes de l'app sont en français).
    static func joinedNames(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " et " + last
    }

    /// Évolution du total : « Total : 88 → 108 ».
    static func totalText(before: Int, after: Int) -> String {
        "Total : \(ScoreFormat.display(before)) → \(ScoreFormat.display(after))"
    }

    /// Lecture VoiceOver d'une ligne d'aperçu.
    static func spokenLine(
        name: String,
        roundScore: Int,
        totalAfter: Int,
        closer: Description?
    ) -> String {
        let total = "Total après la manche : \(ScoreFormat.spoken(totalAfter)) points."
        if let closer {
            return "\(closer.spoken) \(total)"
        }
        return "\(name) : \(ScoreFormat.spoken(roundScore)) points pour la manche. \(total)"
    }

    /// Message de l'alerte de fin anticipée (§4.6) ; `laterRoundIndices` triés, non vides.
    static func earlyEndMessage(endingRoundIndex: Int, laterRoundIndices: [Int]) -> String {
        let head = "Cette correction termine la partie à la manche \(endingRoundIndex)."
        guard let first = laterRoundIndices.first, let last = laterRoundIndices.last else { return head }
        if laterRoundIndices.count == 1 {
            return head + " La manche suivante (\(first)) devra être supprimée."
        }
        return head + " Les manches suivantes (\(first) à \(last)) devront être supprimées."
    }

    /// Bouton destructif de l'alerte de fin anticipée.
    static func deleteLaterRoundsTitle(count: Int) -> String {
        count == 1 ? "Supprimer la manche suivante" : "Supprimer les manches suivantes"
    }
}
