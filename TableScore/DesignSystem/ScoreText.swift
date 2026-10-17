import SwiftUI

/// Mise en forme **d'affichage** des scores (aucune règle de score ici).
///
/// - Signe moins typographique U+2212, indépendant de la langue de l'appareil.
/// - `magnitude` évite tout dépassement de capacité sur `Int.min`.
enum ScoreFormat {
    static let minusSign = "\u{2212}"

    /// « 12 », « 0 », « −3 ».
    static func display(_ value: Int) -> String {
        value < 0 ? minusSign + String(value.magnitude) : String(value)
    }

    /// Écart ou variation : « +12 », « 0 », « −3 ».
    static func delta(_ value: Int) -> String {
        value > 0 ? "+" + String(value) : display(value)
    }

    /// Lecture VoiceOver : « moins 3 » plutôt qu'un signe parfois ignoré.
    static func spoken(_ value: Int) -> String {
        guard value < 0 else { return String(value) }
        let magnitude = String(value.magnitude)
        return String(localized: "moins \(magnitude)")
    }
}

/// Score en chiffres tabulaires, signe moins lisible, lecture VoiceOver explicite.
/// La transition numérique est coupée si « Réduire les animations » est actif.
struct ScoreText: View {
    private let value: Int
    private let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ value: Int, font: Font = Theme.Typography.total) {
        self.value = value
        self.font = font
    }

    var body: some View {
        Text(ScoreFormat.display(value))
            .font(font)
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(value)))
            .accessibilityLabel(ScoreFormat.spoken(value))
    }
}

#Preview {
    VStack(spacing: Theme.Spacing.l) {
        ScoreText(74)
        ScoreText(-12)
        ScoreText(0, font: Theme.Typography.entryScore)
    }
}
