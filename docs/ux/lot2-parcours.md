# Lot 2 — Spécification d'implémentation des parcours (SwiftUI, iOS 18)

> Statut : proposition d'architecture UI, à valider par la session maître. Normatif : `CAHIER_DES_CHARGES.md` §3–§5, `CLAUDE.md` §6.
> Composants natifs d'abord ; aucune règle de score dans les vues ni dans les view models : tout calcul (score retenu,
> raison de doublement, cumuls, fin de partie, vainqueurs, validation du brouillon, recalcul) vient de `TableScoreKit`.
> Les noms d'API du Kit cités ci-dessous sont **attendus** ; les aligner sur l'API réellement livrée, sans dupliquer de logique.

## 0. Principes transverses

- **Source de vérité** : `GameRepository` (protocole, persistance locale) → view models `@Observable @MainActor` → vues.
  Les view models ne stockent que des brouillons de saisie (chaînes, sélection) et des états de présentation.
- **Contrat attendu du Kit** (à confirmer) : `RoundDraft` (scores saisis optionnels + clôturant optionnel + validation),
  `ScoreEngine.preview(draft, game) -> RoundPreview` (score brut, retenu, `DoublingReason`, cumul avant/après, fin de
  partie prévue), `ScoreEngine.recompute(game) -> GameSnapshot` (cumuls, rangs, leaders, vainqueurs, `earliestFinishRound`).
- **Parsing de la saisie** : fonction pure du Kit `RawScoreInput.parse(String) -> Result<Int, InputError>` acceptant
  `-`, `−` (U+2212) et `–` comme signe ; espaces ignorés ; vide ≠ `0` ; refus des non-chiffres et des débordements.
- **Écriture atomique et idempotente** : chaque brouillon de manche porte un `draftID: UUID` réutilisé comme `Round.id` ;
  le dépôt refuse un second insert du même identifiant. Côté UI : `isSaving` désactive le bouton dès le premier tap.
- Aucune vue ne lit directement SwiftData (`@Query` interdit dans les écrans de score) : un seul chemin de données, testable
  avec un dépôt en mémoire injecté (`.environment(...)`).

## 1. Carte de navigation

```
TableScoreApp
└─ RootView : NavigationStack(path: $router.path)            // router: AppRouter (@Observable)
   ├─ HomeView (racine)
   │   ├─ .sheet  NewGameView (NavigationStack interne)       // création ; « Commencer » remplace le path par [.game(id)]
   │   └─ .confirmationDialog « Une partie est en cours »     // si création alors qu'une partie active existe
   ├─ Route.game(UUID)        → GameView (tableau + résultat de fin intégré si status == finished)
   │   ├─ .sheet  RoundEntryView(mode: .new)                  // detents [.large], interactiveDismissDisabled si brouillon modifié
   │   ├─ Route.history(UUID) → HistoryView
   │   │   └─ .sheet RoundEntryView(mode: .edit(roundID))     // même formulaire, CTA « Enregistrer la correction »
   │   │       └─ .alert / .confirmationDialog incohérence §4.6
   │   └─ Menu (toolbar) : Historique, Règles de comptage, Abandonner la partie (confirmé)
   ├─ Route.finishedGames     → FinishedGamesView → Route.game(id) en lecture (+ Historique)
   ├─ Route.rules             → RulesView
   └─ Route.settings          → SettingsView
```

- `enum Route: Hashable { case game(UUID), history(UUID), finishedGames, rules, settings }`.
- Fin de partie : **pas d'écran séparé** ; `GameView` bascule sur `GameOverSection` quand le snapshot indique `isFinished`.
  Reprise après kill : `HomeView` propose « Reprendre » ; aucune restauration automatique du path (évite un état fantôme).
- « Rejouer avec les mêmes joueurs » crée une nouvelle partie (nouveaux `Game.id`, mêmes noms et ordre, nouveaux
  `Participant.id`) puis remplace le path par `[.game(newID)]`.

### View models (propriétés → actions)

