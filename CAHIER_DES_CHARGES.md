# Cahier des charges — Compteur de scores Skyjo pour iOS

> Version : 1.0 — 17 octobre 2026  
> Statut : spécification de référence pour l'implémentation par Claude Code  
> Nom de travail : **TableScore** (provisoire ; éviter de présenter le produit comme une application officielle Magilano)  
> Cible : iPhone, iOS 18+, interface française ; architecture compatible iPad et localisation future.

## 1. Synthèse et intention produit

Créer une application iOS **élégante, moderne, extrêmement simple à utiliser et entièrement hors ligne** pour remplacer le carnet de scores du jeu de cartes physique **Skyjo classique** de Magilano. L'application ne simule pas le jeu : les joueurs manipulent toujours leurs cartes physiques et utilisent un seul iPhone commun pour compter leurs points en fin de manche.

**Promesse UX** : démarrer en quelques secondes, enregistrer les scores d'une manche sans calcul mental si souhaité, lire immédiatement qui mène, corriger une erreur sans perdre la partie et reprendre exactement là où l'on s'était arrêté.

Principes non négociables : **offline-first absolu, zéro compte, zéro publicité, zéro collecte de données, zéro télémétrie, aucune API ni connexion réseau nécessaire**. Le réseau n'est pas une dépendance fonctionnelle, même au premier lancement.

## 2. Périmètre et priorités

| Priorité | Fonction | Attendu |
|---|---|---|
| P0 | Créer une partie | 2 à 8 joueurs, prénoms personnalisés, configuration officielle par défaut |
| P0 | Saisir une manche | Valeurs entières avec signe pour chaque joueur, une seule personne qui a clos la manche, validation rapide |
| P0 | Calcul des règles | Doublement conditionnel automatique, cumul, fin de partie au seuil de 100 |
| P0 | Classement et historique | Totaux, détail des manches, gagnant(s), corrections sûres |
| P0 | Persistance locale | Récupération après fermeture ou interruption, sans réseau |
| P0 | UX et accessibilité | SwiftUI natif, Dark/Light, Dynamic Type, VoiceOver, réduction d'animations |
| P0 | Tests/CI/sécurité | Tests métier, tests UI critiques, revue sécurité, GitHub Actions |
| P1 | Saisie « cartes » | Grille visuelle 3 × 4 par joueur ; colonnes retirées ; calcul automatique |
| P1 | Variantes explicites | Seuil de fin personnalisable, option de pénalité désactivable uniquement en mode « règles maison » |
| P1 | Profils réutilisables | Réutiliser rapidement les mêmes joueurs entre parties |
| P2 | Statistiques | Évolution du score, victoires, moyenne par manche, records |
| P2 | Export à l'initiative de l'utilisateur | CSV/JSON ou partage de résultat via feuille native iOS |
| P2 | Scanner les cartes d'un joueur (prototype) | Photo prise dans l'app, lecture **sur l'iPhone** ; pré-remplit la grille du mode « cartes », toujours **à vérifier** avant l'enregistrement habituel de la manche (voir exception ci-dessous) |

**Hors périmètre** : jeu numérique avec cartes animées, multijoueur en ligne, compte, cloud, synchronisation, IA, OCR/caméra (sauf l'exception P2 ci-dessous), classement social, notifications push, Apple Watch, achats intégrés et SDK analytique. Une fonctionnalité nouvelle doit démontrer un gain UX net et ne pas sacrifier la performance ou la confidentialité.

**Exception P2 — « Scanner les cartes d'un joueur » (décision explicite de l'utilisateur, 2026-10-18)** : contradiction assumée avec « OCR/caméra » et « aucune permission », limitée à ce seul prototype et aux conditions suivantes :

