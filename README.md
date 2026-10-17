# TableScore

Compteur de points pour iPhone destiné aux parties **physiques** du jeu de cartes Skyjo classique.
L'application remplace la feuille de score : saisie rapide des manches, pénalité du clôturant,
cumuls, fin de partie et historique corrigeable. Elle ne simule pas le jeu.

« TableScore » est un nom de travail. Aucun logo ni visuel Magilano n'est utilisé.
La référence produit est le [cahier des charges](CAHIER_DES_CHARGES.md).

## Prérequis

| Outil | Version |
|---|---|
| Xcode | 16.x (16.4 utilisé en CI) |
| iOS (cible minimale) | 18.0, iPhone uniquement |
| Swift | 6 (mode de langage Swift 6) |
| Simulateur | iPhone iOS 18.x |

Aucun compte développeur, secret ou configuration n'est nécessaire pour compiler et tester sur simulateur.
Le moteur de score (package `TableScoreKit`) se teste aussi sous Linux avec une chaîne Swift 6.

## Structure

```text
TableScore.xcodeproj/          Projet Xcode (dossiers synchronisés, schéma partagé « TableScore »)
TableScore/                    Application SwiftUI
  App/                         Point d'entrée (@main)
  Features/Home/               Écran d'accueil (provisoire au Lot 0)
  Resources/Assets.xcassets    Icône, couleur d'accent clair/sombre
TableScoreTests/               Tests unitaires de l'app (Swift Testing, app hôte)
TableScoreUITests/             Tests UI (XCTest)
Packages/TableScoreKit/        Package SwiftPM local : modèles + ScoreEngine pur (Foundation seule)
.github/workflows/ci.yml       Intégration continue
.claude/                       Agents et instructions de développement
```

Les dossiers `TableScore/`, `TableScoreTests/` et `TableScoreUITests/` sont des groupes synchronisés
(Xcode 16) : tout fichier ajouté sur disque est automatiquement inclus dans la cible correspondante.

## Compiler et tester en local

Moteur métier (macOS ou Linux) :

```sh
cd Packages/TableScoreKit
swift test
```

Application (macOS + Xcode 16) :

```sh
xcodebuild -list -project TableScore.xcodeproj
xcrun simctl list devices available          # choisir un iPhone iOS 18.x
xcodebuild test \
  -project TableScore.xcodeproj \
  -scheme TableScore \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5' \
  CODE_SIGNING_ALLOWED=NO
```

Adapter la destination à un simulateur réellement installé. Dans Xcode : ouvrir
`TableScore.xcodeproj`, schéma « TableScore », puis Produit › Tester (⌘U).

## Principes d'architecture

```text
Vues SwiftUI  →  état de présentation  →  ScoreEngine pur (TableScoreKit)  →  persistance locale
```

- **Aucune règle de score dans les vues** : le calcul vit dans `TableScoreKit`, pur, déterministe,
  sans E/S, testé indépendamment de SwiftUI et du stockage.
- **Une seule source de vérité** : scores bruts signés, clôturant et règles de la partie ; scores
  effectifs et cumuls sont toujours recalculés, y compris après correction d'une manche ancienne.
- Persistance locale (SwiftData prévu au Lot 1) dans le conteneur privé de l'app, sans CloudKit.
- Frameworks Apple uniquement ; aucune dépendance externe.

## Hors ligne absolu

L'application ne contient ni requête réseau, ni WebView, ni compte, ni publicité, ni télémétrie,
ni CloudKit, ni entitlement ou capability. Elle doit fonctionner en mode avion dès le premier lancement.
La CI fait échouer le build si une source Swift contient une API réseau (`URLSession`, `Network`,
`WebKit`, `CloudKit`…) ou une URL `http(s)://` hors ligne de commentaire, ou si le projet déclare un
entitlement, une exception ATS ou un mode d'arrière-plan.

## Intégration continue

`.github/workflows/ci.yml` s'exécute sur les pull requests vers `main`, les pushs sur `main` et à la demande
(pas de double exécution push + PR) :

1. **package-tests** (`ubuntu-24.04`, image officielle `swift:6.1.3` épinglée par digest) : contrôles
   statiques zéro réseau puis `swift test` du package.
2. **ios** (`macos-15`, Xcode 16.4) : lancé seulement si le premier job réussit ; sélection dynamique
   d'un simulateur iPhone iOS 18.x, `build-for-testing` puis tests unitaires et UI, sans signature.

Les modifications purement documentaires (`*.md`, `.claude/**`) ne déclenchent pas la CI.

## État d'avancement

- **Lot 0 — Fondation** : projet Xcode, coquille d'app, tests de fumée, CI, contrôles de sécurité. En cours.
- **Lot 1 — Moteur métier et stockage** : `TableScoreKit` (modèles, validation, ScoreEngine). En cours.
- Lots 2 à 4 (interface, saisie par cartes, fiabilisation) : à venir.

## Limitations connues

- Le projet Xcode a été écrit à la main dans un environnement sans Xcode : sa validité n'est
  **vérifiée que par la CI macOS**. Ouvrir le projet dans Xcode peut réordonner le fichier
  `project.pbxproj` sans changement fonctionnel.
- L'écran d'accueil est un emplacement provisoire : « Nouvelle partie » est désactivé.
- L'icône d'application n'a pas encore d'image (emplacements vides).
- Identifiant de bundle générique `app.tablescore.TableScore`, à adapter avant toute distribution.
