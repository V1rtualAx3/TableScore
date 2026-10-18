import SwiftUI

/// Section « Qui a terminé la manche ? » : un bouton par joueur, sélection unique explicite,
/// aucune présélection en ajout. Sélection indiquée par une coche **et** un texte « A terminé »
/// (jamais par la couleur seule) et, pour VoiceOver, par le trait « sélectionné » et la valeur
/// « a terminé ».
///
/// Tailles d'accessibilité : prénom jamais tronqué, mention « A terminé » placée sous le prénom.
struct CloserPicker: View {
    let model: RoundEntryModel

    /// Identifiant de défilement de la section (bouton « Suivant » du clavier).
    static let scrollAnchor = "round.closerSection"

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Section {
            ForEach(model.fields) { field in
                row(for: field)
                    .id(field.position == 0 ? Self.scrollAnchor : "closer.\(field.position)")
            }
        } header: {
            Text("Qui a terminé la manche\u{202F}?")
                .foregroundStyle(Theme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            Text("Choisissez une seule personne.")
                .foregroundStyle(Theme.Palette.secondaryText)
        }
    }

    private func row(for field: RoundEntryModel.Field) -> some View {
        let isSelected = model.closerID == field.participantID
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        return Button {
            model.selectCloser(field.participantID)
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: isSelected ? Theme.Symbol.selected : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.secondaryText)
                if isAccessibilitySize {
                    // Empilé : le prénom garde toute la largeur.
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        name(field)
                        if isSelected { closedLabel }
                    }
                    Spacer(minLength: 0)
                } else {
                    name(field)
                    Spacer(minLength: Theme.Spacing.s)
                    if isSelected { closedLabel }
                }
            }
            .frame(minHeight: Theme.Size.minTapTarget)
            .contentShape(Rectangle())
        }
        // Le bouton fusionne déjà son contenu en un seul élément : libellé = prénom seul.
        .accessibilityLabel(Text(verbatim: field.name))
        .accessibilityValue(isSelected ? Text("a terminé") : Text(verbatim: ""))
        .accessibilityHint(Text("Désigner comme joueur ayant terminé la manche"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.Round.closer(position: field.position))
    }

    private func name(_ field: RoundEntryModel.Field) -> some View {
        Text(field.name)
            .font(Theme.Typography.playerName)
            .foregroundStyle(Color.primary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .multilineTextAlignment(.leading)
    }

    private var closedLabel: some View {
        Label("A terminé", systemImage: Theme.Symbol.closer)
            .font(Theme.Typography.detail)
            .foregroundStyle(Theme.Palette.secondaryText)
    }
}
