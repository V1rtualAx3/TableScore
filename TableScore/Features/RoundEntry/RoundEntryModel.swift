import Foundation
import Observation
import TableScoreKit

/// État de la feuille « Ajouter / corriger une manche » (docs/ux/lot2-parcours.md §2.4, §2.5).
///
/// Ne contient **aucune règle de score** : validation et conversion via `RoundDraft`, score
/// retenu, verdict du clôturant, cumuls et fin de partie via `ScoreEngine`. Le modèle ne garde que
/// les textes saisis, la sélection et des états de présentation ; la source de vérité reste le dépôt.
///
/// Mode « Cartes » (cahier §3.3, P1) : choisi **par joueur** (sélecteur « Points | Cartes » de sa
/// ligne). La grille et le score « points » vivent tous deux dans le `DraftEntry` du Kit : basculer
/// ne perd rien, le pré-remplissage cartes → points est la règle du Kit (jamais d'écrasement d'une
/// saisie manuelle). Total de la grille, triplets et colonnes retirées : `CardGrid.evaluate()`.
///
/// Idempotence : l'identifiant de manche (`RoundDraft.roundID`) est fixé à l'ouverture de la
/// feuille et réutilisé à chaque tentative ; une nouvelle tentative après un succès inaperçu
/// donne `.alreadySaved`, traité comme un succès silencieux.
@Observable
@MainActor
final class RoundEntryModel {
    // MARK: Types

    enum LoadState: Equatable {
        case loaded
        case failed(message: String)
    }

    /// Analyse d'un champ de score (affichage) ; la valeur vient de `RoundDraft.parseScore`.
    enum FieldStatus: Equatable, Sendable {
        case empty
        /// Seulement un signe (« − ») : saisie en cours, non valide.
        case signOnly
        case value(Int)
        /// Valeur valide mais inhabituelle : avertissement non bloquant.
        case unusual(Int)
        case invalid

        var parsedValue: Int? {
            switch self {
            case .value(let value), .unusual(let value): value
            case .empty, .signOnly, .invalid: nil
            }
        }
    }

    struct Field: Identifiable, Equatable {
        let participantID: UUID
        /// Rang 0-based dans l'ordre d'affichage (identifiants d'accessibilité).
        let position: Int
        let name: String
        var text: String
        var status: FieldStatus
        /// Mode de saisie du joueur (reflet de `DraftEntry.inputMethod`, mis à jour avec lui).
        var inputMethod: InputMethod = .points
        /// Information affichée après une bascule cartes → points (grille incomplète, ou total des
        /// cartes différent d'un score saisi à la main et conservé). Jamais bloquante, rien n'est effacé.
        var cardsNotice: String?

        var id: UUID { participantID }

        /// Le texte commence par un signe moins (libellé du bouton « ± »).
        var isNegative: Bool {
            guard let first = text.trimmingCharacters(in: .whitespaces).first else { return false }
            return RoundEntryModel.minusSigns.contains(first)
        }

        /// Message affiché sous le champ (erreur ou avertissement) ; mode « points » seulement.
        var message: String? {
            guard inputMethod == .points else { return nil }
            switch status {
            case .invalid:
                "Nombre entier attendu"
            case .unusual:
                "Score inhabituel\u{00A0}: vérifiez la saisie (habituellement entre "
                    + "\(ScoreFormat.display(RoundEntryModel.usualScores.lowerBound)) et "
                    + "\(ScoreFormat.display(RoundEntryModel.usualScores.upperBound)))."
            case .empty, .signOnly, .value:
                nil
            }
        }

        var isError: Bool { inputMethod == .points && status == .invalid }

        /// Valeur VoiceOver du champ : « vide », « moins 3 »…
        var spokenValue: String {
            switch status {
            case .empty: "vide"
            case .signOnly: "moins"
            case .value(let value), .unusual(let value): ScoreFormat.spoken(value)
            case .invalid: text
            }
        }
    }

    struct PreviewLine: Identifiable, Equatable {
        let participantID: UUID
        let position: Int
        let name: String
        let isCloser: Bool
        let isDoubled: Bool
        /// Score retenu pour la manche (fourni par le moteur).
        let roundScore: Int
        let totalBefore: Int
        let totalAfter: Int
        /// Libellé de pénalité, pour le clôturant uniquement.
        let closerDescription: PenaltyPreviewFormatter.Description?

        var id: UUID { participantID }

        var totalText: String {
            PenaltyPreviewFormatter.totalText(before: totalBefore, after: totalAfter)
        }

