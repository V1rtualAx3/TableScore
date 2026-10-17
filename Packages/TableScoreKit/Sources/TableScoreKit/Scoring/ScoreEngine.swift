import Foundation

/// Moteur de score Skyjo classique : pur, déterministe, sans E/S ni état.
///
/// Source de vérité : participants + règles + manches (scores bruts et clôturant).
/// Toute donnée incohérente lève une `ValidationError` ; aucune arithmétique ne peut planter.
public enum ScoreEngine {

    // MARK: Validation

    public static func validate(rules: GameRules) throws(ValidationError) {
        guard GameRules.allowedTargetScores.contains(rules.targetScore) else {
            throw ValidationError.invalidTargetScore(rules.targetScore)
        }
    }

    /// Valide les participants et les renvoie triés par ordre d'affichage.
    @discardableResult
    public static func validate(participants: [Participant]) throws(ValidationError) -> [Participant] {
        guard Participant.allowedCount.contains(participants.count) else {
            throw ValidationError.participantCountOutOfRange(count: participants.count)
        }
        var ids = Set<UUID>()
        var orders = Set<Int>()
        for participant in participants {
            guard ids.insert(participant.id).inserted else {
                throw ValidationError.duplicateParticipantID(participant.id)
            }
            guard orders.insert(participant.displayOrder).inserted else {
                throw ValidationError.duplicateDisplayOrder(participant.displayOrder)
            }
            guard !participant.trimmedDisplayName.isEmpty else {
                throw ValidationError.emptyParticipantName(participantID: participant.id)
            }
        }
        return participants.sorted { $0.displayOrder < $1.displayOrder }
    }

    // MARK: Manche

    /// Calcule une manche isolée (utile pour la prévisualisation avant confirmation).
    public static func scoreRound(
        _ round: RoundInput,
        participants: [Participant],
        rules: GameRules
    ) throws(ValidationError) -> RoundScoring {
        try validate(rules: rules)
        let ordered = try validate(participants: participants)
        return try scoreValidatedRound(round, ordered: ordered, rules: rules)
    }

    /// Algorithme §3.2 : seuls les scores bruts de la manche sont comparés.
    /// Doublement si et seulement si brut du clôturant > 0 et un autre brut ≤ brut du clôturant.
    static func closerVerdict(
        closingParticipantID: UUID,
        closingRawScore: Int,
        rawScores: [ParticipantRoundScore],
        isPenaltyActive: Bool
    ) -> CloserVerdict {
        if closingRawScore == 0 { return .zeroNeverDoubled }
        if closingRawScore < 0 { return .negativeNeverDoubled }
        let others = rawScores.filter { $0.participantID != closingParticipantID }
        let lower = others.filter { $0.rawScore < closingRawScore }.map { $0.participantID }
        let tied = others.filter { $0.rawScore == closingRawScore }.map { $0.participantID }
        if lower.isEmpty && tied.isEmpty { return .soleLowest }
        guard isPenaltyActive else { return .penaltyDisabledByHouseRules }
        return .doubled(lowerParticipantIDs: lower, tiedParticipantIDs: tied)
    }

