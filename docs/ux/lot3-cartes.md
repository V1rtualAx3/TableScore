# Lot 3 — Saisie par cartes : décisions UX

> Normatif : `CAHIER_DES_CHARGES.md` §3.3, §4.4, §4.6. Complète `lot2-parcours.md` §2.4 (sélecteur livré au Lot 3).
> Tout calcul (total, triplets, colonnes retirées, validation) vient de `CardGrid.evaluate()` / `RoundDraft` (Kit).

## Décisions

1. **Sélecteur « Points | Cartes » par joueur** (contrôle segmenté sous la ligne nom + score, `round.inputMethod.<n>`),
   « Points » par défaut. Plus rapide qu'un sélecteur global : un toucher pour le cas fréquent (un seul joueur compte
   ses cartes), pas d'état « mixte » ambigu, sélecteur immobile lors de la bascule (retour immédiat). Coût : ~30 pt par ligne.
2. **Bascules sans perte** (points et grille conservés dans le brouillon). Cartes → Points : total pré-rempli si la
   grille est complète (règle du Kit : jamais d'écrasement d'une saisie manuelle). Sinon information non bloquante
   sous le champ (`round.cardsNotice.<n>`), annoncée à VoiceOver après un court délai.
3. **Pavé de valeurs −2…12 en feuille basse = exception assumée au guide 03** (« pas de clavier maison ») : elle est
   **fonctionnelle**, pas esthétique — 15 valeurs possibles seulement (aucune saisie invalide), un toucher par carte,
   zone du pouce, boutons natifs ≥ 44 pt lus « moins 2 » par VoiceOver.
4. **Ordre de saisie colonne par colonne** (haut → bas, puis colonne suivante ; colonnes retirées sautées) : il suit
   la structure verticale des colonnes Skyjo et rend un triplet visible dès sa troisième carte.
5. **Validation** : manche non enregistrable tant qu'une carte présente manque (« cartes d'Alice (3 cartes à saisir) ») ;
   « Suivant » du clavier mène ensuite à la première grille incomplète, sinon au choix du clôturant.
6. **Historique** : « (cartes) » sous le prénom, VoiceOver « …, saisi en cartes » ; ligne « Voir les cartes de la
   manche N » (`history.viewCards.<index>`) → feuille en lecture seule (même présentation et disposition 2 × 2 en
   tailles d'accessibilité que l'éditeur). Corriger = toucher la manche (grille rechargée, modifiable).
