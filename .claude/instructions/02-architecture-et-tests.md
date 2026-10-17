# 02 — Architecture iOS, logique métier et tests

**Usage :** design technique, moteur de score, code Swift/SwiftData, migrations, correction des manches, tests.

## Produit et architecture

Référence : `CAHIER_DES_CHARGES.md`, notamment règles de Skyjo classique, priorités P0/P1/P2, cas limites et critères d'acceptation. Ne fais pas évoluer une règle sur une interprétation personnelle ; vérifie la notice Magilano ou signale l'ambiguïté.

- Swift 6 / SwiftUI / Foundation / SwiftData selon version Xcode vérifiée ; iOS 18+. Préférer frameworks Apple, architecture simple et faible empreinte mémoire.
- **ScoreEngine indépendant, pur, déterministe et testable** ; aucune règle métier cachée dans `View.body` ou la persistence.
- Une seule source de vérité pour scores bruts, identifiants de joueurs, clôturant, variantes choisies et manches. L'historique est la base des recalculs, pas un cumul modifié manuellement.
- `UUID` pour identité, `Int` signé pour points, modèles explicites, enums plutôt que constantes magiques, gestion des erreurs et des débordements. Aucune force-unwrap de données persistées non fiables.
- Persistance locale résiliente, opérations atomiques, écriture idempotente ou protection contre le double enregistrement, reprise sûre après fermeture forcée.
- Éviter singleton fourre-tout, logique dupliquée, dépendances tierces gratuites mais inutiles, méthodes géantes et commentaires répétitifs. Dépendances injectées simplement pour tests.

Structure indicative, à adapter au véritable projet :

```text
TableScore/
  App/
  Features/{Home,GameSetup,Scoreboard,RoundEntry,History,Results}/
  Domain/{Models,Scoring}/
  Data/LocalPersistence/
  DesignSystem/
  Resources/
TableScoreTests/
TableScoreUITests/
.claude/{agents,instructions}/
.github/workflows/
```

## Invariants Skyjo critiques

- Partie physique, 2 à 8 joueurs ; 12 cartes par personne, 4 colonnes verticales de 3. Valeurs possibles d'une carte : −2, −1, 0, 1…12.
- Colonnes retirées lorsque trois cartes identiques sont révélées, même au retournement final et même négatives ; jamais de suppression de ligne horizontale, jamais de retrait compté deux fois.
- Score de manche signé ; `0` doit être distingué de valeur manquante. Un seul clôturant.
- Si `closingRawScore > 0` **et** s'il existe un autre `rawScore <= closingRawScore`, doubler **seulement** la valeur du clôturant. Une égalité déclenche la pénalité. Pas de doublement pour négatifs ou zéro.
- Valider tous les participants puis calculer les points effectifs et les cumuls. Partie terminée **après la manche** dès qu'au moins un cumul atteint le seuil (100 par défaut).
- Vainqueur(s) = minimum du cumul final ; égalités possibles sans départage inventé. Ne pas confondre le leader d'une manche et le vainqueur final.
- Modification/suppression explicite d'une manche antérieure : recalcul déterministe **de toutes les manches suivantes**, y compris changement du statut de fin de partie.
- Mode « points » = flux principal, mode « cartes » = aide au comptage facultative, pas de simulation de jeu.

## Tests obligatoires

1. Tests unitaires pour score minimum strict, égalité, score positif, négatif, zéro, retraits de colonnes, seuil atteint, seuil franchi par plusieurs joueurs, égalité finale et valeurs extrêmes.
2. Tests d'historique : correction d'une manche ancienne, recomputation complète, tentative de doublon, interruption d'écriture, reprise après relancement, comportement après suppression autorisée.
3. Tests UI des parcours P0 (création → saisie → classement → correction → reprise), avec tailles d'écran courantes et 8 joueurs.
4. Tests de saisie incomplète, caractères invalides, dépassements `Int`, changements de joueur clôturant et variantes configurables.
5. Restitution factuelle : commande, destination, sortie (succès/échec), environnement, couverture manquante. Ne pas masquer les erreurs CI via `|| true`, `continue-on-error` ou suppression des tests obligatoires.

Sans simulateur/Xcode, ne pas annoncer que la compilation iOS a réussi ; effectuer seulement les vérifications réellement disponibles et expliciter les manques.
