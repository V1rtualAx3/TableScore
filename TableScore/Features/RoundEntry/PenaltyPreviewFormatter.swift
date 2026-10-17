import Foundation
import TableScoreKit

/// Libellés français de l'aperçu d'une manche (docs/ux/lot2-parcours.md §3.2, cahier §4.4).
///
/// **Mise en forme uniquement** : la décision (doublé ou non, score retenu, joueurs ayant fait
/// moins ou égalité) provient toujours de `ScoreEngine` via `CloserVerdict` et `RoundScoring`.
/// Aucune multiplication, aucune comparaison de scores ici. Raisons du verdict : `VerdictText`.
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
        let reason = VerdictText.reason(for: verdict, nameOf: nameOf)
        let detail: String
        var spoken = "\(name) a terminé la manche\(VerdictText.nbsp): \(ScoreFormat.spoken(rawScore))"
        if verdict.isDoubled {
            detail = "\(raw) → \(ScoreFormat.display(effectiveScore)) (\(reason))"
            spoken += ", doublé à \(ScoreFormat.spoken(effectiveScore))"
        } else {
            detail = "\(raw) (\(reason))"
        }
        spoken += ". \(VerdictText.sentenceCase(reason))."
        return Description(text: "\(name)\(VerdictText.nbsp): \(detail)", detail: detail, spoken: spoken)
    }

    /// Évolution du total : « Total : 88 → 108 ».
    static func totalText(before: Int, after: Int) -> String {
        "Total\(VerdictText.nbsp): \(ScoreFormat.display(before)) → \(ScoreFormat.display(after))"
    }

    /// Lecture VoiceOver d'une ligne d'aperçu.
    static func spokenLine(
        name: String,
        roundScore: Int,
        totalAfter: Int,
        closer: Description?
    ) -> String {
        let total = "Total après la manche\(VerdictText.nbsp): \(ScoreFormat.spoken(totalAfter)) points."
        if let closer {
            return "\(closer.spoken) \(total)"
        }
        return "\(name)\(VerdictText.nbsp): \(ScoreFormat.spoken(roundScore)) points pour la manche. \(total)"
    }

    /// Message de l'alerte de fin anticipée (§4.6) ; `laterRoundIndices` triés, non vides.
    /// « Après cette correction, la partie se termine à la manche 6. Les manches 7 à 9 ont été
    /// jouées ensuite. »
    static func earlyEndMessage(endingRoundIndex: Int, laterRoundIndices: [Int]) -> String {
        let head = "Après cette correction, la partie se termine à la manche \(endingRoundIndex)."
        guard !laterRoundIndices.isEmpty else { return head }
        return head + " " + LaterRoundsText.playedAfterSentence(laterRoundIndices)
    }

    /// Bouton destructif de l'alerte de fin anticipée (accord au singulier pour une seule manche).
    static func deleteLaterRoundsTitle(count: Int) -> String {
        count == 1 ? "Supprimer la manche suivante" : "Supprimer les manches suivantes"
    }
}
