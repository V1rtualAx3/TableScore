import SwiftUI

/// Section « Qui a terminé la manche ? » : un bouton par joueur, sélection unique explicite,
/// aucune présélection en ajout. Sélection indiquée par une coche **et** un texte « A terminé »
/// (jamais par la couleur seule) et par le trait VoiceOver « sélectionné ».
struct CloserPicker: View {
    let model: RoundEntryModel

    /// Identifiant de défilement de la section (bouton « Suivant » du clavier).
    static let scrollAnchor = "round.closerSection"

    var body: some View {
        Section {
            ForEach(model.fields) { field in
                row(for: field)
                    .id(field.position == 0 ? Self.scrollAnchor : "closer.\(field.position)")
            }
        } header: {
            Text("Qui a terminé la manche ?")
        } footer: {
            Text("Choisissez une seule personne.")
        }
    }

    private func row(for field: RoundEntryModel.Field) -> some View {
        let isSelected = model.closerID == field.participantID
        return Button {
            model.selectCloser(field.participantID)
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: isSelected ? Theme.Symbol.selected : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.Palette.accent : Color.secondary)
                Text(field.name)
                    .font(Theme.Typography.playerName)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                Spacer(minLength: Theme.Spacing.s)
                if isSelected {
                    Label("A terminé", systemImage: Theme.Symbol.closer)
                        .font(Theme.Typography.detail)
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(minHeight: Theme.Size.minTapTarget)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(field.name) a terminé la manche")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.Round.closer(position: field.position))
    }
}
