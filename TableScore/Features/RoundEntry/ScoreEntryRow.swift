import Accessibility
import SwiftUI
import TableScoreKit

/// Ligne de saisie d'un joueur : nom, champ numérique et bouton « ± » (mode « Points »), ou grille
/// de cartes (mode « Cartes », `CardGridEditor`), avec le sélecteur « Points | Cartes » du joueur.
///
/// Décision clavier (docs/ux/lot2-parcours.md §2.4) : `.numberPad` (grosses touches, une main,
/// aucune lettre) + bouton de signe visible dans la ligne, utilisable avec VoiceOver et un
/// clavier matériel. Le champ vide affiche « — » (jamais « 0 ») ; le texte affiché est
/// exactement celui qui est analysé par `RoundDraft.parseScore`.
///
/// Sélecteur de mode **par joueur** (cahier §3.3, §4.4) : la première ligne (nom + score) reste
/// celle du Lot 2 ; le sélecteur, secondaire, est placé dessous et ne change pas de place quand on
/// bascule (retour immédiat possible). Aucun calcul ici : total et validation viennent du Kit.
struct ScoreEntryRow: View {
    let field: RoundEntryModel.Field
    let model: RoundEntryModel
    let focus: FocusState<UUID?>.Binding

    /// Délai avant l'annonce d'une information de bascule : laisse VoiceOver finir d'annoncer le
    /// changement de segment, qui sinon couvrirait l'annonce.
    private static let noticeAnnouncementDelay: Duration = .milliseconds(600)

    /// Identifiant de défilement de la ligne (bouton « Suivant » du clavier).
    static func scrollAnchor(position: Int) -> String { "round.entry.\(position)" }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var fieldMinWidth: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            firstLine
            if field.inputMethod == .points {
                pointsMessages
            }
            inputMethodPicker
            if field.inputMethod == .cards {
                CardGridEditor(
                    grid: gridBinding,
                    playerName: field.name,
                    position: field.position,
                    onBeginEditing: releaseKeyboardFocus
                )
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: Première ligne

    @ViewBuilder
    private var firstLine: some View {
        if field.inputMethod == .cards {
            // La grille affiche son propre total (`cards.total.<position>`).
            name
        } else if dynamicTypeSize.isAccessibilitySize {
            // Grandes tailles : nom au-dessus, commandes en dessous (aucune troncature).
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                name
                HStack {
                    Spacer(minLength: 0)
                    controls
                }
            }
        } else {
            HStack(spacing: Theme.Spacing.m) {
                name
                Spacer(minLength: Theme.Spacing.s)
                controls
            }
        }
    }

    private var name: some View {
        Text(field.name)
            .font(Theme.Typography.playerName)
            // Tailles d'accessibilité : prénom jamais tronqué (il est seul sur sa ligne).
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            // Exposé comme en-tête de la ligne du joueur (navigation par en-têtes dans un formulaire
            // de 8 joueurs) : masqué, ce texte visible était signalé par l'audit (« texte
            // potentiellement inaccessible »).
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Mode « Points »

    @ViewBuilder
    private var pointsMessages: some View {
        if let message = field.message {
            Label {
                Text(message)
            } icon: {
                Image(systemName: Theme.Symbol.warning)
                    .foregroundStyle(Theme.Palette.warning)
            }
            .font(Theme.Typography.detail)
            .foregroundStyle(field.isError ? Color.primary : Theme.Palette.secondaryText)
            .accessibilityElement(children: .combine)
        }
        if let notice = field.cardsNotice {
            Label {
                Text(verbatim: notice)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(Theme.Typography.detail)
            .foregroundStyle(Theme.Palette.secondaryText)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Round.cardsNotice(position: field.position))
        }
    }

    /// Liaison vers le modèle : le texte saisi est transmis tel quel, l'analyse est faite par le Kit.
    private var textBinding: Binding<String> {
        let text = field.text
        let participantID = field.participantID
        let model = model
        return Binding(
            get: { text },
            set: { model.setText($0, for: participantID) }
        )
    }

    /// Visuellement « ± » puis champ (pouce) ; VoiceOver lit d'abord le champ, puis le bouton
    /// (priorités de lecture dans le conteneur).
    private var controls: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                model.toggleSign(for: field.participantID)
            } label: {
                Image(systemName: Theme.Symbol.sign)
                    .font(.title3)
                    .frame(minWidth: Theme.Size.minTapTarget, minHeight: Theme.Size.minTapTarget)
                    .contentShape(Rectangle())
            }
            // Style explicite : dans un `Form`, évite que toute la ligne déclenche le bouton.
            .buttonStyle(.bordered)
            .accessibilityLabel(signLabel)
            .accessibilitySortPriority(0)
            .accessibilityIdentifier(AccessibilityID.Round.sign(position: field.position))

