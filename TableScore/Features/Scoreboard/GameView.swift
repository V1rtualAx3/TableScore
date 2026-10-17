import Accessibility
import SwiftUI

/// Tableau des scores de la partie (docs/ux/lot2-parcours.md §2.3). Destination de `Route.game`.
///
/// Aucune règle de score ici : tout provient de `GameComputation` via `GameModel`.
/// Rechargement sur `.task(id: router.dataRevision)`.
struct GameView: View {
    let gameID: UUID

    @Environment(AppRouter.self) private var router
    @Environment(AppDependencies.self) private var dependencies
    @State private var model: GameModel?

    var body: some View {
        Group {
            if let model {
                GameContentView(model: model)
            } else {
                ProgressView()
            }
        }
        .task(id: router.dataRevision) {
            let current = model ?? GameModel(gameID: gameID, repository: dependencies.repository)
            if model == nil { model = current }
            current.load()
        }
    }
}

private struct GameContentView: View {
    @Bindable var model: GameModel

    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppPreferenceKey.hapticsEnabled) private var hapticsEnabled = true
    @State private var isConfirmingAbandon = false

    var body: some View {
        Group {
            switch model.loadState {
            case .loading:
                ProgressView()
            case .failed(let message):
                failureView(message: message)
            case .loaded:
                scoreboard
            }
        }
        .background(Theme.Palette.background)
        .navigationTitle(model.headerTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.loadState == .loaded {
                ToolbarItem(placement: .principal) {
                    if model.showsFinalResults {
                        // Le titre « Partie terminée » est dans l'écran de fin : pas de doublon dans la barre.
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityHidden(true)
                    } else {
                        VStack(spacing: 0) {
                            Text(model.headerTitle).font(.headline)
                            Text(model.headerSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    optionsMenu
                }
            }
        }
        .confirmationDialog(
            "Abandonner la partie\u{202F}?",
            isPresented: $isConfirmingAbandon,
            titleVisibility: .visible
        ) {
            Button("Abandonner", role: .destructive) {
                if model.abandon() {
                    router.notifyDataChanged()
                    router.popToRoot()
                }
            }
            Button("Continuer la partie", role: .cancel) {}
        } message: {
            Text("Elle restera consultable dans Parties terminées.")
        }
        .alert(
            "Action impossible",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .sensoryFeedback(trigger: model.savedRoundCount) { _, _ in
            hapticsEnabled ? .success : nil
        }
        .sensoryFeedback(trigger: model.endFeedbackCount) { _, _ in
            hapticsEnabled ? .success : nil
        }
        .task(id: model.showsFinalResults) {
            // Fin de partie : une seule annonce et une seule haptique, au premier affichage.
            guard model.consumeEndAnnouncement(),
                  let game = model.game,
                  let summary = GameOverSummary(game: game) else { return }
            AccessibilityNotification.Announcement(summary.spokenSummary).post()
        }
        .task(id: model.banner) {
            guard let banner = model.banner else { return }
            AccessibilityNotification.Announcement(
                [banner.message, banner.detail].compactMap { $0 }.joined(separator: ". ")
            ).post()
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { model.dismissBanner() }
        }
    }

    // MARK: Contenu

    @ViewBuilder
    private var scoreboard: some View {
        if model.canAddRound {
            scoreboardScroll
                .primaryActionInset {
                    PrimaryActionButton("Ajouter une manche") {
                        router.present(.roundEntry(gameID: model.gameID, mode: .new))
                    }
                    .accessibilityIdentifier(AccessibilityID.Game.addRound)
                }
        } else if model.showsFinalResults {
            scoreboardScroll
                .primaryActionInset {
                    PrimaryActionButton("Rejouer avec les mêmes joueurs") { replay() }
                        .accessibilityIdentifier(AccessibilityID.GameOver.replay)
                }
        } else {
            scoreboardScroll
        }
    }

    private var scoreboardScroll: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.s) {
                if model.hasInconsistency {
                    inconsistencyBanner
                }
                if model.showsFinalResults, let game = model.game {
                    // Un seul tableau final (`standingsAtEnd`) : ni lignes de score ni classement.
                    GameOverSection(game: game)
                } else {
                    if model.roundCount == 0 {
                        Text("Aucune manche pour l'instant. Les totaux apparaîtront ici.")
                            .font(Theme.Typography.detail)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Spacing.xs)
                    }
                    ForEach(model.rows) { row in
                        PlayerScoreRow(row: row)
                    }
                    standingsSection
                    historyLink
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
        }
        .overlay(alignment: .top) {
            // Bannière hors du défilement : visible sans quitter le haut de l'écran.
            if let banner = model.banner {
                bannerView(banner)
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.top, Theme.Spacing.s)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.banner)
    }

    private func bannerView(_ banner: GameModel.Banner) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(banner.message, systemImage: Theme.Symbol.selected)
                .font(.headline)
            if let detail = banner.detail {
                Label(detail, systemImage: Theme.Symbol.doubled)
                    .font(Theme.Typography.detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.m)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row).strokeBorder(Color.secondary.opacity(0.35)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Game.banner)
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    private var inconsistencyBanner: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label {
                Text("La partie aurait dû se terminer plus tôt. Vérifiez l'historique des manches.")
            } icon: {
                Image(systemName: Theme.Symbol.warning)
                    .foregroundStyle(Theme.Palette.warning)
            }
            Button("Ouvrir l'historique") {
                router.show(.history(model.gameID))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.m)
        .background(Theme.Palette.warning.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.Radius.row))
    }

    @ViewBuilder
    private var standingsSection: some View {
        if model.playerCount > 1 {
            DisclosureGroup("Classement") {
                VStack(spacing: Theme.Spacing.s) {
                    ForEach(model.rankedRows) { row in
                        HStack {
                            Text("\(PlayerScoreRow.rankText(row.rank)) · \(row.name)")
                                .lineLimit(2)
                            Spacer(minLength: Theme.Spacing.s)
                            ScoreText(row.total, font: .body.monospacedDigit().bold())
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "\(PlayerScoreRow.spokenRank(row.rank)), \(row.name), \(ScoreFormat.spoken(row.total)) points"
                        )
                    }
                }
                .padding(.top, Theme.Spacing.s)
            }
            .padding(Theme.Spacing.l)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
        }
    }

    @ViewBuilder
    private var historyLink: some View {
        if let title = model.historyLinkTitle {
            historyButton(title)
        }
    }

    private func historyButton(_ title: String) -> some View {
        Button {
            router.show(.history(model.gameID))
        } label: {
            HStack {
                Text(title)
                Spacer(minLength: Theme.Spacing.s)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.Size.minTapTarget)
            .padding(.horizontal, Theme.Spacing.l)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.Game.historyLink)
    }

    private var optionsMenu: some View {
        Menu {
            Button {
                router.show(.history(model.gameID))
            } label: {
                Label("Historique", systemImage: "list.bullet")
            }
            .accessibilityIdentifier(AccessibilityID.Game.menuHistory)

            Button {
                router.show(.rules)
            } label: {
                Label("Règles de comptage", systemImage: "book")
            }
            .accessibilityIdentifier(AccessibilityID.Game.menuRules)

            if model.canAbandon {
                Button(role: .destructive) {
                    isConfirmingAbandon = true
                } label: {
                    Label("Abandonner la partie", systemImage: "xmark.bin")
                }
                .accessibilityIdentifier(AccessibilityID.Game.menuAbandon)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(minWidth: Theme.Size.minTapTarget, minHeight: Theme.Size.minTapTarget)
        }
        .accessibilityLabel("Options de la partie")
        .accessibilityIdentifier(AccessibilityID.Game.menu)
    }

    private func failureView(message: String) -> some View {
        ContentUnavailableView {
            Label(
                model.loadFailureIsNotFound
                    ? String(localized: "Partie introuvable")
                    : String(localized: "Impossible de charger la partie"),
                systemImage: Theme.Symbol.warning
            )
        } description: {
            Text(message)
        } actions: {
            Button("Accueil") { router.popToRoot() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private func replay() {
        if let newID = model.replay() {
            router.notifyDataChanged()
            router.openGame(newID)
        }
    }
}

#if DEBUG
#Preview("8 joueurs") {
    NavigationStack {
        GameView(gameID: UITestSeed.eightPlayers.activeGameID)
    }
    .previewEnvironment(.eightPlayers)
}

#Preview("8 joueurs, XXL, sombre") {
    NavigationStack {
        GameView(gameID: UITestSeed.eightPlayers.activeGameID)
    }
    .previewEnvironment(.eightPlayers)
    .dynamicTypeSize(.accessibility3)
    .preferredColorScheme(.dark)
}

#Preview("Partie terminée") {
    NavigationStack {
        GameView(gameID: UITestSeed.tieEnd.activeGameID)
    }
    .previewEnvironment(.tieEnd)
}
#endif