| VM | État exposé | Actions |
|---|---|---|
| `HomeModel` | `activeGame: GameSummary?` (joueurs, manches jouées, `updatedAt`), `loadError: StorageError?` | `load()`, `startNewGame()`, `abandonActiveGame()` |
| `NewGameModel` | `players: [PlayerDraft]` (id stable, `name`), `suggestions: [String]`, `targetScore = 100`, `houseRulesExpanded`, `canStart`, `duplicateWarnings: [PlayerDraft.ID: String]` | `addPlayer()`, `remove(id)`, `move(from:to:)`, `applySuggestion(_:)`, `start() async throws -> UUID` |
| `GameModel` | `snapshot: GameSnapshot` (ordre stable, cumuls, rangs, leaders, manche courante, vainqueurs), `lastRoundBanner: RoundBanner?`, `isFinished` | `reload()`, `presentRoundEntry()`, `replayWithSamePlayers()`, `abandon()` |
| `RoundEntryModel` | `mode`, `draftID`, `entries: [EntryField]` (`participantID`, `name`, `text`, `parsed: Result<Int,…>?`), `closerID: UUID?`, `preview: RoundPreview?`, `blockingReasons: [String]`, `isSaving`, `isDirty`, `saveError`, `pendingInconsistency: Inconsistency?` | `setText(_:for:)`, `toggleSign(for:)`, `selectCloser(_:)`, `save() async`, `resolveInconsistency(_:)` |
| `HistoryModel` | `rounds: [RoundRow]` (brut, retenu, raison, clôturant, cumul après), `inconsistency`, `undoableDeletion: Round?` | `edit(roundID)`, `deleteLastRound()`, `undoDeletion()` |
| `FinishedGamesModel` | `games: [GameSummary]` | `delete(id)` (confirmé) |
| `SettingsModel` | `hapticsEnabled` (UserDefaults local) | `deleteAllData()` (double confirmation) |

`preview` est recalculé par le Kit à chaque modification (`didSet` / méthode unique `refreshPreview()`), coût négligeable (≤ 8 joueurs).

## 2. Écrans

### 2.1 Accueil — CTA : « Reprendre la partie » si partie active, sinon « Nouvelle partie »

- Hiérarchie : titre « TableScore » (`.largeTitle`), phrase sobre « Les scores de votre partie, sans papier ni crayon. »,
  carte de reprise (si active) : « 4 joueurs · 3 manches jouées · modifiée il y a 5 min » (`RelativeDateTimeFormatter`, local).
- Si partie active : « Reprendre la partie » = `.borderedProminent`, `.controlSize(.large)` ; « Nouvelle partie » devient
  secondaire (`.bordered`). Sinon « Nouvelle partie » est le seul bouton proéminent.
- Liste secondaire (`List` insetGrouped) : Parties terminées, Règles de comptage, Paramètres (`NavigationLink(value:)`).
- Nouvelle partie avec partie active : `confirmationDialog` « Une partie est en cours » → « Abandonner et commencer »
  (destructif, la partie passe en `archived`, conservée et visible « Interrompue » dans Parties terminées) / « Annuler ».
- Erreur de chargement : `ContentUnavailableView` « Impossible de lire les parties enregistrées » + « Réessayer ».
- Aucun onboarding, aucune permission, aucun écran d'attente.

### 2.2 Création de partie — CTA : « Commencer »

- `Form` dans la feuille : section « Joueurs » avec 2 lignes vides au départ ; `TextField("Prénom du joueur 1", …)`,
  `.textContentType(.givenName)`, `.submitLabel(.next)`, `.autocorrectionDisabled()`. `onSubmit` → focus suivant ;
  sur la dernière ligne non vide, ajoute une ligne si < 8, sinon `.done`.
- « Ajouter un joueur » (`plus.circle.fill`) désactivé à 8 avec texte « 8 joueurs maximum ». Suppression par swipe et
  bouton visible en mode édition ; réordonnancement `onMove` + `EditButton` (identifiants stables : `PlayerDraft.id`).
- Suggestions : rangée de `Button` capsules « Prénoms récents » (stockés localement), qui remplissent la première ligne vide.
- Doublons : comparaison insensible à la casse/diacritiques/espaces (`localizedStandardCompare`/`folding`) dans le VM ;
  message sous la ligne « Deux joueurs s'appellent “Alex” : ajoutez une initiale. » et `Commencer` désactivé.
- Section « Règles » : ligne fixe « Skyjo classique · 100 points » ; `DisclosureGroup("Règles maison")` contenant
  `Stepper` « Fin de partie à 100 points » (pas de 10, 50…500). Pas d'autre variante au Lot 2.
