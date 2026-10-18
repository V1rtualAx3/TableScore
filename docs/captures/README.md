# Captures d'écran automatisées

Captures de chaque parcours principal, en thème clair et sombre, plus une passe Dynamic Type AX3
(cahier des charges §10 n° 16–17 et §11). Elles sont produites par les tests UI et ne sont **pas**
versionnées (aucun binaire dans Git) : la CI les publie en artefact.

## Où les trouver

1. GitHub, onglet **Actions**, exécution du workflow **CI** voulue (PR ou `main`).
2. Section **Artifacts**, en bas de la page de l'exécution : **`captures-ecran`** (archive zip,
   conservée 14 jours, publiée à chaque exécution du job iOS, qu'elle réussisse ou échoue).
3. Si le job échoue avant ou pendant les tests : l'artefact `TestResults-xcresult` (7 jours) contient
   le résultat complet, ouvrable dans Xcode.

## Liste des captures

Nommage : `NN-écran-thème`, thème = `clair`, `sombre` ou `ax3` (clair, texte AX3).
Les fichiers sont des images (PNG ou HEIC selon Xcode).

| N° | Écran | Jeu de données |
|---|---|---|
| 01 | `accueil-vide` : accueil sans partie | aucun |
| 02 | `creation-partie` : formulaire de nouvelle partie | aucun |
| 03 | `regles` : règles de comptage | aucun |
| 04 | `parametres` : paramètres | aucun |
| 05 | `accueil-reprise` : accueil avec « Reprendre la partie » | `eightPlayers` |
| 06 | `tableau-8-joueurs` : tableau des scores, haut | `eightPlayers` |
| 07 | `tableau-8-joueurs-suite` : tableau, après défilement | `eightPlayers` |
| 08 | `saisie-manche-penalite` : saisie 10 / 24 / 10, aperçu du doublement | `nearEnd` |
| 09 | `historique` : historique des manches | `withHistory` |
| 10 | `parties-terminees` : parties terminées | `withHistory` |
| 11 | `fin-de-partie-co-vainqueurs` : fin de partie, égalité | `tieEnd` |
| 12 | `cartes-consultation` : grilles de cartes en lecture seule | `withCards` |
| 13 | `saisie-par-cartes` : feuille de correction en mode Cartes | `withCards` |
| 14 | `selecteur-valeur-cartes` : sélecteur de valeur d'une carte | `withCards` |
| 15 | `verification-scan` : vérification d'un scan (8 cartes lues, 1 case à vérifier) | `nearEnd` + `-scanFixture partial` |

Passe `ax3` (Dynamic Type Accessibilité 3, 4 écrans) : `01-accueil-vide-ax3`, `02-creation-partie-ax3`,
`03-tableau-8-joueurs-ax3`, `04-saisie-manche-ax3`. Total attendu : 15 × 2 + 4 = **34** captures ; le
script d'export échoue s'il en trouve moins.

## Régénérer en local (Mac avec Xcode 16.x)

Dans Xcode : choisir le schéma `TableScore` et un simulateur iPhone iOS 18, puis ouvrir le navigateur de
tests (⌘6) et lancer `ScreenshotTests` (captures + audit) (ou ⌘U pour toute la suite). Les captures apparaissent dans le
rapport de tests (⌘9, onglet Rapports, pièces jointes du test).

En ligne de commande :

```bash
xcodebuild test \
  -project TableScore.xcodeproj -scheme TableScore \
  -destination 'platform=iOS Simulator,name=<iPhone disponible>,OS=18.<x>' \
  -only-testing:TableScoreUITests/ScreenshotTests \
  -resultBundlePath /tmp/captures.xcresult \
  CODE_SIGNING_ALLOWED=NO

bash scripts/ci/export-screenshots.sh /tmp/captures.xcresult /tmp/captures-ecran
```

Le script appelle `xcrun xcresulttool export attachments` ; `ScreenshotTests` seul produit déjà les
34 captures attendues (`MIN_CAPTURES`, 34 par défaut). Le simulateur doit utiliser le clavier logiciel
(Simulator, menu I/O, Clavier : « Connect Hardware Keyboard » désactivé).

## Audits d'accessibilité

Le parcours des 15 écrans de chaque thème exécute aussi `performAccessibilityAudit()` (audit complet,
tous types) sur chaque écran, juste après sa capture (`ScreenshotTests`, helper
`AccessibilityAuditUITests.swift`). Un défaut fait échouer le test sans interrompre le parcours ; la passe
AX3 n'est pas auditée (captures seules).

### Lire les résultats

