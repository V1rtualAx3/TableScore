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
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                PrimaryActionButton("Commencer") { start() }
                    .disabled(!model.canStart)
                    .accessibilityIdentifier(AccessibilityID.Setup.start)
                    .accessibilityHint(model.startBlockReason ?? "")
            }
            .confirmationDialog(
                "Abandonner la création ?",
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
        } footer: {
            if !model.canAddPlayer {
                Text("\(NewGameModel.playerRange.upperBound) joueurs maximum")
            } else {
                Text("De \(NewGameModel.playerRange.lowerBound) à \(NewGameModel.playerRange.upperBound) joueurs. Les lignes vides sont ignorées.")
            }
        }
    }

    private func playerRow(_ player: Binding<NewGameModel.PlayerDraft>) -> some View {
        let id = player.wrappedValue.id
        let number = model.number(of: id)
        let issue = model.issues[id]
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            TextField("Prénom du joueur \(number)", text: player.name)
                .focused($focusedID, equals: id)
                .textContentType(.givenName)
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
                        .foregroundStyle(.secondary)
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
            Section("Prénoms récents") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.s) {
                        ForEach(suggestions, id: \.self) { name in
                            Button(name) {
                                if let id = model.applySuggestion(name) { focusedID = id }
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .lineLimit(1)
                            .accessibilityLabel("Ajouter \(name)")
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        }
    }

    // MARK: Règles

    private var rulesSection: some View {
        Section("Règles") {
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

                Toggle("Pénalité du clôturant désactivée", isOn: Bindable(model).isCloserPenaltyDisabled)

                if model.isCloserPenaltyDisabled || model.targetScore != GameRules.officialTargetScore {
                    Text("Variante non officielle : les scores suivront ces réglages.")
                        .font(Theme.Typography.detail)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier(AccessibilityID.Setup.houseRules)
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