        var spokenSummary: String {
            PenaltyPreviewFormatter.spokenLine(
                name: name,
                roundScore: roundScore,
                totalAfter: totalAfter,
                closer: closerDescription
            )
        }
    }

    struct RoundPreview: Equatable {
        let lines: [PreviewLine]
        let targetScore: Int
        /// La partie se termine à l'issue de cette manche (statut calculé par le moteur).
        let endsGameAtThisRound: Bool
        /// Correction d'une manche qui n'est pas la dernière.
        let recomputesLaterRounds: Bool
        /// Correction révélant une fin anticipée : manche de fin (décision demandée à l'enregistrement).
        let earlyEndRoundIndex: Int?
    }

    struct EarlyEndDecision: Equatable, Sendable {
        let endingRoundIndex: Int
        let laterRoundIDs: [UUID]
        let laterRoundIndices: [Int]

        var message: String {
            PenaltyPreviewFormatter.earlyEndMessage(
                endingRoundIndex: endingRoundIndex,
                laterRoundIndices: laterRoundIndices
            )
        }

        var confirmTitle: String {
            PenaltyPreviewFormatter.deleteLaterRoundsTitle(count: laterRoundIDs.count)
        }

        /// Seconde confirmation (comme dans l'historique) : « Supprimer définitivement 3 manches ? ».
        var finalConfirmationTitle: String { LaterRoundsText.deletionTitle(laterRoundIndices) }
        var finalConfirmationMessage: String { LaterRoundsText.deletionMessage(laterRoundIndices) }
        var finalConfirmationButtonTitle: String { LaterRoundsText.deletionButton(laterRoundIndices) }
    }

    /// Décision explicite demandée avant toute écriture (docs/ux/lot2-parcours.md §2.5).
    enum Decision: Equatable, Sendable {
        /// §4.6 : la correction termine la partie plus tôt ; manches postérieures à supprimer.
        /// Le choix destructif mène à une **seconde** confirmation (`pendingDeletionConfirmation`).
        case deleteLaterRounds(EarlyEndDecision)
        /// La partie était terminée ; après correction, plus personne n'atteint le seuil.
        case gameResumes(targetScore: Int)

        var title: String {
            switch self {
            case .deleteLaterRounds: "La partie aurait dû se terminer"
            case .gameResumes: "La partie reprend"
            }
        }

        var message: String {
            switch self {
            case .deleteLaterRounds(let decision):
                decision.message
            case .gameResumes(let targetScore):
                "Plus aucun joueur n'atteint \(targetScore) points\u{00A0}: la partie reprend."
            }
        }

        var confirmTitle: String {
            switch self {
            case .deleteLaterRounds(let decision): decision.confirmTitle
            case .gameResumes: "Enregistrer la correction"
            }
        }

        /// Annule la décision : rien n'est écrit, la saisie est conservée.
        var cancelTitle: String { "Revenir à la saisie" }

        var isDestructive: Bool {
            if case .deleteLaterRounds = self { return true }
            return false
        }
    }

    enum SaveOutcome: Equatable {
        /// Enregistré (ou déjà enregistré / correction identique) : la feuille peut se fermer.
        case saved
        /// Rien n'a été écrit : `pendingDecision` attend un choix explicite.
        case needsDecision
        /// Échec : `saveErrorMessage` renseigné, saisie conservée.
        case failed
        /// Appel ignoré (saisie incomplète, enregistrement en cours ou déjà terminé).
        case ignored
    }

    // MARK: Constantes de présentation

    /// Signes moins acceptés en tête (mêmes que `RoundDraft.parseScore`).
    nonisolated static let minusSigns: Set<Character> = ["-", "\u{2212}", "\u{2013}", "\u{FF0D}"]
    nonisolated static let signCharacters: Set<Character> = minusSigns.union(["+"])

    /// Plage habituelle d'un score brut saisi (12 cartes de −2 à 12) : **simple avertissement**
    /// contre les fautes de frappe, jamais un refus (pas une règle officielle). Dérivée des
    /// constantes du Kit, sans valeur recopiée.
    nonisolated static let usualScores: ClosedRange<Int> = {
        let cardCount = CardGrid.columnCount * CardGrid.rowCount
        return (CardGrid.cardValues.lowerBound * cardCount)...(CardGrid.cardValues.upperBound * cardCount)
    }()

    // MARK: État

    let gameID: UUID
    let mode: RoundEntryMode
    private let repository: any GameRepository

