import SwiftUI

/// Écran affiché si le stockage local ne peut pas être ouvert au lancement.
///
/// `message` provient de `GameRepositoryError.userFacingMessage` (déjà localisé, sans chemin
/// de fichier ni identifiant) : il est affiché tel quel. Aucune donnée n'est effacée ici.
struct StorageErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Impossible de lire les parties enregistrées", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Réessayer", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(AccessibilityID.StorageError.retry)
        }
    }
}

#Preview {
    StorageErrorView(message: "Impossible de lire les données enregistrées.") {}
}
