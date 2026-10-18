import SwiftUI
import TableScoreKit

/// Création de partie (feuille `AppSheet.newGame`, `NavigationStack` interne).
/// Action principale : « Commencer ». Aucune logique métier ici : tout passe par `NewGameModel`.
struct NewGameView: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        NewGameContent(repository: dependencies.repository)
    }
}

private struct NewGameContent: View {
    @Environment(AppRouter.self) private var router
    @State private var model: NewGameModel
    @State private var startError: String?
    @State private var isConfirmingCancel = false
    @FocusState private var focusedID: UUID?

    init(repository: any GameRepository) {
        _model = State(initialValue: NewGameModel(repository: repository))
    }

    var body: some View {
        NavigationStack {
            Form {
                playersSection
                suggestionsSection
                rulesSection
                errorSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Nouvelle partie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler", action: cancel)
                        .accessibilityIdentifier(AccessibilityID.Setup.cancel)
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
            .primaryActionInset {
                if let reason = model.startBlockReason {
                    Text(reason)
                        .font(Theme.Typography.detail)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier(AccessibilityID.Setup.startBlockReason)
                }
                PrimaryActionButton("Commencer") { start() }
                    .disabled(!model.canStart)
                    .accessibilityIdentifier(AccessibilityID.Setup.start)
                    .accessibilityHint(model.startBlockReason ?? "")
            }
            .confirmationDialog(
                "Abandonner la création\u{202F}?",
                isPresented: $isConfirmingCancel,
                titleVisibility: .visible
            ) {
                Button("Abandonner", role: .destructive) { router.dismissSheet() }
                Button("Continuer la saisie", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(model.hasUserInput)
        .task {
            model.loadSuggestions()
            focusedID = model.players.first?.id
        }
    }

    // MARK: Joueurs

    private var playersSection: some View {
        Section {
            ForEach(Bindable(model).players) { $player in
                playerRow($player)
                    .deleteDisabled(!model.canRemovePlayer)
            }
            .onMove { source, destination in
                model.move(from: source, to: destination)
            }
            .onDelete { offsets in
                model.remove(atOffsets: offsets)
            }

            Button {
                if let id = model.addPlayer() { focusedID = id }
            } label: {
                Label("Ajouter un joueur", systemImage: "plus.circle.fill")
            }
            .disabled(!model.canAddPlayer)
            .accessibilityIdentifier(AccessibilityID.Setup.addPlayer)
        } header: {
            Text("Joueurs")
                .foregroundStyle(Theme.Palette.secondaryText)
        } footer: {
            Group {
                if !model.canAddPlayer {
                    Text("\(NewGameModel.playerRange.upperBound) joueurs maximum")
                } else {
                    Text("De \(NewGameModel.playerRange.lowerBound) à \(NewGameModel.playerRange.upperBound) joueurs. Les lignes vides sont ignorées.")
                }
            }
            .foregroundStyle(Theme.Palette.secondaryText)
        }
    }

    private func playerRow(_ player: Binding<NewGameModel.PlayerDraft>) -> some View {
        let id = player.wrappedValue.id
        let number = model.number(of: id)
        let issue = model.issues[id]
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            // Texte d'attente en couleur secondaire contrastée (celle du système, ≈ 2:1, est signalée
            // par l'audit de contraste).
            TextField(
                text: player.name,
                prompt: Text("Prénom du joueur \(number)").foregroundStyle(Theme.Palette.secondaryText)
            ) {
                Text("Prénom du joueur \(number)")
            }
            .focused($focusedID, equals: id)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(model.shouldFinishOnSubmit(id) ? .done : .next)
            .onSubmit { focusedID = model.submit(from: id) }
            .accessibilityLabel("Prénom du joueur \(number)")
            .accessibilityIdentifier(AccessibilityID.Setup.player(number: number))
            if let issue {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Image(systemName: Theme.Symbol.warning)
                        .foregroundStyle(Theme.Palette.warning)
                        .accessibilityHidden(true)
                    Text(issue.message)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
                .font(Theme.Typography.detail)
            }
        }
        .frame(minHeight: Theme.Size.minTapTarget, alignment: .center)
    }

    // MARK: Prénoms récents

    @ViewBuilder
    private var suggestionsSection: some View {
        let suggestions = model.suggestions
        if !suggestions.isEmpty, model.canApplySuggestion {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.s) {
                        ForEach(suggestions, id: \.self) { name in
                            Button(name) {
                                if let id = model.applySuggestion(name) { focusedID = id }
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                            .frame(minHeight: Theme.Size.minTapTarget)
                            .lineLimit(1)
                            .accessibilityLabel("Ajouter \(name)")
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            } header: {
                Text("Prénoms récents")
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
    }

    // MARK: Règles

    private var rulesSection: some View {
        Section {
            Text(model.rulesSummary)
            DisclosureGroup("Règles maison", isExpanded: Bindable(model).houseRulesExpanded) {
                Stepper(
                    value: Bindable(model).targetScore,
                    in: NewGameModel.targetScoreRange,
                    step: NewGameModel.targetScoreStep
                ) {
                    Text("Fin de partie à \(model.targetScore) points")
                }
                .accessibilityIdentifier(AccessibilityID.Setup.targetScore)

                Toggle("Doubler le score du clôturant", isOn: Bindable(model).doublesCloserScore)
                    .accessibilityHint("Activé\u{00A0}: règle officielle. Désactivé\u{00A0}: variante maison, sans doublement.")

                if model.isCloserPenaltyDisabled || model.targetScore != GameRules.officialTargetScore {
                    Text("Variante non officielle\u{00A0}: les scores suivront ces réglages.")
                        .font(Theme.Typography.detail)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }
            .accessibilityIdentifier(AccessibilityID.Setup.houseRules)
        } header: {
            Text("Règles")
                .foregroundStyle(Theme.Palette.secondaryText)
        }
    }

    // MARK: Erreur

    @ViewBuilder
    private var errorSection: some View {
        if let startError {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Image(systemName: Theme.Symbol.warning)
                        .foregroundStyle(Theme.Palette.warning)
                        .accessibilityHidden(true)
                    Text(startError)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Actions

    private func start() {
        do {
            let id = try model.start()
            startError = nil
            router.openGame(id)
            router.notifyDataChanged()
        } catch {
            startError = error.userFacingMessage
        }
    }

    private func cancel() {
        if model.hasUserInput {
            isConfirmingCancel = true
        } else {
            router.dismissSheet()
        }
    }
}

#if DEBUG
#Preview("Clair") {
    NewGameView()
        .previewEnvironment()
}

#Preview("Sombre, texte très grand") {
    NewGameView()
        .previewEnvironment()
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility3)
}
#endif