            // Texte d'attente « — » en couleur secondaire contrastée (celle du système, ≈ 2:1, est
            // signalée par l'audit de contraste) ; la valeur VoiceOver d'un champ vide reste « vide ».
            TextField(text: textBinding, prompt: placeholder) {
                Text(verbatim: "—")
            }
            .keyboardType(.numberPad)
            .autocorrectionDisabled()
            .multilineTextAlignment(.trailing)
            .font(Theme.Typography.entryScore)
            .padding(.horizontal, Theme.Spacing.s)
            .frame(minWidth: fieldMinWidth, maxWidth: fieldMinWidth * 1.6, minHeight: Theme.Size.minTapTarget)
            .background { fieldBackground }
            .focused(focus, equals: field.participantID)
            .accessibilityLabel(Text(verbatim: "Score \(VerdictText.ofName(field.name))"))
            .accessibilityValue(field.spokenValue)
            .accessibilitySortPriority(1)
            .accessibilityIdentifier(AccessibilityID.Round.score(position: field.position))
        }
        .accessibilityElement(children: .contain)
    }

    /// « — » (jamais « 0 ») en couleur secondaire contrastée.
    private var placeholder: Text {
        Text(verbatim: "—").foregroundStyle(Theme.Palette.secondaryText)
    }

    /// Cadre visible du champ (44 pt de haut au minimum). Le champ texte lui-même est plus petit
    /// (marges horizontales, hauteur d'une ligne) : sans ce geste, toucher le bord du cadre ne
    /// donnait pas le focus (cible réelle < 44 pt). Le fond est **derrière** le champ : un toucher
    /// sur le texte reste géré par le champ (placement du curseur). Masqué pour VoiceOver, qui
    /// active le champ lui-même.
    private var fieldBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Spacing.s)
        let participantID = field.participantID
        let focus = focus
        return shape
            .fill(Color(.tertiarySystemFill))
            .contentShape(shape)
            .onTapGesture {
                focus.wrappedValue = participantID
            }
            .accessibilityHidden(true)
    }

    /// « Rendre négatif le score d'Alice » / « Rendre positif le score de Bob ».
    private var signLabel: Text {
        let action = field.isNegative ? "Rendre positif" : "Rendre négatif"
        return Text(verbatim: "\(action) le score \(VerdictText.ofName(field.name))")
    }

    // MARK: Sélecteur « Points | Cartes »

    private var inputMethodPicker: some View {
        Picker(selection: inputMethodBinding) {
            Text("Points").tag(InputMethod.points)
            Text("Cartes").tag(InputMethod.cards)
        } label: {
            Text(verbatim: inputMethodLabel)
        }
        .pickerStyle(.segmented)
        // Largeur naturelle ; en tailles d'accessibilité, toute la largeur (pas de débordement).
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
        .accessibilityIdentifier(AccessibilityID.Round.inputMethod(position: field.position))
    }

    /// « Mode de saisie d'Alice » (libellé du `Picker`).
    private var inputMethodLabel: String {
        "Mode de saisie \(VerdictText.ofName(field.name))"
    }

    /// Bascule par le modèle (aucune perte, cf. `RoundEntryModel.setInputMethod`). Le champ texte
    /// disparaît en mode « Cartes » : son focus est rendu. L'information éventuelle (grille
    /// incomplète…) est aussi annoncée à VoiceOver.
    private var inputMethodBinding: Binding<InputMethod> {
        let inputMethod = field.inputMethod
        let participantID = field.participantID
        let model = model
        let focus = focus
        return Binding(
            get: { inputMethod },
            set: { (newValue: InputMethod) in
                if newValue == .cards, focus.wrappedValue == participantID {
                    focus.wrappedValue = nil
                }
                if let notice = model.setInputMethod(newValue, for: participantID) {
                    Task {
                        try? await Task.sleep(for: Self.noticeAnnouncementDelay)
                        AccessibilityNotification.Announcement(notice).post()
                    }
                }
            }
        )
    }

    // MARK: Mode « Cartes »

    /// Ouverture du sélecteur de valeur : le clavier d'un autre champ se ferme (il masquerait la feuille).
    private var releaseKeyboardFocus: () -> Void {
        let focus = focus
        return { focus.wrappedValue = nil }
    }

    /// Grille du brouillon (Kit) ; chaque modification repasse par le modèle, qui recalcule la
    /// validation et l'aperçu.
    private var gridBinding: Binding<CardGrid> {
        let participantID = field.participantID
        let model = model
        return Binding(
            get: { model.cardGrid(for: participantID) },
            set: { (grid: CardGrid) in model.setCardGrid(grid, for: participantID) }
        )
    }
}