    /// Précondition : `ordered` validé et trié par ordre d'affichage.
    static func scoreValidatedRound(
        _ round: RoundInput,
        ordered: [Participant],
        rules: GameRules
    ) throws(ValidationError) -> RoundScoring {
        let memberIDs = Set(ordered.map { $0.id })
        var rawByID: [UUID: Int] = [:]
        for entry in round.entries {
            guard memberIDs.contains(entry.participantID) else {
                throw ValidationError.unknownParticipant(entry.participantID)
            }
            guard rawByID[entry.participantID] == nil else {
                throw ValidationError.duplicateEntry(participantID: entry.participantID)
            }
            try validateSource(of: entry)
            rawByID[entry.participantID] = entry.rawScore
        }

        // Tous les participants doivent être renseignés avant tout calcul (pas de score implicite).
        var rawScores: [ParticipantRoundScore] = []
        rawScores.reserveCapacity(ordered.count)
        for participant in ordered {
            guard let raw = rawByID[participant.id] else {
                throw ValidationError.missingEntry(participantID: participant.id)
            }
            rawScores.append(ParticipantRoundScore(
                participantID: participant.id,
                rawScore: raw,
                effectiveScore: raw,
                isClosing: participant.id == round.closingParticipantID
            ))
        }

        let closingID = round.closingParticipantID
        guard let closingRaw = rawByID[closingID] else {
            throw ValidationError.closingParticipantNotInGame(closingID)
        }

        let verdict = closerVerdict(
            closingParticipantID: closingID,
            closingRawScore: closingRaw,
            rawScores: rawScores,
            isPenaltyActive: rules.isCloserPenaltyActive
        )
        var closingEffective = closingRaw
        if verdict.isDoubled {
            let (doubled, overflow) = closingRaw.multipliedReportingOverflow(by: 2)
            guard !overflow else { throw ValidationError.arithmeticOverflow(participantID: closingID) }
            closingEffective = doubled
        }

        let scores = rawScores.map { score in
            ParticipantRoundScore(
                participantID: score.participantID,
                rawScore: score.rawScore,
                effectiveScore: score.isClosing ? closingEffective : score.rawScore,
                isClosing: score.isClosing
            )
        }
        return RoundScoring(
            roundID: round.id,
            index: round.index,
            closingParticipantID: closingID,
            closingRawScore: closingRaw,
            closingEffectiveScore: closingEffective,
            verdict: verdict,
            scores: scores
        )
    }

    /// Une saisie « cartes » doit avoir une grille complète cohérente avec le score brut.
    private static func validateSource(of entry: RoundEntry) throws(ValidationError) {
        guard case .cards(let grid) = entry.source else { return }
        guard let expected = grid.evaluate().rawScore else {
            throw ValidationError.incompleteCardGrid(participantID: entry.participantID)
        }
        guard expected == entry.rawScore else {
            throw ValidationError.cardGridScoreMismatch(
                participantID: entry.participantID,
                expected: expected,
                found: entry.rawScore
            )
        }
    }

    // MARK: Historique

    /// Recalcul intégral et déterministe de la partie à partir de toutes ses manches.
    ///
    /// Les manches sont ordonnées par indice ; les indices doivent être continus à partir de
    /// `RoundInput.firstIndex`. Une manche postérieure à la fin de partie est conservée et signalée
    /// via `inconsistency`, jamais supprimée.
    public static func computeGame(
        participants: [Participant],
        rounds: [RoundInput],
        rules: GameRules
    ) throws(ValidationError) -> GameComputation {
        try validate(rules: rules)
        let ordered = try validate(participants: participants)
        let sortedRounds = rounds.sorted { $0.index < $1.index }

        var totals: [UUID: Int] = [:]
        for participant in ordered { totals[participant.id] = 0 }

        var seenRoundIDs = Set<UUID>()
        var summaries: [RoundSummary] = []
        summaries.reserveCapacity(sortedRounds.count)
        var ending: (index: Int, totals: [UUID: Int])?
        var subsequentRoundIDs: [UUID] = []

        for (offset, round) in sortedRounds.enumerated() {
            let expectedIndex = RoundInput.firstIndex + offset
            guard round.index == expectedIndex else {
                throw ValidationError.roundIndexMismatch(expected: expectedIndex, found: round.index)
            }
            guard seenRoundIDs.insert(round.id).inserted else {
                throw ValidationError.duplicateRoundID(round.id)
            }

            // Tous les scores de la manche sont finalisés avant le cumul.
            let scoring = try scoreValidatedRound(round, ordered: ordered, rules: rules)
            for score in scoring.scores {
                let (sum, overflow) = (totals[score.participantID] ?? 0)
                    .addingReportingOverflow(score.effectiveScore)
                guard !overflow else {
                    throw ValidationError.arithmeticOverflow(participantID: score.participantID)
                }
                totals[score.participantID] = sum
            }

            let isAfterGameEnd = ending != nil
            if isAfterGameEnd { subsequentRoundIDs.append(round.id) }
            // Fin de partie évaluée après la manche complète : un cumul ≥ seuil suffit.
            let reachesTarget = totals.values.contains { $0 >= rules.targetScore }
            if reachesTarget && ending == nil { ending = (round.index, totals) }

            summaries.append(RoundSummary(
                scoring: scoring,
                totalsAfterRound: totals,
                reachesTargetScore: reachesTarget,
                isAfterGameEnd: isAfterGameEnd
            ))
        }

        let status: GameStatus
        var inconsistency: EarlyEndInconsistency?
        if let ending {
            status = .finished(roundIndex: ending.index, winnerIDs: lowestTotalIDs(ending.totals, ordered: ordered))
            if !subsequentRoundIDs.isEmpty {
                inconsistency = EarlyEndInconsistency(
                    endingRoundIndex: ending.index,
                    subsequentRoundIDs: subsequentRoundIDs
                )
            }
        } else {
            status = .inProgress
        }

        return GameComputation(
            rounds: summaries,
            totals: totals,
            standings: standings(totals, ordered: ordered),
            status: status,
            inconsistency: inconsistency
        )
    }

