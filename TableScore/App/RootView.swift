import SwiftUI

/// Hôte de navigation : un seul `NavigationStack`, une seule feuille à la fois
/// (docs/ux/lot2-parcours.md §1). Les écrans reçoivent `AppRouter` et `AppDependencies`
/// par l'environnement ; les feuilles en héritent.
struct RootView: View {
    @State private var router = AppRouter()

    var body: some View {
        NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .sheet(item: $router.sheet) { sheet in
            sheetContent(for: sheet)
        }
        .environment(router)
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .game(let gameID):
            GameView(gameID: gameID)
        case .history(let gameID):
            HistoryView(gameID: gameID)
        case .finishedGames:
            FinishedGamesView()
        case .rules:
            RulesView()
        case .settings:
            SettingsView()
        }
    }

    @ViewBuilder
    private func sheetContent(for sheet: AppSheet) -> some View {
        switch sheet {
        case .newGame:
            NewGameView()
        case .roundEntry(let gameID, let mode):
            RoundEntryView(gameID: gameID, mode: mode)
        }
    }
}

#if DEBUG
#Preview("Partie proche de la fin") {
    RootView()
        .previewEnvironment(.nearEnd)
}
#endif