- prise de vue **directe dans l'app** ; autorisation appareil photo (`NSCameraUsageDescription`) demandée **au premier usage seulement**, avec le texte : « TableScore utilise l'appareil photo pour lire les cartes d'un joueur et pré-remplir son décompte. L'image est analysée sur l'iPhone, puis effacée : elle n'est ni conservée ni envoyée. » Aucune autre permission (photothèque, micro, localisation…) ;
- traitement **100 % sur l'appareil** (reconnaissance de texte Vision) ; aucune image conservée (ni fichier, ni photothèque) ni transmise ;
- résultat = **pré-remplissage** de la grille du mode « cartes » (§3.3), cases incertaines laissées vides et signalées ; **aucune validation automatique**, aucune colonne retirée automatiquement, jamais d'écrasement silencieux d'une grille déjà saisie ; rien n'est enregistré avant l'action habituelle d'enregistrement de la manche ;
- refus ou restriction de l'autorisation, ou absence d'appareil photo ⇒ saisie manuelle intacte ;
- détails UX et limites : `docs/ux/scan-cartes.md`.

## 3. Règles de Skyjo classique à implémenter

### 3.1 Référence et domaine

Référence prioritaire : notice multilingue publiée par Magilano, pages françaises imprimées 10–11 (pages PDF 10–11 en numérotation visible ; index PDF 9–10) :  
https://cdn.shopify.com/s/files/1/0019/1696/0881/files/SKYJO.pdf?v=1739260165  
Centre de téléchargement éditeur : https://magilano.com/pages/download

- **2 à 8 joueurs** ; **12 cartes** par joueur en **4 colonnes de 3**.
- Valeurs des cartes classiques : **−2, −1, 0, 1 … 12**. Les scores par manche peuvent être négatifs ou nuls.
- Au début, chaque joueur retourne deux cartes ; la première manche commence avec la somme de cartes visibles la plus élevée. Les manches suivantes commencent avec la personne qui a terminé la manche précédente.
- Une manche est déclenchée lorsqu'un joueur a révélé toutes ses cartes ; chaque autre joueur effectue encore **un dernier tour**. Ensuite les dernières cartes cachées sont retournées.
- **Toute colonne verticale** composée de trois cartes identiques révélées est retirée, y compris lors du décompte final. Une ligne horizontale identique ne compte pas. Les colonnes retirées ne contribuent pas au score.
- Le score de base de chaque joueur correspond à **la somme des cartes restantes après retraits**.
- Le joueur qui a terminé la manche (le **clôturant**) doit être **seul avec le plus petit score de base de la manche**. Si au moins un autre joueur a un score **inférieur ou égal**, **son score de manche est doublé**, mais **uniquement si ce score est strictement positif**. Ne jamais doubler zéro ni un score négatif.
- On additionne les scores de manche retenus aux scores cumulés. **À la fin d'une manche**, dès qu'**au moins un joueur atteint 100 points ou plus**, la partie se termine ; la personne ayant le plus petit cumul gagne.
- Pour une **égalité du meilleur cumul final**, afficher des **co-vainqueurs** : la notice ne définit pas de départage. Ne pas inventer de règle officielle supplémentaire.
- **Ne pas confondre** Skyjo classique, Skyjo Action et Skyjo Junior.

### 3.2 Algorithme de référence

```swift
// Entrées de manche : un score brut entier par joueur + l'identifiant unique du clôturant.
// Les scores bruts sont calculés AVANT toute éventuelle pénalité.
let closingScore = rawScores[closingPlayerID]!
let anotherPlayerIsAtLeastAsGood = rawScores.contains {
    $0.key != closingPlayerID && $0.value <= closingScore
}
let mustDouble = closingScore > 0 && anotherPlayerIsAtLeastAsGood
let closingEffectiveScore = mustDouble ? closingScore * 2 : closingScore

// Pour tous les autres joueurs : effectiveScore = rawScore.
// Les cumuls s'actualisent uniquement après validation de tous les joueurs.
// Après la manche complète : gameOver = totals.values.contains { $0 >= targetScore }
// Le(s) vainqueur(s) = tous les joueurs dont le total est égal au minimum.
```

Exemples impératifs :