    /// Vérifie qu'une nouvelle manche peut être ajoutée puis renvoie le recalcul résultant
    /// (sert aussi de prévisualisation des cumuls à venir).
    ///
    /// Refuse : identifiant déjà présent (double soumission), partie terminée, indice non consécutif,
    /// ainsi que toute entrée invalide.
    public static func computeAppending(
        _ round: RoundInput,
        to rounds: [RoundInput],
        participants: [Participant],
        rules: GameRules
    ) throws(ValidationError) -> GameComputation {
        guard !containsRound(id: round.id, in: rounds) else {
            throw ValidationError.duplicateRoundID(round.id)
        }
        let current = try computeGame(participants: participants, rounds: rounds, rules: rules)
        if case .finished(let endingIndex, _) = current.status {
            throw ValidationError.gameAlreadyFinished(atRoundIndex: endingIndex)
        }
        guard round.index == current.nextRoundIndex else {
            throw ValidationError.roundIndexMismatch(expected: current.nextRoundIndex, found: round.index)
        }
        return try computeGame(participants: participants, rounds: rounds + [round], rules: rules)
    }

    /// Détection d'une manche déjà enregistrée (protection contre la double insertion).
    public static func containsRound(id: UUID, in rounds: [RoundInput]) -> Bool {
        rounds.contains { $0.id == id }
    }

    // MARK: Classement

    /// Tous les participants au plus petit cumul (co-vainqueurs, aucun départage inventé).
    static func lowestTotalIDs(_ totals: [UUID: Int], ordered: [Participant]) -> [UUID] {
        guard let minimum = totals.values.min() else { return [] }
        return ordered.filter { totals[$0.id] == minimum }.map { $0.id }
    }

    static func standings(_ totals: [UUID: Int], ordered: [Participant]) -> [Standing] {
        let sorted = ordered.enumerated().sorted { lhs, rhs in
            let lhsTotal = totals[lhs.element.id] ?? 0
            let rhsTotal = totals[rhs.element.id] ?? 0
            return lhsTotal != rhsTotal ? lhsTotal < rhsTotal : lhs.offset < rhs.offset
        }
        var result: [Standing] = []
        result.reserveCapacity(sorted.count)
        for (position, item) in sorted.enumerated() {
            let total = totals[item.element.id] ?? 0
            let rank: Int
            if let previous = result.last, previous.total == total {
                rank = previous.rank
            } else {
                rank = position + 1
            }
            result.append(Standing(participantID: item.element.id, total: total, rank: rank))
        }
        return result
    }
}
