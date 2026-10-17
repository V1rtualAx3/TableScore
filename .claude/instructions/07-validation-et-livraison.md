# 07 — Validation indépendante, définition de terminé et livraison

**Usage :** clôture d'une tâche, d'une PR, d'un jalon, d'une version ou revue finale de l'application.

## Démarrage recommandé

1. `repo-scout` (Haiku) : lire `CAHIER_DES_CHARGES.md`, inspecter les outils/agents/git et remonter les contraintes.
2. `systems-architect` (Opus) : proposer la structure légère, les invariants du domaine et les tests du moteur de score.
3. `ios-implementer` (Sonnet) : mettre en place un projet SwiftUI natif et les écrans P0 séquencés ; escalader à Opus toute implémentation réellement complexe.
4. D'abord stabiliser **ScoreEngine** et ses tests, puis développer la saisie de manches, le classement, les corrections et la reprise ; réaliser le mode « cartes » P1 ensuite.
5. `test-engineer` (Sonnet) : compléter les tests ; `quality-reviewer` (Opus) : revue technique indépendante ; `security-auditor` (Opus) : audit hors ligne/sécurité.
6. `git-operator` (Haiku) : préparer commits, branches, PR ; Sonnet implémente la CI standard après vérification Xcode ; intégrer seulement après les contrôles requis.

## « Terminé » signifie

- Respect du cahier des charges et de ses critères métier ; pas de règle officielle réinventée.
- Tests des cas limites et parcours pertinents **exécutés et documentés** ; compilation iOS vérifiée quand macOS/Xcode sont disponibles.
- Relecture d'un sous-agent **distinct de l'implémenteur**, puis corrections et nouveaux tests si nécessaires.
- Interface lisible, fluide, adaptée au partage d'un appareil, accessible (VoiceOver, Dynamic Type, clair/sombre, Reduce Motion).
- Aucun nouveau point de sortie réseau, SDK suspect, permission injustifiée, stockage distant ou secret introduit ; audit adapté au risque.
- Commits conventionnels, diff compris, PR revue ; CI verte si elle existe. Tout échec ou test impossible reste visible et ne se transforme pas en « vert ».

## Rapport final attendu du maître

1. Fonctions réalisées et limites par priorité (P0/P1/P2).
2. Fichiers et changements d'architecture importants ; captures si UI et simulateur disponibles.
3. Tests et build réellement exécutés (commandes, résultats, environnement) + ce qui n'a pas été vérifié.
4. Résultats des revues qualité, UX et sécurité, blocages et risques résiduels.
5. Commits, branches, PR/CI si existants, sans inventer d'URL.
6. Prochaines étapes priorisées ; aucune promesse de validation future présentée comme acquise.

**En cas de conflit :** préserver les impératifs du fichier racine `CLAUDE.md`, du `CAHIER_DES_CHARGES.md`, le zéro réseau et la politique de modèles. Le maître doit expliquer les arbitrages plutôt que modifier silencieusement le périmètre.