    private(set) var loadState: LoadState = .loaded
    private(set) var fields: [Field] = []
    private(set) var closerID: UUID?
    private(set) var preview: RoundPreview?
    /// Raisons détaillées qui empêchent l'enregistrement (vide ⇒ enregistrable).
    private(set) var blockingReasons: [String] = []
    /// Résumé court affiché au-dessus du bouton (lisible avec le clavier ouvert).
    private(set) var blockingSummary: String?
    /// Version détaillée pour VoiceOver : « Il manque : score de Bob, score de Chloé… ».
    private(set) var blockingHint: String?
    private(set) var isSaving = false
    /// Enregistrement terminé : la vue ferme la feuille.
    private(set) var isCompleted = false
    /// Le dépôt a été modifié pendant la session (rechargement des écrans nécessaire).
    private(set) var hasWrittenData = false
    private(set) var saveErrorMessage: String?
    private(set) var pendingDecision: Decision?
    /// Seconde confirmation de la suppression des manches postérieures (après `confirm`).
    private(set) var pendingDeletionConfirmation: EarlyEndDecision?

    private var game: SavedGame?
    private var draft: RoundDraft?
    /// Brouillon à l'ouverture (modes et grilles initiaux, pour `isDirty`).
    private var initialDraft: RoundDraft?
    private var initialTexts: [UUID: String] = [:]
    private var initialCloserID: UUID?
    /// Manches dont la suppression a été confirmée pour la saisie courante.
    private var confirmedLaterRoundIDs: Set<UUID>?
    private var confirmedResume = false
    /// Partie `finished` rouverte par cette feuille pour l'enregistrement et pas encore rétablie
    /// (« terminée ») : seul état intermédiaire possible, résorbé dès que possible.
    private var reopenedFinishedGame = false
    /// Correction d'une partie terminée impossible : une autre partie est en cours (lu au chargement).
    private var anotherGameIsActive = false

    init(gameID: UUID, mode: RoundEntryMode, repository: any GameRepository) {
        self.gameID = gameID
        self.mode = mode
        self.repository = repository
        load()
    }

    // MARK: Lecture

    var isEditing: Bool { mode != .new }

    /// Identifiant de la manche saisie, stable pendant toute la vie de la feuille.
    var roundID: UUID? { draft?.roundID }
    var roundIndex: Int? { draft?.index }

    var title: String {
        guard let index = roundIndex else { return isEditing ? "Correction" : "Manche" }
        return isEditing ? "Correction de la manche \(index)" : "Manche \(index)"
    }

    var saveTitle: String {
        isEditing ? "Enregistrer la correction" : "Enregistrer la manche"
    }

    var canSave: Bool {
        loadState == .loaded && draft != nil && blockingReasons.isEmpty && preview != nil
            && !isSaving && !isCompleted
    }

    /// Ligne courte du clôturant, affichée au-dessus du bouton dès que la saisie est complète :
    /// « Alice : 10 → 20 (score doublé : égalité avec Chloé) » (libellé du moteur, cf. aperçu).
    var closerPreviewLine: PreviewLine? {
        preview?.lines.first { $0.isCloser && $0.closerDescription != nil }
    }

    /// Vrai tant qu'une partie terminée, rouverte pour enregistrer, n'a pas retrouvé son statut :
    /// la feuille ne doit pas pouvoir être fermée par glissement sans ce rétablissement.
    var needsLifecycleRestore: Bool { reopenedFinishedGame }

    /// Saisie modifiée depuis l'ouverture (confirmation avant abandon) : textes, clôturant, mode de
    /// saisie ou grille de cartes.
    var isDirty: Bool {
        if closerID != initialCloserID { return true }
        if fields.contains(where: { $0.text != (initialTexts[$0.participantID] ?? "") }) { return true }
        guard let draft, let initialDraft else { return false }
        return draft.participantIDs.contains { participantID in
            let current = draft.entry(for: participantID)
            let initial = initialDraft.entry(for: participantID)
            return current?.inputMethod != initial?.inputMethod || current?.cardGrid != initial?.cardGrid
        }
    }

    /// Grille de cartes du joueur (brouillon du Kit) ; grille vide si le joueur est inconnu.
    func cardGrid(for participantID: UUID) -> CardGrid {
        draft?.entry(for: participantID)?.cardGrid ?? CardGrid()
    }

    /// Recharge la partie après un échec de lecture (jamais après le chargement réussi : le
    /// brouillon et son identifiant doivent rester stables).
    func retryLoad() {
        guard draft == nil else { return }
        load()
    }

    // MARK: Saisie

