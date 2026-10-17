import SwiftUI

/// Ligne de saisie du score d'un joueur : nom, bouton « ± », champ numérique.
///
/// Décision clavier (docs/ux/lot2-parcours.md §2.4) : `.numberPad` (grosses touches, une main,
/// aucune lettre) + bouton de signe visible dans la ligne, utilisable avec VoiceOver et un
/// clavier matériel. Le champ vide affiche « — » (jamais « 0 ») ; le texte affiché est
/// exactement celui qui est analysé par `RoundDraft.parseScore`.
struct ScoreEntryRow: View {
    let field: RoundEntryModel.Field
    let model: RoundEntryModel
    let focus: FocusState<UUID?>.Binding

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var fieldMinWidth: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if dynamicTypeSize.isAccessibilitySize {
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
            if let message = field.message {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: Theme.Symbol.warning)
                        .foregroundStyle(Theme.Palette.warning)
                }
                .font(Theme.Typography.detail)
                .foregroundStyle(field.isError ? Color.primary : Color.secondary)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var name: some View {
        Text(field.name)
            .font(Theme.Typography.playerName)
            .lineLimit(2)
            .accessibilityHidden(true) // déjà dans le libellé du champ et du bouton
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
            .accessibilityLabel(field.isNegative ? "Rendre positif" : "Rendre négatif")
            .accessibilityHint("Score de \(field.name)")
            .accessibilityIdentifier(AccessibilityID.Round.sign(position: field.position))

            TextField("—", text: textBinding)
                .keyboardType(.numberPad)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .font(Theme.Typography.entryScore)
                .padding(.horizontal, Theme.Spacing.s)
                .frame(minWidth: fieldMinWidth, maxWidth: fieldMinWidth * 1.6, minHeight: Theme.Size.minTapTarget)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: Theme.Spacing.s))
                .focused(focus, equals: field.participantID)
                .accessibilityLabel("Score de \(field.name)")
                .accessibilityValue(field.spokenValue)
                .accessibilityIdentifier(AccessibilityID.Round.score(position: field.position))
        }
    }
}
