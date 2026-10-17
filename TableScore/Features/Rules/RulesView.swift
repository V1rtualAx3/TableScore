import SwiftUI

/// Règles de comptage (docs/ux/lot2-parcours.md §2.7) : texte statique reformulé, hors ligne,
/// sans lien externe ni visuel de marque. Les exemples reprennent le tableau du cahier des
/// charges (§3.2) ; le calcul réel reste dans le moteur, cet écran n'affiche que du texte.
struct RulesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                RulesSection(title: "Le principe") {
                    Text("À chaque manche, chaque joueur compte les points de ses cartes. Les scores de manche s'additionnent et le plus petit total gagne.")
                    Text("Cette aide concerne Skyjo classique (2 à 8 joueurs, 12 cartes par joueur en 4 colonnes de 3, cartes de −2 à 12).")
                }

                RulesSection(title: "Compter sa grille") {
                    Text("On additionne les valeurs des cartes restantes. Un 0 ne rapporte rien, une carte négative fait baisser le score\u{00A0}: le score d'une manche peut donc être nul ou négatif.")
                }

                RulesSection(title: "Colonnes verticales identiques") {
                    Text("Quand les trois cartes d'une même colonne verticale sont identiques, la colonne est retirée et ne compte plus, même si la valeur est négative.")
                    Text("Seules les colonnes verticales comptent\u{00A0}: trois cartes identiques sur une ligne horizontale ne sont pas retirées. Une colonne ne se retire qu'une seule fois.")
                    Text("En saisie directe des points, les colonnes sont déjà retirées à la table\u{00A0}: l'application ne les retire pas une seconde fois.")
                }

                RulesSection(title: "Le joueur qui termine la manche") {
                    Text("Le joueur qui termine la manche doit avoir le plus petit score, sans égalité. Si au moins un autre joueur a un score inférieur ou égal au sien, son score de manche est doublé, à condition qu'il soit strictement positif.")
                    Text("Le doublement n'est jamais appliqué à 0 ni à un score négatif.")
                        .fontWeight(.semibold)
                    Text("La comparaison se fait sur les scores de la manche avant doublement, jamais sur les totaux.")
                }

                RulesSection(title: "Exemples") {
                    VStack(spacing: Theme.Spacing.s) {
                        ForEach(RulesExample.all) { example in
                            ExampleRow(example: example)
                        }
                    }
                }

                RulesSection(title: "Fin de partie") {
                    Text("Une fois les scores de tous les joueurs ajoutés aux totaux, la partie s'arrête dès qu'un total atteint 100 points ou plus (ou le seuil choisi dans les règles maison). La manche en cours va toujours à son terme.")
                    Text("Le plus petit total gagne. En cas d'égalité, les joueurs concernés sont co-vainqueurs\u{00A0}: aucun départage n'est inventé.")
                }

                Text("Texte reformulé. En cas de doute, la notice de votre boîte de jeu fait foi.")
                    .font(Theme.Typography.detail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.l)
        }
        .background(Theme.Palette.background)
        .navigationTitle("Règles de comptage")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Section titrée (en-tête VoiceOver) ; le texte est sélectionnable par lecture linéaire.
private struct RulesSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// Exemple de manche (cahier des charges §3.2). Valeurs documentaires, non calculées.
private struct RulesExample: Identifiable, Sendable {
    let id: Int
    let scores: String
    let closer: String
    let retained: String
    let cause: String

    static let all: [RulesExample] = [
        RulesExample(id: 1, scores: "Alice 10, Bob 24, Chloé 10", closer: "Alice", retained: "20", cause: "égalité\u{00A0}: score doublé"),
        RulesExample(id: 2, scores: "Alice 10, Bob 11", closer: "Alice", retained: "10", cause: "seul plus petit score\u{00A0}: pas de doublement"),
        RulesExample(id: 3, scores: "Alice 12, Bob 9", closer: "Alice", retained: "24", cause: "Bob a fait moins\u{00A0}: score doublé"),
        RulesExample(id: 4, scores: "Alice \(ScoreFormat.display(-2)), Bob \(ScoreFormat.display(-4))", closer: "Alice", retained: ScoreFormat.display(-2), cause: "score négatif\u{00A0}: jamais doublé"),
        RulesExample(id: 5, scores: "Alice 0, Bob \(ScoreFormat.display(-1))", closer: "Alice", retained: "0", cause: "zéro\u{00A0}: jamais doublé"),
        RulesExample(id: 6, scores: "Alice \(ScoreFormat.display(-5)), Bob \(ScoreFormat.display(-5))", closer: "Alice", retained: ScoreFormat.display(-5), cause: "négatif malgré l'égalité\u{00A0}: jamais doublé"),
    ]
}

private struct ExampleRow: View {
    let example: RulesExample

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(example.scores)
                .font(.body.monospacedDigit())
            Text("\(example.closer) termine\u{00A0}: score retenu \(example.retained), \(example.cause).")
                .font(Theme.Typography.detail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.m)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
        .accessibilityElement(children: .combine)
    }
}

#Preview("Règles") {
    NavigationStack {
        RulesView()
    }
}

#Preview("Sombre, XXL") {
    NavigationStack {
        RulesView()
    }
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility3)
}
