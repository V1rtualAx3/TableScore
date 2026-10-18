import SwiftUI
import TableScoreKit

/// Point d'entrée « Scanner les cartes » de la grille d'un joueur (prototype P2).
///
/// Absent quand aucun appareil photo n'est disponible (simulateur) : la saisie manuelle reste
/// l'unique chemin, inchangé. Le scan ne fait que **proposer** une grille, vérifiée puis
/// confirmée (« Remplacer les cartes saisies ? » si des cartes existent déjà) ; rien n'est
/// enregistré avant « Enregistrer la manche ».
struct CardScanButton: View {
    @Binding private var grid: CardGrid
    private let playerName: String
    private let position: Int
    private let onBegin: () -> Void

    @State private var isPresented = false

    init(grid: Binding<CardGrid>, playerName: String, position: Int, onBegin: @escaping () -> Void) {
        _grid = grid
        self.playerName = playerName
        self.position = position
        self.onBegin = onBegin
    }

    var body: some View {
        if CardScanAvailability.isOffered {
            Button {
                onBegin()
                isPresented = true
            } label: {
                Label("Scanner les cartes", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity, minHeight: Theme.Size.minTapTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text(verbatim: "Scanner les cartes \(VerdictText.ofName(playerName))"))
            .accessibilityHint(Text("Photographiez la grille pour pré-remplir les cartes, à vérifier ensuite."))
            .accessibilityIdentifier(AccessibilityID.Scan.start(position: position))
            .fullScreenCover(isPresented: $isPresented) {
                CardScanFlowView(
                    currentGrid: grid,
                    playerName: playerName,
                    position: position,
                    onUse: { grid = $0 }
                )
            }
        }
    }
}