- CTA : zone d'action fixe en bas (`primaryActionInset`, voir §2.3) bouton pleine largeur « Commencer » ; actif si ≥ 2 noms valides (non vides après
  trim, ≤ 24 caractères, sans doublon) ; lignes vides ignorées. Toolbar : « Annuler » (confirmation seulement si saisie).

### 2.3 Partie en cours — CTA : « Ajouter une manche »

- Toolbar : titre **système** « Manche 4 · 4 joueurs » (= manches jouées + 1, puis nombre de joueurs ; iOS 18 n'a pas
  de sous-titre de barre natif, et un titre composé dans `ToolbarItem(.principal)` reste plafonné en Dynamic Type sans
  Grand contenu) ; `Menu` (`ellipsis.circle`, label « Options de la partie ») : Historique, Règles de comptage,
  Abandonner la partie.
- Corps : `ScrollView` + `VStack` (non paresseuse : 8 joueurs au plus) de `PlayerScoreRow` **dans l'ordre de
  `displayOrder`** (jamais retrié) : nom (`.title3`, 2 lignes au plus, sans limite en tailles d'accessibilité), rang
  « 1er », total (`.largeTitle.monospacedDigit()` bold),
  badge « En tête » (`crown.fill` + texte) pour **tous** les leaders ; écart « +12 » vs leader en `Theme.Palette.secondaryText`.
- Section repliée « Classement » triée (optionnelle, `DisclosureGroup`) ; section « Manches » : lien « Historique (3 manches) ».
- Bannière post-enregistrement (`RoundBanner`, 4 s, non bloquante, rejouable via Historique) : « Manche 3 enregistrée » +
  pour le clôturant doublé « Alice : score doublé (10 → 20) ». Annonce VoiceOver via `AccessibilityNotification.Announcement`.
- Animation des totaux : `.contentTransition(.numericText(value:))` ; désactivée si `accessibilityReduceMotion`.
- CTA : zone d'action fixe en bas (`primaryActionInset`) « Ajouter une manche » pleine largeur, `.borderedProminent`,
  hauteur ≥ 50 pt. Zone **opaque** (`Theme.Palette.surface`, filet de séparation en haut) placée **sous** le contenu
  défilant, jamais superposée : pas de matériau translucide (texte flouté derrière le bouton, contraste illisible
  signalé par l'audit d'accessibilité ; pas d'effet de verre, docs 03).
- 8 joueurs / XXL : une ligne par joueur, défilement vertical ; en `dynamicTypeSize.isAccessibilitySize`, la ligne passe
  en `VStack` (nom au-dessus, total dessous) — pas de `minimumScaleFactor` sur le total sous 0.8.
- État vide (0 manche) : texte « Aucune manche pour l'instant. Les totaux apparaîtront ici. » ; tous les totaux à « 0 ».

#### Fin de partie (même écran, `GameOverSection`) — CTA : « Rejouer avec les mêmes joueurs »

- Titre « Partie terminée » ; « Vainqueur : Alice » ou « Co-vainqueurs : Alice et Bob » (liste formatée
  `ListFormatStyle`) ; sous-titre « Plus petit total après 9 manches ». Tableau final trié par total croissant.
- Rappel explicite si utile : « Bob a atteint 100 points : la partie s'arrête, le plus petit total gagne. »
- Secondaires : « Voir l'historique », « Accueil ». « Ajouter une manche » disparaît.
- Animation courte (≤ 0,6 s, scale/opacity du titre) uniquement si Reduce Motion désactivé ; haptique `.success`.

### 2.4 Ajouter une manche (feuille) — CTA : « Enregistrer la manche »

- `NavigationStack` + `Form` ; titre « Manche 4 » ; toolbar « Annuler » (si `isDirty` : `confirmationDialog`
  « Abandonner la saisie ? » → « Abandonner » destructif / « Continuer la saisie »).
- Sélecteur « Points | Cartes » : **livré au Lot 3, par joueur** (contrôle segmenté sous la ligne nom + score de
  chaque joueur, `round.inputMethod.<position>`, « Points » par défaut) plutôt que global en tête de formulaire ;
  voir `ScoreEntryRow` et `RoundEntryModel.setInputMethod` (bascules sans perte, information si grille incomplète).
- **Section « Points de la manche »** : une ligne par joueur, ordre stable : nom, bouton de signe, champ.
- **Décision clavier : `.keyboardType(.numberPad)` + bouton de signe par ligne.** Justification : pavé à grosses touches
  utilisable à une main et sans risque de lettres ; `.numbersAndPunctuation` a des touches petites, expose des lettres
  et rend le `−` peu visible. Le bouton de signe inline (et non seulement dans la toolbar clavier) reste visible avec
  VoiceOver, clavier matériel et iPad-compat, et ne dépend pas du bug connu de `ToolbarItemGroup(placement: .keyboard)`
  dans les feuilles.
  - Bouton « ± » 44×44 pt (`plusminus`), label VoiceOver « Rendre négatif » / « Rendre positif », valeur « Alice ».
    Bascule le préfixe `-` du texte ; sur champ vide, prépare « − » (champ toujours non valide tant qu'aucun chiffre).
  - Toolbar clavier (bonus) : « Suivant » (focus joueur suivant, puis section clôturant) et « OK » (ferme le clavier).
  - `@FocusState var focused: UUID?` ; ouverture de la feuille → focus sur le premier joueur (`.defaultFocus` ou `task`).
  - Champ : `.multilineTextAlignment(.trailing)`, `.font(.title2.monospacedDigit())`, largeur min. 4 caractères
    (`-144`), placeholder « — » (jamais « 0 »). Le texte est **sanitisé** par le VM (chiffres + un signe en tête, 4 car.).
  - Erreur inline sous la ligne (texte + `exclamationmark.triangle.fill`) : « Nombre entier attendu » ou
    « Score hors limites (−24 à 144) » [bornes à arbitrer, cf. §6].
- **Section « Qui a terminé la manche ? »** : liste de lignes-boutons, une par joueur, coche `checkmark.circle.fill`
  sur la sélection, `.accessibilityAddTraits(.isSelected)` sur la ligne choisie ; un tap re-sélectionne (jamais 0 ou
  2 sélectionnés une fois choisi). Pas de présélection. Alternative native acceptable : `Picker(.inline)`.
- **Section « Aperçu »** (visible dès que le brouillon est complet) : une ligne par joueur
  « Alice  +10 → 84 » ; pour le clôturant, libellé exact fourni par le Kit (cf. §3.2), badge « ×2 » + texte.
  Si incomplet : « Complétez : score de Bob, clôturant. » (liste des `blockingReasons`).
- CTA dans la zone d'action fixe (`primaryActionInset`, §2.3) : reste au-dessus du clavier (comportement par défaut de la safe area clavier ;
  **ne pas** utiliser `.ignoresSafeArea(.keyboard)`). Désactivé tant que `blockingReasons` non vide ; libellé
  « Enregistrer la manche » ; pendant `isSaving` : `ProgressView` + « Enregistrement… », bouton désactivé.
- Après succès : haptique `.success`, `dismiss()`, bannière sur `GameView`. Échec : alerte « Enregistrement impossible »,
  « La manche n'a pas été enregistrée. Votre saisie est conservée. » → « Réessayer » / « OK » (même `draftID`).
- Protection double-tap : garde `guard !isSaving` + `draftID` idempotent côté dépôt + `.disabled(isSaving)`.

### 2.5 Historique et correction — pas de CTA proéminent (action principale : toucher une manche)

- `List` de sections « Manche n » (plus récente en haut) ; clôturant marqué « a terminé » (`flag.checkered` + texte) ;
  par joueur : « brut 10 · retenu 20 · total 84 » ; badge « Doublé » si retenu ≠ brut.
- Tap → `RoundEntryView(mode: .edit)` pré-rempli ; CTA « Enregistrer la correction » ; aperçu affiche aussi
  « Les manches suivantes seront recalculées. » si la manche n'est pas la dernière.
- Suppression **uniquement de la dernière manche** (swipe + bouton dans l'édition) → `confirmationDialog`
  « Supprimer la manche 9 ? Les totaux reviendront à leur état précédent. » → « Supprimer la manche » (destructif).
  Puis bannière « Manche 9 supprimée » + bouton « Annuler » (rétablit la même `Round`, même id) jusqu'à la prochaine action.
- **Incohérence §4.6** (le Kit renvoie `earliestFinishRound < dernière manche` après correction) : avant écriture,
  `alert` « La partie aurait dû se terminer » / « Après cette correction, Bob atteint 100 points à la manche 6.
  Les manches 7 à 9 ont été jouées ensuite. » → « Revenir à la saisie » (annule, rien n'est écrit) /
  « Supprimer les manches 7 à 9 » (destructif → seconde confirmation « Supprimer définitivement 3 manches ? »,
  puis correction + suppression en **une** transaction).
  Rien n'est effacé sans ce choix explicite.
- Correction rendant une partie terminée à nouveau active : message « Plus aucun joueur n'atteint 100 points :
  la partie reprend. » (alerte d'information avant écriture, « Enregistrer » / « Revenir à la saisie »).
- État vide : `ContentUnavailableView("Aucune manche", systemImage: "list.number", description: Text("Les manches enregistrées apparaîtront ici."))`.

### 2.6 Parties terminées
- `List` : date, joueurs, vainqueur(s), nombre de manches ; tag « Interrompue » pour les parties abandonnées.
- Swipe « Supprimer » → `confirmationDialog` « Supprimer définitivement cette partie ? Cette action est irréversible. ».
- Vide : « Aucune partie terminée ».

### 2.7 Règles de comptage (statique, `ScrollView` de `Text` localisés)
- Retrait des colonnes verticales de 3 cartes identiques (jamais horizontales) ; règle du clôturant avec les 6 exemples
  du cahier §3.2 ; fin à 100 après la manche, le plus petit total gagne, co-vainqueurs possibles.
- Mention : « Texte reformulé. En cas de doute, la notice de votre boîte de jeu fait foi. » Aucun visuel Magilano.

### 2.8 Paramètres (minimal)
- « Retours haptiques » (`Toggle`), « Supprimer toutes les données » (destructif, double confirmation), section
  « À propos » : version, « Fonctionne entièrement hors ligne. Aucune donnée ne quitte cet iPhone. »

## 3. Microcopie et VoiceOver

### 3.1 Boutons et identifiants d'accessibilité

| Élément | Libellé visible | VoiceOver (label · value · hint) | `accessibilityIdentifier` |
|---|---|---|---|
| Reprendre | « Reprendre la partie » | hint « 4 joueurs, 3 manches jouées » | `home.resume` |
| Nouvelle partie | « Nouvelle partie » | — | `home.newGame` |
| Champ prénom n | placeholder « Prénom du joueur n » | label « Prénom du joueur n » | `setup.player.<n>` |
| Ajouter joueur | « Ajouter un joueur » | — | `setup.addPlayer` |
| Commencer | « Commencer » | hint si désactivé « Saisissez au moins deux prénoms » | `setup.start` |
| Ligne joueur | — | « Alice, total 74 points, première place, en tête » (combine) | `game.player.<index>` |
| Ajouter manche | « Ajouter une manche » | — | `game.addRound` |
| Champ score | « — » | label « Score de Alice » · value « moins 3 » / « vide » | `round.score.<index>` |
| Bouton signe | « ± » | « Rendre négatif » / « Rendre positif » · hint « Score de Alice » | `round.sign.<index>` |
| Clôturant | nom | « Alice a terminé la manche » + trait sélectionné | `round.closer.<index>` |
| Enregistrer | « Enregistrer la manche » | hint si désactivé « Il manque : score de Bob » | `round.save` |
| Fin | « Partie terminée » | « Partie terminée. Vainqueur : Alice, 82 points » | `gameOver.title` |
| Rejouer | « Rejouer avec les mêmes joueurs » | — | `gameOver.replay` |
| Manche historique | « Manche n » | « Manche 3, Alice a terminé, score doublé de 10 à 20 » | `history.round.<n>` |

`<index>` = `displayOrder` (stable, testable) ; jamais le nom (doublons, caractères spéciaux).
Les nombres négatifs s'affichent avec `−` typographique (U+2212) via `formatted()` / `Int.formatted(.number.sign(strategy: .always()))`
pour les deltas ; VoiceOver lit « moins » (vérifier en test, sinon fournir `accessibilityValue` explicite).

### 3.2 Libellés de pénalité (produits par le Kit à partir de `DoublingReason`, localisés `Localizable.xcstrings`)
- Doublé, égalité : « Alice : 10 → 20 (score doublé : égalité avec Chloé) » (plusieurs : « égalité avec Chloé et Bob »).
- Doublé, meilleur score ailleurs : « Alice : 12 → 24 (score doublé : Bob a fait moins) ».
- Cas mixte (égal + inférieur) : priorité au plus petit : « (score doublé : Bob a fait moins) ».
- Non doublé, seul plus petit : « Alice : 10 (seul plus petit score, pas de pénalité) ».
- Non doublé, zéro : « Alice : 0 (zéro n'est jamais doublé) ». Négatif : « Alice : −2 (score négatif, jamais doublé) ».
- Badge court : « ×2 Doublé » ; VoiceOver « score doublé ».
- Lot 3 (cartes, pour cohérence) : « 3 cartes identiques : colonne non comptée » ; « Colonne retirée ».

### 3.3 Erreurs et états
- Sauvegarde en cours : « Enregistrement… » ; stockage : « Enregistrement impossible. Votre saisie est conservée. »
- Lecture : « Impossible de lire les parties enregistrées. » + « Réessayer ».
- Abandon de partie : « Abandonner la partie ? Elle restera consultable dans Parties terminées. » → « Abandonner ».

## 4. Tokens visuels minimaux (`DesignSystem/Theme.swift`, < 60 lignes)

| Token | Valeur | Toujours doublé par |
|---|---|---|
| `accent` | `AccentColor` : clair `#1A626A`, sombre `#58BEC9` (texte ≥ 4,8:1 sur tous les fonds) | libellé du bouton |
| `onAccent` | blanc (clair, 7,0:1) / noir (sombre, ≈ 9,6:1) : libellé des boutons proéminents | — |
| `secondaryText` | `#5C5C61` / `#AEAEB2` (contraste accru : `#3A3A3C` / `#D1D1D6`), ≥ 4,8:1 | — |
| `leader` | vert `#18692C` / `#30D158` | « En tête » + `crown.fill` |
| `doubled`, `warning` | orange `#9C4500` / `#FF9F0A` | « ×2 Doublé » + `multiply.circle.fill` ; texte + `exclamationmark.triangle.fill` |
| `destructive` | rouge `#B3261E` / `#FF6961` (actions destructives affichées dans l'écran) | texte explicite |
| Fond | `Color(.systemGroupedBackground)` ; surfaces `secondarySystemGroupedBackground` | — |

- Contraste ≥ 4,5:1 pour tout texte, clair et sombre (audit `performAccessibilityAudit`) : les couleurs système
  `.secondary`, `.tertiary`, `.orange`, `.green`, `.red` ne servent jamais de couleur de texte (≈ 2–3,4:1 en clair) ;
  en-têtes et pieds de sections et textes d'attente des champs reçoivent `secondaryText`. Pas de dégradé, pas
  d'ombres ; zone du CTA fixe opaque (`surface`), sans matériau translucide. Restent translucides : le bandeau
  « Annuler la suppression » de l'historique (temporaire) et la barre de capture du scan, posée sur l'aperçu caméra.
- Typo : totaux `.largeTitle` `.monospacedDigit()` bold ; scores de saisie `.title2.monospacedDigit()` ; noms
  `.title3` ; détails `.subheadline` `secondaryText`. Uniquement des styles Dynamic Type (pas de tailles fixes).
- Espacements : constantes `4, 8, 12, 16, 24` ; rayons `12` (lignes), `16` (cartes). Cible tactile ≥ 44 pt.
- Haptique : `.sensoryFeedback(.success, trigger:)` à l'enregistrement et à la fin de partie ; `.selection` au choix
  du clôturant ; `.warning` sur incohérence. Respect du réglage « Retours haptiques ». Rien d'autre.
- Reduce Motion : `@Environment(\.accessibilityReduceMotion)` → aucune `contentTransition` numérique, pas d'animation
  de victoire, transitions `.opacity` seulement.

## 5. Découpage en tâches parallélisables

Prérequis commun (T0, séquentiel, petit) : `Route`, `AppRouter`, protocole `GameRepository` + `InMemoryGameRepository`
(tests/previews), `Theme.swift`, `Localizable.xcstrings` initial. Ensuite les tâches T1–T7 touchent des dossiers distincts.

| Tâche | Fichiers (`TableScore/Features/…`) | Critères d'acceptation | Tests UI / unitaires |
|---|---|---|---|
| T1 Accueil | `Home/HomeView.swift`, `HomeModel.swift` | CTA unique selon état ; carte de reprise ; dialog partie active ; erreur de lecture | `testResumeAfterRelaunch` (kill/relaunch, `home.resume`) ; `HomeModelTests` |
| T2 Création | `GameSetup/NewGameView.swift`, `NewGameModel.swift` | 2–8 joueurs, doublons bloqués, réordonnancement sans changer les ids, focus suivant, Règles maison repliées | `testCreateGameTwoPlayers`, `testEightPlayersMax` (`setup.addPlayer` désactivé) ; `NewGameModelTests` (doublons, trim) |
| T3 Tableau | `Scoreboard/GameView.swift`, `PlayerScoreRow.swift`, `GameModel.swift` | ordre stable, leaders multiples, négatifs/3 chiffres lisibles, VoiceOver combiné, CTA fixe | `testScoreboardEightPlayersXXL` (lancement `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXL`) |
| T4 Saisie manche | `RoundEntry/RoundEntryView.swift`, `ScoreEntryRow.swift`, `CloserPicker.swift`, `RoundEntryModel.swift` | vide ≠ 0, signe, un seul clôturant, aperçu exact, CTA visible clavier ouvert, double-tap sans doublon | `testAddRoundWithPenaltyPreview` (10/24/10 → « 10 → 20 »), `testNegativeAndZeroEntry`, `testSaveDisabledUntilComplete`, `testDoubleTapSavesOnce` ; `RoundEntryModelTests` |
| T5 Fin de partie | `Results/GameOverSection.swift` | vainqueur(s) = plus petit total, co-vainqueurs, Rejouer, Reduce Motion | `testGameOverCoWinners`, `testReplaySamePlayers` |
| T6 Historique | `History/HistoryView.swift`, `HistoryModel.swift`, `InconsistencyAlert.swift` | brut/retenu/cumul, correction recalcule, suppression dernière + annuler, incohérence sans effacement silencieux | `testEditOldRoundRecomputes`, `testDeleteLastRoundUndo`, `testCorrectionCreatesEarlyFinishRequiresChoice` |
| T7 Secondaires | `FinishedGames/…`, `Rules/RulesView.swift`, `Settings/SettingsView.swift` | suppression confirmée, textes reformulés, toggle haptique | `testDeleteFinishedGameConfirmation` |

Commun à toutes les tâches : previews clair/sombre + XXL + 8 joueurs (dépôt en mémoire), aucune importation réseau,
aucune logique de score hors Kit (revue : rechercher `* 2`, `>= 100`, `min(` dans `Features/`), identifiants §3.1.
Arguments de lancement UI : `-uiTesting` → dépôt en mémoire vierge ; `-seed eightPlayers|nearEnd|tieEnd` → données
fixtures déterministes (fournies par T0), aucun accès disque persistant pendant les tests UI.

Ordre d'intégration recommandé : T0 → (T1, T2, T3, T4, T6, T7 en parallèle) → T5 (dépend de T3) → revue UX
(captures clair/sombre, iPhone SE 3e gén. + Pro Max) → audit qualité.

## 6. Points à arbitrer par la session maître

1. **Bornes de saisie manuelle** : proposition −24…144 (12 cartes × −2 / × 12, bornes arithmétiques, pas une règle
   officielle) ; alternative : seulement contrôle de débordement `Int`. Le Kit doit porter la décision.
2. **Une seule partie active** : créer une partie archive l'active (« Interrompue ») après confirmation. Alternative :
   plusieurs parties actives listées sur l'accueil (plus complexe).
3. **Cas mixte égalité + inférieur** : libellé « X a fait moins » prioritaire — formulation, pas de règle.
4. **Incohérence §4.6** : résolution obligatoire *avant* écriture (aucun état incohérent persisté) vs enregistrement
   puis bandeau persistant. Recommandé : avant écriture.
5. Suppression limitée à la **dernière** manche (cahier §4.6) ; suppression d'une manche intermédiaire non proposée.
6. Segment « Points | Cartes » : tranché et livré au Lot 3 (sélecteur par joueur, cf. §2.4).
7. Limite de 24 caractères par prénom et pas de 10 pour la cible « Règles maison » (choix UX, modifiables).
