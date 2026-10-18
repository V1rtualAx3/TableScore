import Foundation
import Observation

/// Résumé affichable de la partie en cours (aucune règle de score : tout vient du dépôt/moteur).
struct ActiveGameSummary: Sendable, Hashable, Identifiable {
    let id: UUID
    let playerCount: Int
    let roundsPlayed: Int
    let updatedAt: Date
    /// Le moteur considère la partie terminée (elle reste « en cours » côté cycle de vie
    /// jusqu'à action explicite) : aucune perte si l'on en crée une nouvelle.
    let isOver: Bool
}

/// État de l'accueil : lecture seule du dépôt (source de vérité unique).
@Observable
@MainActor
final class HomeModel {
    enum State: Equatable {
        case loading
        case empty
        case active(ActiveGameSummary)
        /// Message déjà localisé et sans donnée sensible (`GameRepositoryError.userFacingMessage`).
        case failed(message: String)
    }

    private(set) var state: State = .loading
    private let repository: any GameRepository

    init(repository: any GameRepository) {
        self.repository = repository
    }

    /// Relit la partie active. Toute erreur est affichée, jamais masquée par un état vide.
    func load() {
        do {
            if let game = try repository.activeGame() {
                state = .active(
                    ActiveGameSummary(
                        id: game.id,
                        playerCount: game.participants.count,
                        roundsPlayed: game.rounds.count,
                        updatedAt: game.updatedAt,
                        isOver: game.isOver
                    )
                )
            } else {
                state = .empty
            }
        } catch {
            state = .failed(message: GameRepositoryError.from(error, operation: .read).userFacingMessage)
        }
    }

    var activeGame: ActiveGameSummary? {
        if case .active(let summary) = state { return summary }
        return nil
    }

    /// Créer une partie range l'active comme « interrompue » : confirmation requise, sauf si elle
    /// est déjà terminée selon le moteur (elle est alors simplement close, sans perte).
    var needsReplacementConfirmation: Bool {
        guard let summary = activeGame else { return false }
        return !summary.isOver
    }

    // MARK: Textes

    /// « 4 joueurs · 3 manches jouées ».
    static func summaryText(playerCount: Int, roundsPlayed: Int) -> String {
        let players = playerCount == 1
            ? String(localized: "1 joueur")
            : String(localized: "\(playerCount) joueurs")
        let rounds = switch roundsPlayed {
        case 0: String(localized: "aucune manche jouée")
        case 1: String(localized: "1 manche jouée")
        default: String(localized: "\(roundsPlayed) manches jouées")
        }
        return "\(players) · \(rounds)"
    }

    /// « Modifiée il y a 5 minutes » ; « Modifiée à l'instant » sous la minute (toujours en français).
    static func lastSavedText(updatedAt: Date, now: Date = Date()) -> String {
        guard abs(now.timeIntervalSince(updatedAt)) >= 60 else {
            return String(localized: "Modifiée à l'instant")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Theme.locale
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: updatedAt, relativeTo: now)
        return String(localized: "Modifiée \(relative)")
    }
}