- **Échecs** : un `XCTFail` d'une seule ligne par problème,
  « [écran] type d'audit — résumé — élément — détail », l'élément étant décrit par son type, son
  identifiant d'accessibilité, son libellé (70 caractères au plus) et son cadre (`@x,y largeur×hauteur`).
  Une capture `audit-<écran>` est jointe au test en échec.
- **Résumé de fin de parcours** (dans le journal, même si le parcours est interrompu) : bloc
  `===== RÉSUMÉ AUDIT ACCESSIBILITÉ (clair|sombre) … =====` de 150 lignes au plus : totaux par écran et
  par type, puis une ligne par problème distinct (écran | type | résumé | élément | ×occurrences). Il est
  imprimé à la fin de chaque test de thème, donc visible dans les 5 000 dernières lignes affichées par
  GitHub. Le résumé complet est joint au résultat de tests (`resume-audit-clair`, `resume-audit-sombre`,
  dans l'artefact `TestResults-xcresult` ; ignoré par l'export des captures).

### Exceptions (faux positifs)

Aucun type d'audit ni aucun écran n'est exclu globalement. Une exception n'est admise que pour un faux
positif **démontré**, déclarée dans `AccessibilityAudit.exemptions` avec écran, type d'audit, identifiant
(ou libellé exact) de l'élément, **preuve vérifiée à l'exécution** et justification, puis listée
ci-dessous. Preuves possibles : `inNavigationBar` (un élément de même type, même identifiant ou libellé et
même cadre existe dans `app.navigationBars`) ; `disabled` (`isEnabled == false` sur l'élément signalé).
Preuve non vérifiée, ou élément non identifiable (« élément non fourni ») : le problème reste un échec.
Un problème toléré n'échoue pas mais reste affiché dans le résumé (« TOLÉRÉ : raison »).

| Écran | Type | Élément | Preuve | Justification |
|---|---|---|---|---|
| 02 `creation-partie` | Dynamic Type | `setup.cancel` « Annuler » | `inNavigationBar` | Bouton de barre de navigation UIKit : taille de texte plafonnée par le système, Grand contenu à l'appui long ; non modifiable par l'app. |
| 02 `creation-partie` | Dynamic Type | « Modifier » (`EditButton` système) | `inNavigationBar` | Idem. |
| 08 `saisie-manche-penalite` | Dynamic Type | `round.cancel` « Annuler » | `inNavigationBar` | Idem. |
| 13 `saisie-par-cartes` | Dynamic Type | `round.cancel` « Annuler » | `inNavigationBar` | Idem. |
| 12 `cartes-consultation` | Dynamic Type | « OK » (fermeture de la feuille) | `inNavigationBar` | Idem. |
| 02 `creation-partie` | Contraste | `setup.start` « Commencer » | `disabled` | Formulaire vide à la capture : bouton désactivé. WCAG 1.4.3 exempte les composants inactifs ; la raison du blocage est affichée au-dessus en texte contrasté (`secondaryText`). |

Les boutons de retour système ne sont pas signalés ; les titres système de barre non plus (d'où le titre
système « Manche 3 · 8 joueurs » du tableau, voir ci-dessous).

### Corrections de fond (audit de la PR n° 5)

- **Contraste** : les couleurs système `.secondary`/`.tertiary`/`secondaryLabel` (≈ 3,1–3,4:1 en clair),
  `.orange`/`.green`/`.red` (≈ 2–3,6:1 en clair) et le texte d'attente des champs ne servent plus de
  couleur de texte ; jetons `Theme.Palette.secondaryText`, `leader`, `doubled`/`warning`, `destructive`
  (≥ 4,5:1 sur tous les fonds de l'app, clair et sombre), y compris en-têtes et pieds de sections de
  formulaires. Teinte `AccentColor` : clair `#1A626A`, sombre `#58BEC9` (l'ancienne teinte sombre tombait
  à 3,4:1 en texte sur `#1C1C1E`) ; libellé des boutons proéminents noir en sombre (`onAccent`, ≈ 9,6:1).
- **Texte potentiellement inaccessible** (textes visibles masqués à VoiceOver) : prénoms des lignes de
  saisie et titres de colonnes de la grille en texte simple exposé ; explications de la grille consultée
  exposées ; libellés de « Colonne retirée » et du bouton « Colonne N retirée » commençant par le texte
  visible (Contrôle vocal, WCAG 2.5.3).
- **Zone touchable** : bouton « OK » du sélecteur de valeur (cadre de 44 pt dans le libellé).
- **Troncature** : valeurs de cartes en taille idéale (`fixedSize`) au lieu de `lineLimit(1)` ; titre du
  sélecteur et titres de colonnes sur plusieurs lignes si besoin ; date et statut des parties terminées
  empilés quand ils ne tiennent pas sur une ligne.
- **Dynamic Type** : totaux en `.largeTitle` (style de texte direct, sans police arrondie recréée).

### Seconde passe (résumé de la CI sur 6653ff6 : 258 problèmes)

- **Contraste, texte sous la zone d'action** (06 « Classement » ; 08 « Chloé », « +10 », « Total : 23 →
  33 » ; 13 « Total brut », « Bob » ; 15 « 4 cartes à saisir ») : les cadres signalés sont **derrière** la
  zone d'action translucide (`safeAreaInset` + `.bar`), texte flouté. Probablement aussi 02 (« RÈGLES »,
  « Skyjo classique · 100 points », « Règles maison ») si le clavier, ouvert à l'arrivée sur le formulaire,
  a remonté la zone d'action pendant l'audit (non démontré : le cadre de « Commencer » est relevé plus tard,
  clavier fermé). Correction : `primaryActionInset` devient une zone **opaque placée sous** le contenu
  défilant (pile verticale, filet de séparation) ; plus aucun contenu ne défile derrière l'action.