| Bruts de manche | Clôturant | Score retenu du clôturant | Cause |
|---|---|---:|---|
| Alice 10, Bob 24, Chloé 10 | Alice | **20** | Égalité : pénalité |
| Alice 10, Bob 11 | Alice | **10** | Plus petit score strict |
| Alice 12, Bob 9 | Alice | **24** | Bob fait mieux |
| Alice −2, Bob −4 | Alice | **−2** | Négatif : jamais doublé |
| Alice 0, Bob −1 | Alice | **0** | Zéro : jamais doublé |
| Alice −5, Bob −5 | Alice | **−5** | Négatif malgré égalité |

**Attention** : comparer les **scores bruts de la manche**, jamais les scores cumulés ni le score du clôturant déjà doublé.

### 3.3 Mode de saisie des cartes (P1)

- Présenter la grille finale de chaque joueur en **3 rangées × 4 colonnes** ; chaque case présente l'une des valeurs de carte `−2 … 12`.
- Un emplacement peut être « carte présente » ou « colonne retirée ». Le retrait concerne nécessairement les **trois emplacements d'une même colonne**, jamais une case isolée.
- Proposer un bouton **« Colonne retirée »** afin d'indiquer qu'elle a été éliminée pendant la manche. Elle contribue `0` au total et n'exige plus de saisir ses trois anciennes valeurs.
- Si les **trois valeurs saisies dans une colonne présente sont identiques**, retirer cette colonne du calcul automatiquement, même si la valeur est négative. Afficher une explication visible, sans effacement silencieux des saisies : « 3 cartes identiques : colonne non comptée ».
- Interdire la validation tant qu'il subsiste des cartes présentes non renseignées. **Zéro est une vraie valeur**, distincte d'une case vide.
- Afficher le score brut en direct. Autoriser correction, annulation et bascule vers saisie manuelle **sans perdre les données déjà validées de la manche** ; prévenir en cas de brouillon non convertissable.
- Le mode cartes sert au **décompte final**, pas au suivi de toutes les actions ou de la pioche pendant le jeu.
- Pour la saisie manuelle, les joueurs ont déjà retiré les colonnes physiquement : l'application **ne doit pas soustraire de colonnes une seconde fois**.

## 4. Parcours UX et écrans

### 4.1 Accueil (1 action pour reprendre)

- Accroche claire et sobre ; bouton principal **« Nouvelle partie »**.
- Si une partie est active, gros bouton **« Reprendre la partie »**, accompagné du nombre de joueurs, de la manche et du dernier enregistrement.
- Accès secondaire à **« Parties terminées »**, « Règles de comptage » et « Paramètres ».
- Aucun onboarding imposé, aucune permission au lancement, aucune inscription.

### 4.2 Création de partie

- Ajouter 2 à 8 joueurs : champs prénom, boutons rapides, suggestion de prénoms enregistrés localement ; éviter les doublons ambigus (les distinguer visuellement ou proposer renommage).
- Ordre des joueurs modifiable sans effet sur leurs identifiants stables.
- Règles **« Skyjo classique · 100 points »** présélectionnées. Variante/limite personnalisée dans un réglage replié, explicitement intitulé « Règles maison ».
- Bouton **« Commencer »** affiché dès que les 2 joueurs minimum ont des noms valides. Gestion clavier : retour, Done, focus suivant.

### 4.3 Partie en cours — écran central

Écran à optimiser en priorité pour une table familiale :

- En-tête compact : « Manche 4 », compteur de joueurs, bouton menu discret.
- **Scores cumulés très visibles**, avec noms, rang et indication claire du ou des leaders. Les totaux négatifs doivent être lisibles. Ne pas laisser une couleur seule porter l'information.
- Conserver un **ordre stable des participants pendant la saisie**, même si le classement évolue ; un classement visuel secondaire peut être trié.
- Gros CTA fixé près de la zone atteignable du pouce : **« Ajouter une manche »**.
- Option de consulter le déroulé de toutes les manches par une interaction naturelle (section « Historique » ou vue dédiée).
- Pas de graphique imposé au premier écran, ni carrousel horizontal obligatoire, ni interface ressemblant à une feuille Excel.

### 4.4 Ajouter une manche — opération la plus fréquente

