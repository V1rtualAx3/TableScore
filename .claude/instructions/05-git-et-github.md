# 05 — Git, GitHub et Conventional Commits

**Usage :** gestion du dépôt, branches, commits, pull requests, fusion, audits Git, conventions.

## Politique du dépôt

- Commencer avec Git local. Utiliser un dépôt GitHub **seulement si** l'utilisateur l'a autorisé et qu'un remote/repo valable est connu ou créé avec autorisation ; **ne pas inventer** d'URL remote.
- Si création GitHub autorisée sans visibilité explicite : choisir **privé** et le signaler. Ne pousser aucune donnée ni code sans destination authentifiée/consentie.
- Branches courtes : `feat/...`, `fix/...`, `test/...`, `docs/...`, `chore/...` ; protéger `main` par PR et vérifications CI dès que possible.
- Un commit = une modification cohérente et vérifiable. Pas d'artefacts de compilation (`DerivedData`, `.build`, archives), certificats, profils, secrets ou fichiers locaux sensibles dans le suivi Git.

## Conventional Commits obligatoires

Syntaxe : `type(scope): imperative summary` (anglais concis et à l'impératif). Types : `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `style`, `build`, `ci`, `chore`.

Exemples :

```text
feat(score): apply closing player penalty
test(score): cover tied and negative rounds
fix(history): recompute totals after round edit
ci(ios): add simulator build and tests
```

Pour rupture réelle : `type(scope)!: ...` et pied `BREAKING CHANGE: ...` si nécessaire.

## Agents et garde-fous

- **`git-operator` = Haiku 5.5** pour `git status`, branches, commits, PR et inventaires `gh`. L'agent n'a pas de mission de modification de code source.
- Les conflits **sémantiques** et l'intégration de code difficile exigent Sonnet ou Opus suivant la complexité ; ensuite Haiku réalise la mécanique Git.
- Avant chaque commit : relire le diff, rechercher secrets, vérifier périmètre, lancer tests adaptés, vérifier que les fichiers attendus sont bien suivis.
- PR : objectif, références aux exigences, captures en cas d'UI, commandes/tests réellement exécutés, effet sur la sécurité et le réseau, risques, liens vers issues si présents, résultat de la revue indépendante.
- Pas de `git push --force`, `git reset --hard`, suppressions distantes, purge d'historique ou action destructive sans autorisation explicite.
- Ne pas créer de secrets GitHub en clair dans le dépôt, dans la CI, les logs, les issues ou les PR. Si un secret est exposé, arrêter, signaler et demander sa rotation.
- Les changements parallèles en worktrees doivent être revus et fusionnés **explicitement** ; attention à leur point de départ, parfois la branche par défaut.

Consulte aussi `06-ci-github-actions.md` pour création/maintenance de workflows et `07-validation-et-livraison.md` avant tout merge.