- **Contraste, boutons secondaires** « Nouvelle partie » (05) et « Reprendre la photo » (15) : fond
  `.bordered` translucide posé sur le matériau `.bar` ; les mêmes boutons sur fond opaque (fin de partie,
  écran 11) passent. Corrigé par la zone opaque.
- **Contraste, écran 07** (« Chloé », « Élodie » en plein écran, lignes du haut) : capture prise après
  `swipeUp()`, défilement inertiel encore en mouvement pendant l'audit. Le parcours descend désormais par
  glissements freinés jusqu'au lien « Historique » puis attend l'immobilité (`waitUntilStill`).
- **Dynamic Type, tableau (06, 07)** : prénoms, rangs, écarts, « En tête », « Classement » étaient des
  enfants d'une `LazyVStack` ; les lignes de fin de partie, de même structure dans une pile ordinaire
  (écran 11), ne sont pas signalées (corrélation, cause à confirmer par le prochain résumé). Tableau en
  `VStack` (8 joueurs au plus, aucune perte mesurable). Prénom sans limite de lignes en tailles
  d'accessibilité.
- **Dynamic Type, titre du tableau** (« Manche 3 », « 8 joueurs » en `ToolbarItem(.principal)`) : titre
  système « Manche 3 · 8 joueurs » (Grand contenu fourni par le système).
- **Zone touchable** : aperçu du clôturant (`round.closerPreview`, 16 pt de haut) et sous-totaux de
  colonne (« Colonne 2, 6 points », 11 × 20 pt ; écrans 13 à 15) étaient des éléments regroupés **sans
  type** (« autre »), traités comme des commandes : trait `isStaticText` (ce sont des textes, non
  interactifs) ; sous-total sur toute la largeur de la colonne.
- **Texte tronqué** : aperçu du clôturant et résumé de blocage sans plafond de lignes (`lineLimit(2)` /
  `lineLimit(1)` en tailles d'accessibilité tronquaient la pénalité) ; toujours masqués en tailles
  d'accessibilité tant qu'un champ a le focus.
- **Restes sans cause établie** (à confirmer par le prochain résumé ; reproduction locale conseillée avec
  l'audit de l'Inspecteur d'accessibilité sur simulateur iOS 18) : Dynamic Type « partially unsupported » de
  textes de listes (`Form`/`List` : « Vos données… » 04, pied « De 2 à 8 joueurs… » 02, en-tête « POINTS DE
  LA MANCHE » 13, « Règles maison » 02, « Supprimer la dernière manche » 09) et « unsupported » non
  identifiés (08 ×9, 09 ×6) ; textes tronqués dans des listes (01 ×3, 04, 05 carte de reprise, 09, 10
  « Vainqueur : Bob », 12 « Colonne N — … ») ; champs « Prénom du joueur N » (02 : `TextField` sur une
  ligne, contenu défilant à l'édition) ; contraste non identifié en 09 sombre.

## Limites

- Thème : appliqué par l'argument de lancement DEBUG `-uiTesting -uiTestingAppearance dark|light`
  (`preferredColorScheme` à la racine + `overrideUserInterfaceStyle` sur les fenêtres) ; le test vérifie la
  luminosité de la première capture et échoue si le thème n'est pas appliqué.
- Les captures reflètent le simulateur de la CI (un seul modèle d'iPhone). La vérification sur un petit
  et un grand iPhone (§10 n° 17) reste à faire sur au moins deux simulateurs.
- Aucun test sur appareil réel ni VoiceOver réel : l'audit automatique ne remplace pas un essai manuel.
