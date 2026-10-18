import Accessibility
import SwiftUI
import TableScoreKit

/// Vérification de la grille proposée par le scan (prototype P2).
///
/// Réutilise `CardGridEditor` (mêmes calculs du Kit, même sélecteur de valeur) sur une **copie
/// locale** : la manche n'est modifiée qu'avec « Utiliser ces cartes », après confirmation si le
/// joueur avait déjà des cartes saisies, et rien n'est enregistré avant « Enregistrer la manche ».
/// Cases incertaines : vides, signalées dans la grille (symbole + « à vérifier » pour VoiceOver)
/// et listées en texte avec la lecture probable.
struct CardScanReviewView: View {
    private let summary: CardScanSummary
    private let position: Int
    private let currentGrid: CardGrid
    private let onUse: (CardGrid) -> Void
    private let onRetake: () -> Void

    @State private var grid: CardGrid
    @State private var isConfirmingReplace = false

    init(
        result: CardScanResult,
        playerName: String,
        position: Int,
        currentGrid: CardGrid,
        onUse: @escaping (CardGrid) -> Void,
        onRetake: @escaping () -> Void
    ) {
        self.summary = CardScanSummary(result: result, playerName: playerName)
        self.position = position
        self.currentGrid = currentGrid
        self.onUse = onUse
        self.onRetake = onRetake
        _grid = State(initialValue: result.grid)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                CardScanSummaryHeader(summary: summary)
                let notes = summary.notes
                if !notes.isEmpty {
                    CardScanNotes(notes: notes)
                }
                CardGridEditor(
                    grid: $grid,
                    playerName: summary.playerName,
                    position: position,
                    flaggedCells: Set(summary.result.uncertainCells),
                    allowsScanning: false
                )
                Text(verbatim: CardScanSummary.reviewReminder)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.l)
        }
        .background(Theme.Palette.background)
        .primaryActionInset {
            PrimaryActionButton("Utiliser ces cartes") { use() }
                .disabled(!CardScanSummary.canUse(grid))
                .accessibilityIdentifier(AccessibilityID.Scan.use)
            Button {
                onRetake()
            } label: {
                Label("Reprendre la photo", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, minHeight: Theme.Size.minTapTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityID.Scan.retake)
        }
        .confirmationDialog(
            Text(verbatim: CardScanSummary.replaceTitle),
            isPresented: $isConfirmingReplace,
            titleVisibility: .visible
        ) {
            Button("Remplacer", role: .destructive) { onUse(grid) }
                .accessibilityIdentifier(AccessibilityID.Scan.confirmReplace)
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(verbatim: CardScanSummary.replaceMessage(playerName: summary.playerName))
        }
        .task {
            // Laisse VoiceOver annoncer le changement d'écran avant le bilan.
            try? await Task.sleep(for: .milliseconds(600))
            var message = AttributedString(summary.announcement)
            message.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(message).post()
        }
    }

    /// Jamais d'écrasement silencieux d'une grille déjà commencée.
    private func use() {
        if CardScanSummary.needsReplaceConfirmation(current: currentGrid) {
            isConfirmingReplace = true
        } else {
            onUse(grid)
        }
    }
}

/// « 10 cartes lues sur 12 » + « 2 cases à vérifier » (symbole et texte).
private struct CardScanSummaryHeader: View {
    let summary: CardScanSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label {
                Text(verbatim: summary.headline)
                    .font(.title3.weight(.semibold))
            } icon: {
                Image(systemName: "camera.viewfinder")
            }
            if let verifyText = summary.verifyText {
                Label {
                    Text(verbatim: verifyText)
                } icon: {
                    Image(systemName: Theme.Symbol.warning)
                        .foregroundStyle(Theme.Palette.warning)
                }
                .font(Theme.Typography.detail)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [summary.headline, summary.verifyText].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(AccessibilityID.Scan.summary)
    }
}

/// Cases à vérifier (avertissement) et informations (colonne vide, cases sans lecture).
private struct CardScanNotes: View {
    let notes: [CardScanSummary.Note]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(notes) { note in
                Label {
                    Text(verbatim: note.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: note.kind == .warning ? Theme.Symbol.warning : "info.circle")
                        .foregroundStyle(note.kind == .warning ? Theme.Palette.warning : Color.secondary)
                }
                .font(Theme.Typography.detail)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Scan.notes)
    }
}
