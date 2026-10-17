import SwiftUI

/// Fin de partie, intégrée en tête du tableau des scores par `GameView` (docs/ux/lot2-parcours.md §2.3).
///
/// Vainqueur(s), rangs et totaux viennent de `GameOverSummary` (lecture de `GameComputation`).
/// « Rejouer » : `onReplay()` (la création est faite par le modèle de `GameView`).
struct GameOverSection: View {
    let game: SavedGame
    let onReplay: () -> Void

    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppPreferenceKey.hapticsEnabled) private var hapticsEnabled = true
    @State private var hasAppeared = false

    private var summary: GameOverSummary? { GameOverSummary(game: game) }

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            if let summary {
                header(summary)
                finalScores(summary)
                Text(summary.rulesReminder)
                    .font(Theme.Typography.detail)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                titleText
            }
            actions
        }
        .padding(Theme.Spacing.l)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .sensoryFeedback(trigger: hasAppeared) { _, appeared in
            (appeared && hapticsEnabled) ? .success : nil
        }
        .task {
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.easeOut(duration: 0.5)) { hasAppeared = true }
            }
            if let summary {
                AccessibilityNotification.Announcement(summary.spokenSummary).post()
            }
        }
    }

    // MARK: Blocs

    private var titleText: some View {
        Text("Partie terminée")
            .font(.title.bold())
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(AccessibilityID.GameOver.title)
    }

    private func header(_ summary: GameOverSummary) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: "trophy.fill")
                .font(.largeTitle)
                .foregroundStyle(Theme.Palette.accent)
                // Animation sobre (échelle + opacité), supprimée si « Réduire les animations ».
                .scaleEffect(reduceMotion || hasAppeared ? 1 : 0.6)
                .opacity(reduceMotion || hasAppeared ? 1 : 0)
                .accessibilityHidden(true)
            titleText
            Text(summary.headline)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary.spokenWinners)
                .accessibilityIdentifier(AccessibilityID.GameOver.winners)
            Text("Après \(summary.roundCount) manches")
                .font(Theme.Typography.detail)
                .foregroundStyle(.secondary)
        }
    }

    private func finalScores(_ summary: GameOverSummary) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            ForEach(summary.lines) { line in
                lineView(line)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: GameOverSummary.Line) -> some View {
        let content = Group {
            Text("\(PlayerScoreRow.rankText(line.rank)) · \(line.name)")
                .font(Theme.Typography.playerName)
                .fontWeight(line.isWinner ? .bold : .regular)
                .lineLimit(2)
            if line.isWinner {
                Label("Vainqueur", systemImage: Theme.Symbol.leader)
                    .font(.caption.bold())
                    .foregroundStyle(Theme.Palette.leader)
            }
        }
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    content
                    ScoreText(line.total, font: .title.monospacedDigit().bold())
                }
            } else {
                HStack(spacing: Theme.Spacing.s) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) { content }
                    Spacer(minLength: Theme.Spacing.s)
                    ScoreText(line.total, font: .title.monospacedDigit().bold())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLine(line))
    }

    private func spokenLine(_ line: GameOverSummary.Line) -> String {
        let base = "\(PlayerScoreRow.spokenRank(line.rank)), \(line.name), \(ScoreFormat.spoken(line.total)) points"
        return line.isWinner ? base + ", " + String(localized: "vainqueur") : base
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.s) {
            PrimaryActionButton("Rejouer avec les mêmes joueurs", action: onReplay)
                .accessibilityIdentifier(AccessibilityID.GameOver.replay)
            Button {
                router.show(.history(game.id))
            } label: {
                Text("Voir l'historique").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier(AccessibilityID.GameOver.history)
            Button {
                router.popToRoot()
            } label: {
                Text("Accueil").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier(AccessibilityID.GameOver.home)
        }
    }
}

#if DEBUG
#Preview("Égalité de fin") {
    NavigationStack {
        GameView(gameID: UITestSeed.tieEnd.activeGameID)
    }
    .previewEnvironment(.tieEnd)
}

#Preview("Égalité, XXL, sombre") {
    NavigationStack {
        GameView(gameID: UITestSeed.tieEnd.activeGameID)
    }
    .previewEnvironment(.tieEnd)
    .dynamicTypeSize(.accessibility3)
    .preferredColorScheme(.dark)
}
#endif
