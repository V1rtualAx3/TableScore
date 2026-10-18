import SwiftUI

/// Ligne d'un joueur : nom, rang, badge « En tête » (texte + symbole), total très lisible.
/// Lecture VoiceOver combinée : « Alice, total 74 points, première place, en tête ».
struct PlayerScoreRow: View {
    let row: GameModel.Row

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    nameView
                    ScoreText(row.total)
                    detailsView
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: Theme.Spacing.m) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        nameView
                        detailsView
                    }
                    Spacer(minLength: Theme.Spacing.s)
                    ScoreText(row.total)
                }
            }
        }
        .padding(Theme.Spacing.l)
        .frame(minHeight: Theme.Size.minTapTarget)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier(AccessibilityID.Game.player(position: row.position))
    }

    private var nameView: some View {
        Text(row.name)
            .font(Theme.Typography.playerName)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var detailsView: some View {
        // `ViewThatFits` évite la troncature quand rang, badge et écart ne tiennent pas sur une ligne.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.s) { detailItems }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) { detailItems }
        }
        .font(Theme.Typography.detail)
    }

    @ViewBuilder
    private var detailItems: some View {
        Text(Self.rankText(row.rank))
            .foregroundStyle(Theme.Palette.secondaryText)
        if row.isLeader {
            Label {
                Text("En tête")
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: Theme.Symbol.leader)
                    .foregroundStyle(Theme.Palette.leader)
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Palette.leader.opacity(0.15), in: Capsule())
        }
        if let gap = row.gapToLeader, gap > 0 {
            Text(Self.gapText(gap))
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.secondaryText)
        }
    }

    // MARK: Textes

    static func rankText(_ rank: Int) -> String {
        rank == 1 ? String(localized: "1er") : String(localized: "\(rank)e")
    }

    static func spokenRank(_ rank: Int) -> String {
        rank == 1 ? String(localized: "première place") : String(localized: "\(rank)e place")
    }

    /// Écart affiché : « +12\u{00A0}pts ».
    static func gapText(_ gap: Int) -> String {
        ScoreFormat.delta(gap) + "\u{00A0}" + String(localized: "pts")
    }

    /// Écart lu par VoiceOver : « 12 points de plus que le premier ».
    static func spokenGap(_ gap: Int) -> String {
        gap == 1
            ? String(localized: "1 point de plus que le premier")
            : String(localized: "\(gap) points de plus que le premier")
    }

    private var accessibilityText: String {
        var parts = [
            row.name,
            String(localized: "total \(ScoreFormat.spoken(row.total)) points"),
            Self.spokenRank(row.rank),
        ]
        if row.isLeader {
            parts.append(String(localized: "en tête"))
        } else if let gap = row.gapToLeader, gap > 0 {
            parts.append(Self.spokenGap(gap))
        }
        return parts.joined(separator: ", ")
    }
}

#if DEBUG
#Preview("Lignes") {
    VStack {
        PlayerScoreRow(row: .init(id: UUID(), position: 0, name: "Alice", total: 74, rank: 1, isLeader: true, gapToLeader: nil))
        PlayerScoreRow(row: .init(id: UUID(), position: 1, name: "Marie-Charlotte", total: -7, rank: 2, isLeader: false, gapToLeader: 12))
    }
    .padding()
}
#endif
