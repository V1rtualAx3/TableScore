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
    ///
    /// Zone **opaque, placée sous** le contenu défilant (pile verticale), jamais superposée à lui
    /// (l'ancien `safeAreaInset` + matériau `.bar` laissait défiler le contenu derrière l'action) :
    /// aucun texte flouté sous un fond translucide (illisible, signalé « Contrast failed » par
    /// l'audit sur les écrans 06, 08, 13 et 15, probablement 02 clavier ouvert) ni bouton à fond translucide
    /// posé sur un matériau (« Nouvelle partie », « Reprendre la photo »). Pas d'effet de verre
    /// (docs 03). Fond `surface` (blanc en clair, gris foncé en sombre, comme une barre d'outils)
    /// prolongé sous l'indicateur d'accueil ; filet de séparation en haut. La liste ou le
    /// défilement s'arrête au-dessus de la zone : sa dernière ligne reste atteignable.
    ///
    /// `isPresented` à `false` : ni séparateur ni bande vide (écran sans action pour l'instant).
    func primaryActionInset<Content: View>(
        isPresented: Bool = true,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let actions = content()
        return VStack(spacing: 0) {
            self
            if isPresented {
                Divider()
                VStack(spacing: Theme.Spacing.s) {
                    actions
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .frame(maxWidth: .infinity)
                .background(Theme.Palette.surface)
            }
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