    /// Texte saisi tel quel (ce qui est affiché est ce qui est analysé) ; l'analyse est celle du Kit.
    func setText(_ text: String, for participantID: UUID) {
        guard !isCompleted, !isSaving,
              let position = fields.firstIndex(where: { $0.participantID == participantID }),
              fields[position].text != text
        else { return }
        let status = Self.status(for: text)
        fields[position].text = text
        fields[position].status = status
        // Saisie manuelle : l'information de bascule n'a plus lieu d'être.
        fields[position].cardsNotice = nil
        // Une entrée « cartes » corrigée à la main passe en saisie « points ».
        if draft?.entry(for: participantID)?.inputMethod != .points {
            draft?.setInputMethod(.points, for: participantID)
            fields[position].inputMethod = .points
        }
        draft?.setPoints(status.parsedValue, for: participantID)
        draftDidChange()
    }

    /// Sélecteur « Points | Cartes » d'un joueur. Rien n'est perdu : points et grille restent dans
    /// le brouillon. Cartes → points : le Kit pré-remplit le score avec le total d'une grille
    /// complète (champ vide ou déjà issu de la grille) ; sinon une information est affichée sous le
    /// champ, sans rien effacer. Renvoie cette information (annonce VoiceOver), `nil` sinon.
    @discardableResult
    func setInputMethod(_ inputMethod: InputMethod, for participantID: UUID) -> String? {
        guard !isCompleted, !isSaving,
              let position = fields.firstIndex(where: { $0.participantID == participantID }),
              let current = draft?.entry(for: participantID),
              current.inputMethod != inputMethod
        else { return nil }
        draft?.setInputMethod(inputMethod, for: participantID)
        fields[position].inputMethod = inputMethod
        fields[position].cardsNotice = nil
        if inputMethod == .points, let updated = draft?.entry(for: participantID) {
            // Texte affiché = score du brouillon (pré-rempli par le Kit) ; une saisie manuelle,
            // même invalide, n'est remplacée que si le Kit a effectivement pré-rempli.
            if updated.isPointsDerivedFromGrid, let points = updated.points,
               fields[position].status.parsedValue != points {
                let text = ScoreFormat.display(points)
                fields[position].text = text
                fields[position].status = Self.status(for: text)
            }
            fields[position].cardsNotice = Self.cardsNotice(for: updated)
        }
        draftDidChange()
        return fields[position].cardsNotice
    }

    /// Nouvelle grille d'un joueur en mode « Cartes » (liaison de `CardGridEditor`). Ignorée en
    /// mode « Points » : la saisie points ne soustrait jamais de colonnes.
    func setCardGrid(_ grid: CardGrid, for participantID: UUID) {
        guard !isCompleted, !isSaving,
              let current = draft?.entry(for: participantID),
              current.inputMethod == .cards,
              current.cardGrid != grid
        else { return }
        draft?.updateEntry(for: participantID) { $0.cardGrid = grid }
        draftDidChange()
    }

    /// Bouton « ± » : ajoute ou retire le signe moins ; sur un champ vide, prépare « − ».
    func toggleSign(for participantID: UUID) {
        guard let field = fields.first(where: { $0.participantID == participantID }) else { return }
        let trimmed = field.text.trimmingCharacters(in: .whitespaces)
        let newText: String
        if let first = trimmed.first, Self.signCharacters.contains(first) {
            let digits = String(trimmed.dropFirst().drop { $0.isWhitespace })
            newText = Self.minusSigns.contains(first) ? digits : ScoreFormat.minusSign + digits
        } else {
            newText = ScoreFormat.minusSign + trimmed
        }
        setText(newText, for: participantID)
    }

    /// Clôturant unique : choisir un joueur remplace le précédent ; jamais de désélection.
    func selectCloser(_ participantID: UUID) {
        guard !isCompleted, !isSaving, closerID != participantID,
              fields.contains(where: { $0.participantID == participantID })
        else { return }
        closerID = participantID
        draft?.closingParticipantID = participantID
        draftDidChange()
    }

    // MARK: Enregistrement

    /// Enregistre la manche (ajout) ou la correction. Synchrone : le dépôt est local et atomique.
    ///
    /// Une décision encore en attente (alerte ou seconde confirmation non affichée, ou fermée sans
    /// passer par ses boutons) ne bloque jamais l'enregistrement : elle est abandonnée et, si elle
    /// est toujours nécessaire, redemandée par ce nouvel appel (rien n'a été écrit entre-temps).
    @discardableResult
    func save() -> SaveOutcome {
        guard !isSaving, !isCompleted, canSave,
              let game, let draft,
              let input = try? draft.makeRoundInput()
        else { return .ignored }
        pendingDecision = nil
        pendingDeletionConfirmation = nil
        isSaving = true
        defer { isSaving = false }
        saveErrorMessage = nil
        switch mode {
        case .new:
            return append(input)
        case .edit:
            return replace(input, in: game)
        }
    }

