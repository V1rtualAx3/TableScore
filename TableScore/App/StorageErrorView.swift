import Accessibility
import SwiftUI

/// Écran affiché si le stockage local ne peut pas être ouvert au lancement.
///
/// `message` provient de `GameRepositoryError.userFacingMessage` (déjà localisé, sans chemin
/// de fichier ni identifiant) : il est affiché tel quel. Aucune donnée n'est effacée ici.
///
/// Seconde action, sur décision explicite et après confirmation : mettre de côté les fichiers
/// illisibles (renommés, conservés, jamais supprimés) puis réessayer, ce qui crée un stockage
/// vide (`AppBootstrap.setAsideUnreadableData`).
struct StorageErrorView: View {
    let message: String
    let onRetry: () -> Void
    private let context: PersistenceController.LaunchContext

    @State private var isConfirmingSetAside = false
    @State private var setAsideFailed = false
    @State private var didSetAside = false

    init(
        message: String,
        context: PersistenceController.LaunchContext = .current,
        onRetry: @escaping () -> Void
    ) {
        self.message = message
        self.context = context
        self.onRetry = onRetry
    }

    var body: some View {
        ContentUnavailableView {
            Label("Impossible de lire les parties enregistrées", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            VStack(spacing: 8) {
                Text(message)
                if didSetAside {
                    Text("Les données illisibles ont été mises de côté.")
                }
            }
        } actions: {
            Button("Réessayer", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(AccessibilityID.StorageError.retry)
            if AppBootstrap.canSetAsideUnreadableData(context: context) {
                Button("Mettre de côté les données illisibles et repartir de zéro") {
                    isConfirmingSetAside = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier(AccessibilityID.StorageError.setAside)
            }
        }
        .confirmationDialog(
            "Repartir de zéro\u{202F}?",
            isPresented: $isConfirmingSetAside,
            titleVisibility: .visible
        ) {
            Button("Mettre de côté et repartir de zéro", role: .destructive, action: setAside)
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(
                "Les fichiers illisibles seront renommés et conservés sur cet iPhone, sans être supprimés, "
                + "mais l'application ne pourra plus afficher les parties qu'ils contiennent. "
                + "Un stockage vide sera créé pour les prochaines parties."
            )
        }
        .alert("Mise de côté impossible", isPresented: $setAsideFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Aucun fichier n'a été supprimé. Vous pouvez réessayer.")
        }
    }

    private func setAside() {
        do {
            try AppBootstrap.setAsideUnreadableData(context: context)
        } catch {
            setAsideFailed = true
            return
        }
        didSetAside = true
        AccessibilityNotification.Announcement("Les données illisibles ont été mises de côté.").post()
        onRetry()
    }
}

#Preview {
    StorageErrorView(message: "Impossible de lire les données enregistrées.") {}
}
