import SwiftUI
import TableScoreKit

/// Écran plein écran du scan (prototype P2) : autorisation, aperçu avec cadre-guide 3 × 4,
/// lecture, puis vérification. « Annuler » ferme sans rien modifier.
struct CardScanFlowView: View {
    private let currentGrid: CardGrid
    private let playerName: String
    private let position: Int
    private let onUse: (CardGrid) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppPreferenceKey.hapticsEnabled) private var hapticsEnabled = true
    /// Créé à l'apparition (pas à chaque reconstruction de la vue parente).
    @State private var model: CardScanModel?

    init(currentGrid: CardGrid, playerName: String, position: Int, onUse: @escaping (CardGrid) -> Void) {
        self.currentGrid = currentGrid
        self.playerName = playerName
        self.position = position
        self.onUse = onUse
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(verbatim: title))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annuler") { close() }
                            .accessibilityIdentifier(AccessibilityID.Scan.cancel)
                    }
                }
        }
        .task {
            if model == nil {
                model = CardScanModel.makeDefault()
            }
            await model?.start()
        }
        .onDisappear { model?.stop() }
        .sensoryFeedback(trigger: model?.resultCount ?? 0) { _, newValue in
            hapticsEnabled && newValue > 0 ? .impact(weight: .light) : nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            switch model.phase {
            case .preparing:
                CardScanProgress(text: "Ouverture de l'appareil photo…")
            case .capturing:
                if let camera = model.camera as? CardScanCamera {
                    CardScanCaptureView(camera: camera) { region in
                        Task { await model.capture(region: region) }
                    }
                }
            case .analyzing:
                CardScanProgress(text: "Lecture des cartes…")
            case .review(let result):
                CardScanReviewView(
                    result: result,
                    playerName: playerName,
                    position: position,
                    currentGrid: currentGrid,
                    onUse: { use($0) },
                    onRetake: { Task { await model.retake() } }
                )
                // Nouvelle vérification (grille locale réinitialisée) à chaque résultat.
                .id(model.resultCount)
            case .denied, .restricted, .unavailable, .interrupted, .failed:
                CardScanMessageView(
                    phase: model.phase,
                    onRetake: { Task { await model.retake() } },
                    onClose: { close() }
                )
            }
        } else {
            CardScanProgress(text: "Ouverture de l'appareil photo…")
        }
    }

    private var title: String {
        if case .some(.review) = model?.phase {
            return CardScanSummary.title(playerName: playerName)
        }
        return "Scanner les cartes"
    }

    private func use(_ grid: CardGrid) {
        onUse(grid)
        close()
    }

    private func close() {
        model?.stop()
        dismiss()
    }
}

private struct CardScanProgress: View {
    let text: LocalizedStringKey

    var body: some View {
        ProgressView(text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Aperçu en direct, cadre-guide et bouton « Prendre la photo » (zone du pouce).
private struct CardScanCaptureView: View {
    let camera: CardScanCamera
    let onCapture: (CardScanRegion?) -> Void

    @State private var previewSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CardScanPreview(camera: camera)
                CardScanGuide()
            }
            .clipped()
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                previewSize = size
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Aperçu de l'appareil photo"))
            .accessibilityValue(Text("Cadrez les 12 cartes du joueur, 4 colonnes et 3 rangées."))

            VStack(spacing: Theme.Spacing.m) {
                Text("Cadrez les 12 cartes du joueur, vues du dessus\u{00A0}: 4 colonnes, 3 rangées.")
                    .font(Theme.Typography.detail)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    onCapture(region)
                } label: {
                    Label("Prendre la photo", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(AccessibilityID.Scan.capture)
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private var region: CardScanRegion? {
        guard previewSize.width > 0, previewSize.height > 0 else { return nil }
        return CardScanRegion(guide: CardScanGeometry.guideRect(in: previewSize), viewSize: previewSize)
    }
}

/// Cadre-guide 4 colonnes × 3 rangées (tirets clairs sur liseré sombre : lisible sur tout fond).
private struct CardScanGuide: View {
    var body: some View {
        GeometryReader { proxy in
            let path = Self.path(in: CardScanGeometry.guideRect(in: proxy.size))
            ZStack {
                path.stroke(Color.black.opacity(0.45), style: StrokeStyle(lineWidth: 4))
                path.stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func path(in rect: CGRect) -> Path {
        Path { path in
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 12, height: 12))
            for column in 1..<CardGrid.columnCount {
                let x = rect.minX + rect.width * CGFloat(column) / CGFloat(CardGrid.columnCount)
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            for row in 1..<CardGrid.rowCount {
                let y = rect.minY + rect.height * CGFloat(row) / CGFloat(CardGrid.rowCount)
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
    }
}

/// Autorisation refusée ou limitée, appareil indisponible, lecture impossible. La saisie
/// manuelle reste disponible ; aucun lien ne quitte l'application (chemin des Réglages en texte).
private struct CardScanMessageView: View {
    let phase: CardScanModel.Phase
    let onRetake: () -> Void
    let onClose: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: content.title)
            } icon: {
                Image(systemName: content.symbol)
            }
        } description: {
            Text(verbatim: content.message)
        } actions: {
            if phase == .failed || phase == .interrupted {
                Button(LocalizedStringKey(phase == .failed ? "Reprendre la photo" : "Réessayer"), action: onRetake)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.Scan.retake)
            }
            Button("Saisir à la main", action: onClose)
                .buttonStyle(.bordered)
        }
        .accessibilityIdentifier(AccessibilityID.Scan.message)
    }

    private var content: (title: String, message: String, symbol: String) {
        let manual = "La saisie manuelle des cartes reste disponible."
        switch phase {
        case .denied:
            return (
                "Accès à l'appareil photo refusé",
                "Autorisez l'accès dans Réglages\u{00A0}› TableScore\u{00A0}› Appareil photo, puis réessayez. \(manual)",
                "lock.fill"
            )
        case .restricted:
            return (
                "Appareil photo limité",
                "L'accès à l'appareil photo est limité sur cet iPhone (Temps d'écran ou gestion de l'appareil). \(manual)",
                "lock.fill"
            )
        case .interrupted:
            return (
                "Appareil photo interrompu",
                "Un appel ou une autre app utilise l'appareil photo. La prise de vue reprend dès qu'il est libéré. \(manual)",
                "pause.circle"
            )
        case .failed:
            return (
                "Lecture impossible",
                "La photo n'a pas pu être analysée. \(manual)",
                Theme.Symbol.warning
            )
        default:
            return (
                "Appareil photo indisponible",
                "L'appareil photo n'a pas pu être ouvert. \(manual)",
                Theme.Symbol.warning
            )
        }
    }
}
