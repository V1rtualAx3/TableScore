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
sans exclusion) sur chaque écran, juste après sa capture (`ScreenshotTests`, helper
`AccessibilityAuditUITests.swift`). Un défaut fait échouer le test sans interrompre le parcours ; chaque
problème est rapporté sous la forme « [écran] type d'audit — résumé — élément : … — détail », avec une
capture `audit-…` jointe au test en échec. La passe AX3 n'est pas auditée (captures seules).

## Limites

- Thème : appliqué par l'argument de lancement DEBUG `-uiTesting -uiTestingAppearance dark|light`
  (`preferredColorScheme` à la racine + `overrideUserInterfaceStyle` sur les fenêtres) ; le test vérifie la
  luminosité de la première capture et échoue si le thème n'est pas appliqué.
- Les captures reflètent le simulateur de la CI (un seul modèle d'iPhone). La vérification sur un petit
  et un grand iPhone (§10 n° 17) reste à faire sur au moins deux simulateurs.
- Aucun test sur appareil réel ni VoiceOver réel : l'audit automatique ne remplace pas un essai manuel.