- Ouvrir une **feuille native** ou un écran dédié, sans perdre le contexte des cumuls.
- Indiquer tous les joueurs, un **champ numérique signé** par joueur et une sélection explicite unique **« Qui a terminé la manche ? »**.
- Mode « Points » par défaut : clavier numérique adapté, prise en charge du signe `−` (un `numberPad` seul ne fournit pas forcément de signe négatif : prévoir un bouton `−` accessible), `0` valide, champs vides distincts.
- Permettre enchaînement rapide de la saisie de joueur en joueur, sans clavier masquant le bouton de confirmation. Cible UX indicative : **moins de 20 secondes** pour 4 joueurs déjà équipés de leurs scores calculés.
- Aucune validation tant qu'un joueur manque ou qu'aucun clôturant n'est choisi. Toujours **un et un seul clôturant**.
- Prévisualisation **avant confirmation** : « Alice : 10 → 20 (score doublé : égalité avec Chloé) » ou raison de non-doublement, plus cumuls à venir.
- Bouton final unique **« Enregistrer la manche »** ; une seule transaction atomique, protection contre double-tap/double insertion.
- Saisie par cartes (P1) accessible via un sélecteur clairement nommé « Points | Cartes », sans détour obligatoire.

### 4.5 Résultat de manche et fin de partie

- Après enregistrement : mouvement discret des chiffres, badge informatif lorsqu'une pénalité a été appliquée, classement mis à jour.
- Si seuil atteint : écran **« Partie terminée »**, nom(s) du/des gagnant(s), scores finaux, nombre de manches et bouton « Rejouer avec les mêmes joueurs ».
- Ne pas confondre « première personne à atteindre 100 » et gagnant : **le plus petit cumul gagne**.
- En cas d'égalité finale, annoncer explicitement tous les co-vainqueurs.
- Une animation de victoire courte peut exister, désactivée avec « Réduire les animations ».

### 4.6 Historique, modifications et reprise

- Historique par manche avec score **brut**, score **retenu**, pénalité et clôturant, ainsi que cumul obtenu après la manche.
- Modifier une manche passée puis **recalculer de façon déterministe toutes les manches suivantes**, car une pénalité modifiée affecte les cumuls futurs.
- Après recalcul, si une manche ancienne aurait dû arrêter la partie à 100 et qu'il existe des manches ultérieures, **ne rien effacer automatiquement** : afficher une incohérence, demander une décision explicite (par exemple supprimer les manches postérieures après confirmation ou revenir sur la correction).
- Suppression de la dernière manche avec confirmation et possibilité de revenir à l'état précédent ; pas d'édition destructrice silencieuse.
- Reprise instantanée après fermeture forcée de l'app ou redémarrage de l'iPhone.
- Archiver une partie terminée et conserver son historique ; action de suppression définitive toujours confirmée.

## 5. Direction artistique : élégance + lisibilité + vitesse

### 5.1 Langage visuel

**Référence esthétique** : qualité des applications iOS de premier plan, avec une identité calme et contemporaine. S'appuyer sur SwiftUI, les composants et interactions natifs d'Apple ; garder une personnalité propre au produit, **sans copier le graphisme ni les visuels protégés du jeu Skyjo**.

- Fond clair légèrement cassé et palette sombre réellement conçue pour le mode nuit ; pas d'aplats criards ni effet « casino ».
- Composants regroupés en surfaces légèrement contrastées, séparateurs légers, coins généreux et **hiérarchie typographique forte**.
- Typographie système SF : scores en **chiffres tabulaires**, tailles visiblement supérieures aux détails.
- **Une couleur d'accent** pour les actions principales ; couleurs ponctuelles pour « en tête », « score doublé », « avertissement ». Utiliser une étiquette textuelle également.
- Cartes et boutons tactiles de grande taille, espacements cohérents (grille 4/8 pt), CTA accessible d'une main.
- Pas de surcharge d'ombres, de dégradés, de transparences ou d'effets Liquid Glass gratuits ; utiliser les matériaux système **uniquement là où ils clarifient la hiérarchie**.
- Micro-interactions discrètes et haptique légère seulement sur validations importantes ; aucune animation longue bloquante.

### 5.2 Accessibilité et qualité UX

