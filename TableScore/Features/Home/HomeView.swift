import SwiftUI

/// Accueil : racine de `RootView` (pas de `NavigationStack` propre).
/// Action principale unique selon l'état : « Reprendre la partie » ou « Nouvelle partie ».
struct HomeView: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        HomeScreen(repository: dependencies.repository)
    }
}

private struct HomeScreen: View {
    @Environment(AppRouter.self) private var router
    @State private var model: HomeModel
    @State private var isConfirmingReplacement = false

    init(repository: any GameRepository) {
        _model = State(initialValue: HomeModel(repository: repository))
    }

    var body: some View {
        List {
            Section {
                header
            }
            .listRowBackground(Color.clear)

            Section {
                NavigationLink(value: Route.finishedGames) {
                    Label("Parties terminées", systemImage: "archivebox")
                }
                .accessibilityIdentifier(AccessibilityID.Home.finishedGames)

                NavigationLink(value: Route.rules) {
                    Label("Règles de comptage", systemImage: "book")
                }
                .accessibilityIdentifier(AccessibilityID.Home.rules)

                NavigationLink(value: Route.settings) {
                    Label("Paramètres", systemImage: "gearshape")
                }
                .accessibilityIdentifier(AccessibilityID.Home.settings)
            }
        }
        .navigationTitle("TableScore")
        .task(id: router.dataRevision) {
            model.load()
        }
        .primaryActionInset {
            actions
        }
        .confirmationDialog(
            "Une partie est en cours",
            isPresented: $isConfirmingReplacement,
            titleVisibility: .visible
        ) {
            Button("Abandonner et commencer", role: .destructive) {
                router.present(.newGame)
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("La partie en cours sera rangée dans les parties terminées comme interrompue.")
        }
    }

    // MARK: En-tête

    @ViewBuilder
    private var header: some View {
        switch model.state {
        case .failed(let message):
            ContentUnavailableView {
                Label("Impossible de lire les parties enregistrées", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Réessayer") {
                    model.load()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.StorageError.retry)
            }
        case .active(let summary):
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                tagline
                resumeCard(summary)
            }
        case .loading, .empty:
            tagline
        }
    }

    private var tagline: some View {
        Text("Les scores de votre partie, sans papier ni crayon.")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resumeCard(_ summary: ActiveGameSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Partie en cours")
                .font(.headline)
            Text(HomeModel.summaryText(playerCount: summary.playerCount, roundsPlayed: summary.roundsPlayed))
            if summary.isOver {
                Text("Partie terminée : résultat à consulter")
            }
            Text(HomeModel.lastSavedText(updatedAt: summary.updatedAt))
                .foregroundStyle(.secondary)
        }
        .font(Theme.Typography.detail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch model.state {
        case .active(let summary):
            PrimaryActionButton("Reprendre la partie") {
                router.openGame(summary.id)
            }
            .accessibilityHint(
                HomeModel.summaryText(playerCount: summary.playerCount, roundsPlayed: summary.roundsPlayed)
            )
            .accessibilityIdentifier(AccessibilityID.Home.resume)

            Button {
                startNewGame()
            } label: {
                Text("Nouvelle partie")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier(AccessibilityID.Home.newGame)
        case .empty:
            PrimaryActionButton("Nouvelle partie") {
                startNewGame()
            }
            .accessibilityIdentifier(AccessibilityID.Home.newGame)
        case .loading, .failed:
            // Pas d'action de création tant que l'état du stockage est inconnu.
            EmptyView()
        }
    }

    private func startNewGame() {
        if model.needsReplacementConfirmation {
            isConfirmingReplacement = true
        } else {
            router.present(.newGame)
        }
    }
}

#if DEBUG
#Preview("Vide") {
    NavigationStack { HomeView() }
        .previewEnvironment()
}

#Preview("Partie en cours") {
    NavigationStack { HomeView() }
        .previewEnvironment(.nearEnd)
}

#Preview("Partie en cours, sombre, XXL") {
    NavigationStack { HomeView() }
        .previewEnvironment(.eightPlayers)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility3)
}
#endif