    /// Choix explicite de l'utilisateur dans l'alerte de décision.
    ///
    /// - `.gameResumes` : enregistre la correction.
    /// - `.deleteLaterRounds` : **aucune écriture** ; demande la seconde confirmation
    ///   (`pendingDeletionConfirmation`, renvoie `.needsDecision`).
    @discardableResult
    func confirm(_ decision: Decision) -> SaveOutcome {
        pendingDecision = nil
        switch decision {
        case .deleteLaterRounds(let earlyEnd):
            pendingDeletionConfirmation = earlyEnd
            return .needsDecision
        case .gameResumes:
            confirmedResume = true
            return save()
        }
    }

    /// Seconde confirmation « Supprimer définitivement… » : correction + suppression des manches
    /// confirmées en une seule transaction (identifiants revérifiés par le dépôt).
    ///
    /// Le paramètre est la décision affichée (et non l'état courant) : la fermeture de la boîte
    /// de dialogue peut remettre `pendingDeletionConfirmation` à `nil` avant cet appel.
    @discardableResult
    func confirmLaterRoundsDeletion(_ earlyEnd: EarlyEndDecision) -> SaveOutcome {
        pendingDeletionConfirmation = nil
        confirmedLaterRoundIDs = Set(earlyEnd.laterRoundIDs)
        return save()
    }

    /// « Revenir à la saisie » (alerte) : rien n'est écrit, saisie conservée.
    func dismissDecision() {
        pendingDecision = nil
    }

    /// « Annuler » (seconde confirmation) : rien n'est écrit, saisie conservée.
    func cancelLaterRoundsDeletion() {
        pendingDeletionConfirmation = nil
    }

    func dismissSaveError() {
        saveErrorMessage = nil
    }

    /// À appeler avant de fermer la feuille (bouton, glissement ou fin d'enregistrement).
    /// Filet de sécurité : si une partie terminée, rouverte pour enregistrer, n'a pas pu retrouver
    /// son statut (double échec d'écriture), une dernière tentative est faite.
    /// Renvoie vrai si le dépôt a été modifié pendant la session (les écrans doivent se recharger).
    func prepareForDismissal() -> Bool {
        restoreLifecycleIfNeeded()
        return hasWrittenData
    }

    /// Rétablit le statut « terminée » d'une partie rouverte par cette feuille si le moteur la
    /// considère toujours terminée. Renvoie vrai si une écriture a eu lieu. En cas d'échec, l'état
    /// reste valide et sans perte (partie simplement active, visible à l'accueil) ; la fermeture
    /// de la feuille n'est jamais bloquée.
    @discardableResult
    func restoreLifecycleIfNeeded() -> Bool {
        guard reopenedFinishedGame else { return false }
        do {
            let current = try repository.game(id: gameID)
            guard current.lifecycle == .active, current.isOver else {
                // Déjà rétablie, ou reprise confirmée et enregistrée : la partie reste telle quelle.
                reopenedFinishedGame = false
                return false
            }
            game = try repository.finishGame(id: gameID)
            reopenedFinishedGame = false
            hasWrittenData = true
            return true
        } catch {
            return false
        }
    }

    // MARK: Chargement