- Respect de **Dynamic Type**, contrastes, taille minimale de cible tactile environ **44 × 44 pt**, VoiceOver explicite (« Alice, total 74 points, première place »).
- Accessibilité des contrôles de sélection du clôturant, pénalité non exprimée uniquement par couleur, thèmes clairs/sombres, langue FR initiale.
- Respect des réglages **Reduce Motion**, Bold Text, augmentation du contraste et différentes tailles d'iPhone.
- États soignés : aucune partie, aucun historique, saisie partielle, sauvegarde en cours, erreur de stockage, partie terminée.
- Ne pas interrompre le jeu avec confirmations excessives : confirmation réservée aux actions destructrices, pas à chaque score saisi.
- Les contrôles et chiffres doivent rester lisibles avec le clavier ouvert et en conditions de luminosité variables.

### 5.3 Critères qualitatifs vérifiables

1. Démarrage et reprise sans écran d'attente artificiel, sans demande réseau.
2. Le parcours courant « reprise → manche → confirmation → classement » demande le moins de gestes possible.
3. Les scores de **8 joueurs** restent utilisables sans chevauchement ni police illisible ; préférer défilement vertical à miniaturisation.
4. Les chaînes longues, les scores négatifs et les nombres à 3 chiffres ne cassent jamais la mise en page.
5. Les interfaces ont une finition cohérente sur iPhone compact et grand format, en clair et en sombre.

## 6. Architecture et modèle de données

### 6.1 Choix de départ

- **Swift 6 / SwiftUI** ; cible minimale **iOS 18**, à confirmer au démarrage en fonction de la version Xcode stable disponible.
- **SwiftData** pour la persistance structurée locale, sans configuration CloudKit ; si un obstacle technique objectivé apparaît, proposer une solution locale simple (fichier JSON atomique ou SQLite) après justification.
- Architecture légère **UI SwiftUI → état/contrôleur de présentation → `ScoreEngine` pur → dépôt de persistance local**. L'interface n'implémente aucune formule métier.
- Limiter les packages externes ; préférer **Foundation, SwiftUI, SwiftData et XCTest/Swift Testing**.
- Éviter la complexité artificielle (pas de micro-services, serveur, DI framework, navigation router généraliste ou stockage distant).

### 6.2 Entités conceptuelles

```text
Game
  id: UUID
  title: String?
  createdAt / updatedAt / finishedAt: Date?
  status: active | finished | archived
  rules: {edition: classic, targetScore: 100, houseRules: ...}
  participants: [Participant] (ordre explicite et stable)
  rounds: [Round] (indice monotone)

Participant
  id: UUID
  displayName: String
  displayOrder: Int
  appearanceToken: String?  // repère visuel local facultatif

Round
  id: UUID
  index: Int
  closingParticipantID: UUID
  entries: [RoundEntry]
  createdAt / modifiedAt: Date

RoundEntry
  participantID: UUID
  rawScore: Int
  effectiveScore: Int        // calculable, jamais source de vérité autonome
  inputMethod: points | cards
  optionalCardGrid: CardGrid?

CardGrid
  4 colonnes × 3 positions : valeur entière de -2...12 OU colonne marquée retirée
```

Règles d'intégrité : UUID stables, aucune entrée pour un participant étranger à la partie ; une entrée par participant et manche ; clôturant membre de la partie ; indices de manches continus ; pas de score par défaut implicite ; calcul effectif systématiquement dérivé des scores bruts. **Source de vérité** : scores bruts + clôturant + règles de la partie ; ne pas faire dériver les cumuls stockés indépendamment sans contrôle.

### 6.3 Protection des données locales

- Toutes les données utilisateur restent **dans le conteneur privé de l'application**, sans CloudKit, serveur ni SDK de suivi.
- Utiliser la protection de données iOS adaptée et vérifier le comportement du stockage SwiftData lorsque le terminal est verrouillé ; ne pas promettre un chiffrement applicatif spécifique sans l'implémenter et le tester.
- Aucune permission système non nécessaire (seule exception : appareil photo du prototype P2 « Scanner les cartes », §2), aucun secret embarqué, aucun identifiant publicitaire.
- Les sauvegardes système de l'iPhone sont indépendantes de toute communication déclenchée par l'application ; ne pas activer explicitement de synchronisation.
- Export (P2) uniquement après une action volontaire et explicite de la personne, sans transfert automatique.

