# 01 — Sous-agents, routage et délégation

**Usage :** amorçage des agents, choix du modèle et effort, découpage du travail, parallélisation et intégration.

## Politique de modèles

| Nature réelle | Modèle exact | Profils |
|---|---|---|
| Lecture, documentation, recherche simple, exploration, inventaire, Git, GitHub, collecte de logs, tâches mécaniques | `claude-haiku-5-5` | `repo-scout`, `git-operator` |
| Code et tests simples à modérés (SwiftUI, SwiftData ordinaire, YAML CI standard) | `claude-sonnet-5-5` | `ios-implementer`, `test-engineer` |
| Architecture, code complexe, bugs difficiles, analyse structurante, audit sécurité ou revue critique | `claude-opus-5-5` | `systems-architect`, `security-auditor`, `quality-reviewer` |

Le maître **choisit l'effort par invocation** : `low` pour mécanique, `medium` pour code courant, `high` pour forte incertitude, `xhigh/max` si et seulement si risque ou complexité le justifient et si le modèle l'accepte. Ces exemples ne figent pas les réglages. Vérifie le modèle **effectif** (p. ex. `/tasks`). En cas d'indisponibilité d'une version 5.5, informe l'utilisateur au lieu d'utiliser une version différente sans autorisation.

Documentation : https://code.claude.com/docs/en/sub-agents . L'effort par invocation dépend de la version Claude Code installée ; `CLAUDE_CODE_EFFORT_LEVEL` peut l'écraser et `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` supprime le routage par tâche. Vérifie ces variables. Si le réglage par invocation n'est pas pris en charge, adapte le mécanisme avec la version installée sans déléguer le **choix** de l'effort.

## Profils opérationnels

Les profils sont **déjà fournis** dans `.claude/agents/` ; ne les régénère pas inutilement :

- `repo-scout` — Haiku ; `Read`, `Glob`, `Grep`, `Bash` de diagnostic non mutant ; lecture et conclusions factuelles.
- `git-operator` — Haiku ; `Read`, `Bash` ; opérations Git/GitHub, sans modification de code ni opérations destructrices.
- `ios-implementer` — Sonnet ; édition et test de modifications simples/modérées, y compris SwiftUI.
- `test-engineer` — Sonnet ; implémentation et exécution de tests courants.
- `systems-architect` — Opus ; architecture, domaine, migrations et code complexe.
- `security-auditor` — Opus ; analyse de sécurité **sans écriture**.
- `quality-reviewer` — Opus ; revue indépendante **sans écriture**.

Vérifie que les frontmatters comportent `name`, `description`, `model`, `tools` cohérents, et que les agents sont disponibles via `/agents`. Leur champ `model` est explicite ; **aucun effort figé dans leurs fichiers**, puisque le maître doit décider à chaque appel. Vérifie la compatibilité de l'outillage au démarrage. Certains changements de profils exigent de relancer la session.

## Contrat de mission minimal

Le prompt de délégation comporte : **objectif**, référence précise du cahier des charges, **fichiers à lire**, limites de modification, livrable attendu, **modèle/effort**, tests et critères de réussite, mode de restitution. Ne demande pas au sous-agent de lire toute `.claude/instructions/`.

Le compte rendu comporte : résultat concret, fichiers touchés, commandes exécutées, preuve des tests, risques, blocages, dépendances en attente. Un statut « tests OK » sans résultat ou explication ne vaut pas vérification.

## Parallélisme, relecture et intégration

1. Décompose en tâches courtes, indépendantes, testables ; évite le chevauchement de fichiers modifiés.
2. Lorsque plusieurs agents modifient le code en parallèle, privilégie `isolation: worktree` si compatible ; **vérifie la branche de départ** (le worktree peut partir de la branche par défaut plutôt que du `HEAD` courant).
3. Intègre/merge/cherry-pick explicitement après inspection ; ne présume pas que le contenu d'un worktree existe dans l'arbre principal.
4. Confie la revue à un **autre agent** : Opus pour sécurité, règles critiques, architecture ou changement complexe ; Sonnet pour revue simple non critique lorsque approprié.
5. Demande des corrections ciblées, relance les tests, puis délègue la mécanique Git au profil Haiku.
6. Ne crée pas de chaîne opaque d'agents se délégant mutuellement ni de parallélisme inutile ; le maître arbitre et garde la responsabilité finale.

Au premier lancement : confie à Haiku l'inventaire des outils (`swift`, `xcodebuild`, Xcode, simulateurs, `git`, `gh`), le contrôle des fichiers agents et de l'arborescence. Les changements incompatibles ou absences de modèle bloquantes sont signalés avant tout développement.