    private func load() {
        do {
            let loaded = try repository.game(id: gameID)
            let newDraft: RoundDraft
            switch mode {
            case .new:
                newDraft = RoundDraft(index: loaded.computation.nextRoundIndex, participants: loaded.participants)
            case .edit(let roundID):
                guard let round = loaded.rounds.first(where: { $0.id == roundID }) else {
                    loadState = .failed(message: "Cette manche n'existe plus.")
                    return
                }
                newDraft = RoundDraft(editing: round, participants: loaded.participants)
            }
            let participantsByID = Dictionary(
                loaded.participants.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var newFields: [Field] = []
            for (position, participantID) in newDraft.participantIDs.enumerated() {
                let entry = newDraft.entry(for: participantID)
                let text = entry?.rawScore.map(ScoreFormat.display) ?? ""
                newFields.append(Field(
                    participantID: participantID,
                    position: position,
                    name: participantsByID[participantID]?.displayName ?? "",
                    text: text,
                    status: Self.status(for: text),
                    inputMethod: entry?.inputMethod ?? .points
                ))
            }
            if case .edit = mode, loaded.lifecycle == .finished {
                // Lecture seule : la réouverture à l'enregistrement serait refusée. Une erreur de
                // lecture ici n'empêche pas la saisie (l'enregistrement la signalerait).
                if let active = try? repository.activeGame() {
                    anotherGameIsActive = active.id != loaded.id
                } else {
                    anotherGameIsActive = false
                }
            }
            game = loaded
            draft = newDraft
            initialDraft = newDraft
            fields = newFields
            closerID = newDraft.closingParticipantID
            initialTexts = Dictionary(
                newFields.map { ($0.participantID, $0.text) },
                uniquingKeysWith: { first, _ in first }
            )
            initialCloserID = newDraft.closingParticipantID
            loadState = .loaded
            refreshDerivedState()
        } catch {
            loadState = .failed(message: GameRepositoryError.from(error, operation: .read).userFacingMessage)
        }
    }

    // MARK: Dérivés (calculés par le Kit)

    private func draftDidChange() {
        // Toute modification invalide une décision donnée pour une saisie précédente.
        confirmedLaterRoundIDs = nil
        confirmedResume = false
        refreshDerivedState()
    }

    private func refreshDerivedState() {
        guard let game, let draft else {
            preview = nil
            setBlocking([], summary: nil, hint: nil)
            return
        }

        if let lifecycleMessage = lifecycleBlockingMessage(for: game) {
            preview = nil
            setBlocking([lifecycleMessage], summary: lifecycleMessage, hint: lifecycleMessage)
            return
        }

        var reasons: [String] = []
        var summaryItems: [String] = []
        let missing = Set(draft.missingScoreParticipantIDs)
        let missingFields = fields.filter { missing.contains($0.participantID) }
        // Mode « cartes » : grille incomplète (le texte du champ points n'est pas utilisé).
        let invalidFields = missingFields.filter { $0.inputMethod == .points && $0.status == .invalid }
        let emptyFields = missingFields.filter { $0.inputMethod == .cards || $0.status != .invalid }
        for field in missingFields {
            if field.inputMethod == .cards {
                let missingCards = draft.entry(for: field.participantID)?.cardGrid.evaluate().missingCardCount ?? 0
                reasons.append("\(Self.cardsItem(field.name)) (\(Self.missingCardsText(missingCards)))")
            } else if field.status == .invalid {
                reasons.append("score \(VerdictText.ofName(field.name)) à corriger")
            } else {
                reasons.append("score \(VerdictText.ofName(field.name))")
            }
        }
        // Résumé court : au-delà de deux joueurs, un décompte plutôt qu'une liste de prénoms.
        if emptyFields.count > 2 {
            summaryItems.append("\(emptyFields.count) scores")
        } else {
            summaryItems += emptyFields.map { (field: Field) -> String in
                if field.inputMethod == .cards { return Self.cardsItem(field.name) }
                return "score \(VerdictText.ofName(field.name))"
            }
        }
        if invalidFields.count > 2 {
            summaryItems.append("\(invalidFields.count) scores à corriger")
        } else {
            summaryItems += invalidFields.map { "score \(VerdictText.ofName($0.name)) à corriger" }
        }
        if draft.closingParticipantID == nil {
            reasons.append("qui a terminé la manche")
            summaryItems.append("qui a terminé la manche")
        }

        guard reasons.isEmpty else {
            preview = nil
            setBlocking(
                reasons,
                summary: "À compléter\u{00A0}: " + summaryItems.joined(separator: ", ") + ".",
                hint: "Il manque\u{00A0}: " + reasons.joined(separator: ", ") + "."
            )
            return
        }

        do {
            let input = try draft.makeRoundInput()
            preview = try makePreview(for: input, in: game)
            setBlocking([], summary: nil, hint: nil)
        } catch {
            let message = Self.blockingMessage(for: error)
            preview = nil
            setBlocking([message], summary: message, hint: message)
        }
    }

    private func setBlocking(_ reasons: [String], summary: String?, hint: String?) {
        blockingReasons = reasons
        blockingSummary = summary
        blockingHint = hint
    }

    private func lifecycleBlockingMessage(for game: SavedGame) -> String? {
        switch (mode, game.lifecycle) {
        case (.edit, .finished) where anotherGameIsActive:
            CorrectionText.anotherGameActive
        case (.new, .active), (.edit, .active), (.edit, .finished):
            nil
        case (.new, _), (.edit, .archived):
            GameRepositoryError.gameNotActive(id: game.id, lifecycle: game.lifecycle).userFacingMessage
        }
    }

    /// Aperçu calculé par le moteur : manche ajoutée (`computeAppending`) ou corrigée
    /// (`computeReplacing`), avec les cumuls avant/après la manche.
    private func makePreview(for input: RoundInput, in game: SavedGame) throws(ValidationError) -> RoundPreview? {
        let computation: GameComputation
        switch mode {
        case .new:
            computation = try ScoreEngine.computeAppending(
                input,
                to: game.rounds,
                participants: game.participants,
                rules: game.rules
            )
        case .edit:
            computation = try ScoreEngine.computeReplacing(
                input,
                in: game.rounds,
                participants: game.participants,
                rules: game.rules
            )
        }
        guard let roundPosition = computation.rounds.firstIndex(where: { $0.scoring.roundID == input.id }) else {
            return nil
        }
        let summary = computation.rounds[roundPosition]
        let totalsBefore = roundPosition > 0 ? computation.rounds[roundPosition - 1].totalsAfterRound : [:]
        let names = Dictionary(
            fields.map { ($0.participantID, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let scoring = summary.scoring

        let lines = fields.compactMap { field -> PreviewLine? in
            guard let score = scoring.score(for: field.participantID) else { return nil }
            var description: PenaltyPreviewFormatter.Description?
            if score.isClosing {
                description = PenaltyPreviewFormatter.closerDescription(
                    name: field.name,
                    rawScore: scoring.closingRawScore,
                    effectiveScore: scoring.closingEffectiveScore,
                    verdict: scoring.verdict,
                    nameOf: { names[$0] ?? "" }
                )
            }
            return PreviewLine(
                participantID: field.participantID,
                position: field.position,
                name: field.name,
                isCloser: score.isClosing,
                isDoubled: score.isClosing && scoring.verdict.isDoubled,
                roundScore: score.effectiveScore,
                totalBefore: totalsBefore[field.participantID] ?? 0,
                totalAfter: summary.totalsAfterRound[field.participantID] ?? 0,
                closerDescription: description
            )
        }

        var endsGameAtThisRound = false
        if case .finished(let endingIndex, _) = computation.status {
            endsGameAtThisRound = endingIndex == input.index
        }
        return RoundPreview(
            lines: lines,
            targetScore: game.rules.targetScore,
            endsGameAtThisRound: endsGameAtThisRound,
            recomputesLaterRounds: isEditing && roundPosition < computation.rounds.count - 1,
            earlyEndRoundIndex: computation.inconsistency?.endingRoundIndex
        )
    }

    // MARK: Écriture

    private func append(_ input: RoundInput) -> SaveOutcome {
        do {
            let outcome = try repository.appendRound(input, toGame: gameID)
            // `.alreadySaved` : même identifiant, même contenu (tentative précédente aboutie).
            hasWrittenData = true
            game = outcome.game
            complete()
            return .saved
        } catch {
            saveErrorMessage = GameRepositoryError.from(error, operation: .write).userFacingMessage
            return .failed
        }
    }

    private func replace(_ input: RoundInput, in game: SavedGame) -> SaveOutcome {
        // Correction identique : rien à écrire (ni réouverture de la partie).
        if game.rounds.contains(game.normalized(input)) {
            complete()
            return .saved
        }

        // Pré-contrôle **pur** (Kit) avant toute écriture, y compris la réouverture d'une partie
        // terminée : aucune décision ne doit être demandée après un effet de bord.
        let computation: GameComputation
        do {
            computation = try ScoreEngine.computeReplacing(
                input,
                in: game.rounds,
                participants: game.participants,
                rules: game.rules
            )
        } catch {
            saveErrorMessage = GameRepositoryError.from(error, operation: .write).userFacingMessage
            return .failed
        }

        var resolution = EarlyEndResolution.rejectIfEarlyEnd
        if let inconsistency = computation.inconsistency {
            let laterIDs = inconsistency.subsequentRoundIDs
            guard confirmedLaterRoundIDs == Set(laterIDs) else {
                pendingDecision = .deleteLaterRounds(Self.earlyEndDecision(inconsistency, in: computation))
                return .needsDecision
            }
            resolution = .deleteRoundsAfterEarlyEnd(confirmedRoundIDs: laterIDs)
        } else if game.isOver, computation.status == .inProgress, !confirmedResume {
            pendingDecision = .gameResumes(targetScore: game.rules.targetScore)
            return .needsDecision
        }

        do {
            // Partie terminée : réouverture **au moment d'enregistrer** seulement (ouvrir, saisir,
            // annuler ou glisser la feuille n'écrit rien) ; statut rétabli juste après si la partie
            // est toujours terminée, ou immédiatement en cas d'échec.
            if game.lifecycle == .finished && !reopenedFinishedGame {
                _ = try repository.reopenGame(id: gameID)
                reopenedFinishedGame = true
                hasWrittenData = true
            }
            switch try repository.replaceRound(input, inGame: gameID, resolution: resolution) {
            case .saved(let updated, _):
                hasWrittenData = true
                self.game = updated
            case .unchanged(let updated):
                self.game = updated
            case .requiresDecision(let conflict):
                // Décision périmée ou partielle : rien n'a été écrit, on redemande.
                restoreLifecycleIfNeeded()
                confirmedLaterRoundIDs = nil
                pendingDecision = .deleteLaterRounds(
                    Self.earlyEndDecision(conflict.inconsistency, in: conflict.preview)
                )
                return .needsDecision
            }
            // Correction enregistrée : « terminée » rétabli si le moteur la juge toujours terminée
            // (un échec ici n'annule pas la correction ; nouvelle tentative à la fermeture).
            restoreLifecycleIfNeeded()
            complete()
            return .saved
        } catch {
            // Correction non enregistrée : la partie rouverte retrouve aussitôt son statut.
            restoreLifecycleIfNeeded()
            saveErrorMessage = Self.saveMessage(for: GameRepositoryError.from(error, operation: .write))
            return .failed
        }
    }

    private static func saveMessage(for error: GameRepositoryError) -> String {
        if case .anotherGameActive = error { return CorrectionText.anotherGameActive }
        return error.userFacingMessage
    }

    private func complete() {
        pendingDecision = nil
        pendingDeletionConfirmation = nil
        saveErrorMessage = nil
        isCompleted = true
    }

    // MARK: Utilitaires

    nonisolated static func status(for text: String) -> FieldStatus {
        switch RoundDraft.parseScore(text) {
        case .empty:
            return .empty
        case .value(let value):
            return usualScores.contains(value) ? .value(value) : .unusual(value)
        case .invalid:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.count == 1, let sign = trimmed.first, signCharacters.contains(sign) {
                return .signOnly
            }
            return .invalid
        }
    }

    /// « cartes d'Alice » (raison de blocage d'une grille incomplète).
    nonisolated static func cardsItem(_ name: String) -> String {
        "cartes \(VerdictText.ofName(name))"
    }

    /// « 1 carte manquante », « 3 cartes manquantes ».
    nonisolated static func missingCardsText(_ count: Int) -> String {
        count > 1 ? "\(count) cartes manquantes" : "\(count) carte manquante"
    }

    /// Information après une bascule cartes → points (`nil` si rien à signaler) : grille jamais
    /// touchée ⇒ rien ; grille incomplète ⇒ invitation à saisir le total ou compléter les cartes ;
    /// total des cartes différent d'un score saisi à la main ⇒ ce score est conservé (règle du Kit).
    nonisolated static func cardsNotice(for entry: DraftEntry) -> String? {
        guard entry.inputMethod == .points, entry.cardGrid != CardGrid() else { return nil }
        guard let total = entry.cardGrid.evaluate().rawScore else {
            if entry.points == nil {
                return "La grille est incomplète\u{00A0}: saisissez le total à la main ou complétez les cartes."
            }
            return "La grille est incomplète\u{00A0}: le score saisi à la main est conservé. "
                + "Vérifiez-le ou complétez les cartes."
        }
        if let points = entry.points, points != total {
            return "Total des cartes\u{00A0}: \(ScoreFormat.display(total)). Le score saisi à la main "
                + "(\(ScoreFormat.display(points))) est conservé\u{00A0}: corrigez-le si besoin."
        }
        return nil
    }

    private static func earlyEndDecision(
        _ inconsistency: EarlyEndInconsistency,
        in computation: GameComputation
    ) -> EarlyEndDecision {
        let laterIDs = Set(inconsistency.subsequentRoundIDs)
        let indices = computation.rounds
            .filter { laterIDs.contains($0.scoring.roundID) }
            .map(\.scoring.index)
            .sorted()
        return EarlyEndDecision(
            endingRoundIndex: inconsistency.endingRoundIndex,
            laterRoundIDs: inconsistency.subsequentRoundIDs,
            laterRoundIndices: indices
        )
    }

    /// Refus du moteur sur une saisie complète (rare : partie déjà terminée, dépassement).
    private static func blockingMessage(for error: any Error) -> String {
        guard let validationError = error as? ValidationError else {
            return "Cette saisie ne peut pas être calculée."
        }
        switch validationError.underlyingReason {
        case .gameAlreadyFinished:
            return "La partie est terminée\u{00A0}: aucune manche ne peut être ajoutée."
        case .arithmeticOverflow:
            return "Un score est trop grand pour être calculé."
        default:
            return "Cette saisie ne peut pas être calculée."
        }
    }
}