## 7. Fonctionnement strictement hors ligne et sécurité

- **Aucun appel réseau dans le runtime** : aucun `URLSession`, `Network.framework`, `WebKit`, `WKWebView`, sockets, analytics, SDK crash distant, remote config ou URLs distantes chargées par l'application.
- Ne déclarer ni capacités Background Modes, ni Push Notifications, ni entitlements réseau/CloudKit sans besoin validé.
- Ne pas ajouter de domaine ATS en exception ; aucun serveur ni backend.
- Images, icônes, palettes, police système et ressources nécessaires **embarquées dans l'application**.
- Minimiser la collecte ; l'app n'exige que les prénoms ou surnoms saisis volontairement et les scores.
- Aucun crash log transmis par du code maison ; les éventuelles données de diagnostic collectées par le système Apple dépendent des réglages iOS et de la distribution, et doivent être distinguées de la télémétrie de l'app.
- Menaces prioritaires : suppression involontaire, données corrompues, doublon de manche, altération d'un score après coup, fuite de secrets via dépôt/CI, dépendance transitive indésirable.
- Tests en mode avion (premier démarrage, saisie, fermeture/réouverture, historique, suppression) ; revue statique de toute importation ou permission réseau lors de chaque PR.

## 8. Performance et fiabilité

- Application légère, faible consommation mémoire, pas de travail continu en arrière-plan.
- `ScoreEngine` déterministe, sans E/S et testé indépendamment de SwiftUI/SwiftData.
- Limiter les rafraîchissements de vues ; recalcul rapide pour plusieurs dizaines/centaines de manches.
- Sauvegarde atomique à l'enregistrement ; rollback en cas d'échec ; indiquer les erreurs de persistance au lieu de simuler une réussite.
- Éviter une longue tâche principale lors du calcul ; fluidité prioritaire sur l'effet visuel.
- Aucun délai d'attente dû au réseau, aucun crash sur nom long, score nul/négatif, correction rétroactive ou perte de focus.

## 9. Plan de réalisation

### Lot 0 — Fondation

Créer le projet Xcode exécutable, structure répertoire claire, `.gitignore`, `README.md`, `CLAUDE.md`, agents, test target, schéma partagé, GitHub Actions, configuration iOS et contrôles de sécurité. Ne pas publier tant que le dépôt cible n'est pas confirmé.

### Lot 1 — Moteur métier et stockage (P0)

Modèles, calculs, invariants, historique recalculable, tests unitaires complets, persistance et restauration locale.

### Lot 2 — Interface et UX (P0)

Accueil, création/reprise, tableau des scores, saisie rapide, prévisualisation des pénalités, écran résultat, correction, fin de partie. Revues UX sur simulateur et captures clair/sombre.

### Lot 3 — Saisie par cartes (P1)

Grille et gestion des colonnes retirées, validation et bascule vers mode points, tests des triplets de valeurs négatives et du décompte final.

### Lot 4 — Fiabilisation et livraison

Tests d'intégration/UI, accessibilité, revue sécurité, test mode avion, optimisation, nettoyage du code, documentation, CI verte et PR de livraison avec résumé des décisions.

**Principe** : le premier incrément fonctionnel P0 doit être livrable et agréable à utiliser même si P1/P2 n'est pas encore réalisé.

## 10. Cas de tests obligatoires et critères d'acceptation

### Métier

