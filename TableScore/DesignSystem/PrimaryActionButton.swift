import SwiftUI

/// Action principale d'un écran : bouton pleine largeur, proéminent, taille `.large`
/// (≈ 50 pt de haut, au-delà de la cible minimale de 44 pt).
///
/// Pendant `isLoading`, le bouton affiche un indicateur et `loadingTitle`, et reste désactivé
/// (protection contre le double tap, en complément de l'idempotence du dépôt).
/// Identifiant d'accessibilité et `.disabled(...)` supplémentaires : à appliquer par l'appelant.
struct PrimaryActionButton: View {
    private let title: LocalizedStringKey
    private let isLoading: Bool
    private let loadingTitle: LocalizedStringKey
    private let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        isLoading: Bool = false,
        loadingTitle: LocalizedStringKey = "Enregistrement…",
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isLoading = isLoading
        self.loadingTitle = loadingTitle
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.s) {
                if isLoading {
                    ProgressView()
                }
                Text(isLoading ? loadingTitle : title)
            }
            .frame(maxWidth: .infinity)
            .onAccentForeground()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isLoading)
    }
}

/// Libellé d'un bouton `.borderedProminent` : `Theme.Palette.onAccent` (blanc en clair, noir en
/// sombre, où la teinte est claire), tant que le bouton est actif ; désactivé, le style système
/// garde son propre rendu. À appliquer **dans** le libellé du bouton (l'environnement `isEnabled`
/// y reflète `.disabled(...)` posé sur le bouton, et le style ne peut pas l'écraser).
private struct OnAccentForeground: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.foregroundStyle(Theme.Palette.onAccent)
        } else {
            content
        }
    }
}

extension View {
    /// Couleur du libellé d'un bouton `.borderedProminent` (voir `OnAccentForeground`).
    func onAccentForeground() -> some View {
        modifier(OnAccentForeground())
    }

    /// Zone d'action fixée en bas de l'écran, à portée de pouce, au-dessus du clavier
    /// (safe area clavier respectée : ne pas combiner avec `.ignoresSafeArea(.keyboard)`).
    /// Le matériau `.bar` ne sert qu'à séparer l'action du contenu qui défile.
    func primaryActionInset<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Theme.Spacing.s) {
                content()
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
            .background(.bar)
        }
    }
}

#Preview {
    List {
        Text("Contenu")
    }
    .primaryActionInset {
        PrimaryActionButton("Enregistrer la manche", isLoading: false) {}
    }
}