1. Partie 2 joueurs et partie 8 joueurs valides ; 1 et 9 refusés.
2. Clôturant à 10, adversaire à 10 ⇒ clôturant 20 ; à 10 contre 11 ⇒ 10 ; à 12 contre 9 ⇒ 24.
3. Clôturant à 0 contre −1 ⇒ 0 ; à −2 contre −4 ⇒ −2 ; à −5 contre −5 ⇒ −5.
4. Un adversaire a un score inférieur et un autre supérieur ⇒ doublement du positif ; comparer tous les participants.
5. Colonne 7/7/7 ⇒ 0 ; colonne −2/−2/−2 ⇒ 0 ; ligne horizontale 5/5/5 ⇒ ne pas retirer.
6. Colonne complète lors du dernier dévoilement ⇒ retrait pris en compte ; colonne marquée retirée ⇒ aucun double retrait.
7. Score de manche négatif réduit le cumul ; calcul avec des totaux cumulés déjà négatifs.
8. 99 → 101 après une manche ⇒ fin ; 99 → 99 ⇒ continuation ; plusieurs joueurs >100 simultanément ⇒ gagnant au plus petit cumul.
9. Égalité au minimum cumulé ⇒ co-vainqueurs, pas de départage inventé.
10. Impossible de confirmer avec un joueur sans score, avec deux clôturants, ou de sauvegarder deux fois la même validation.
11. Modifier le score brut/clôturant d'une ancienne manche ⇒ tous les scores effectifs et cumuls ultérieurs recalculés correctement.
12. Correction créant une fin de partie antérieure ⇒ confirmation nécessaire, pas de suppression silencieuse.

### Produit, UX et sécurité

13. Après kill/relaunch de l'application, reprendre exactement une partie en cours.
14. Depuis l'accueil, création d'une partie et enregistrement d'une manche sans tutoriel.
15. Fonctionner à 100 % en mode avion, y compris au **premier lancement**.
16. VoiceOver annonce noms, scores et pénalités ; Dynamic Type ne tronque pas les actions principales.
17. Vérifier le thème clair et sombre sur au moins un petit et un grand iPhone.
18. Ne produire aucune requête réseau initiée par l'app durant les scénarios de tests ; aucun SDK de télémétrie ni autorisation superflue.
19. CI GitHub Actions : build simulateur + tests métier, et tests UI critiques selon stabilité du runner.
20. App utilisable sans aucun secret, compte développeur Apple ou configuration CI pour ses **tests locaux** (la distribution signée reste soumise aux exigences Apple).

## 11. Livrables attendus du développement

- Projet Xcode complet ouvrable, schémas partagés, ressources locales, code source lisible, tests.
- README : prérequis de versions, build/test local, principes d'architecture, règles, limitations connues.
- `CLAUDE.md` et `.claude/agents/` versionnés ; pipeline `.github/workflows/ci.yml`.
- Capture(s) d'écrans de chaque parcours principal, y compris thème sombre, issues ou journal des choix techniques.
- Rapport de revue qualité, sécurité, accessibilité et résultat des tests, avec limites explicitement signalées.
- GitHub : branches, commits conventionnels, PR relue, checks au vert ; aucune clé ni information privée dans le dépôt.

## 12. Questions non bloquantes / décisions par défaut

- **Nom définitif** : nom de travail « TableScore », à valider avant publication ; ne pas utiliser logos, graphismes ou identité visuelle Skyjo sans autorisation. Mention descriptive « compatible avec les règles du jeu de cartes Skyjo classique » seulement si les droits et la formulation sont vérifiés.
- **Distribution** : développement/test local d'abord ; App Store ou TestFlight seulement sur demande ultérieure, après vérifications légales et exigences Apple.
- **Règles maison** : hors du flux principal ; mode classique reste la valeur par défaut et l'algorithme est couvert par tests distincts.
- **Internationalisation** : français au lancement, préparer une architecture localisable pour l'anglais, sans retarder P0.

## Sources de référence

1. [Magilano — notice Skyjo classique multilingue, pages françaises 10–11](https://cdn.shopify.com/s/files/1/0019/1696/0881/files/SKYJO.pdf?v=1739260165) — source prioritaire des règles.
2. [Magilano — téléchargements officiels](https://magilano.com/pages/download).
3. [Documentation Claude Code — sous-agents](https://code.claude.com/docs/en/sub-agents).
4. [GitHub — GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

> Le présent cahier des charges reformule les règles nécessaires au logiciel ; il ne reproduit pas le livret original. En cas d'écart, la notice de l'édition physique utilisée par le joueur prime.
