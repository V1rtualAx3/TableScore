# 06 — GitHub Actions : CI iOS et chaîne d'approvisionnement

**Usage :** `.github/workflows/`, configuration Xcode en CI, compilation/tests automatiques, permissions et dépendances.

## Initialisation vérifiée

Créer `.github/workflows/ci.yml` **une fois que le projet Xcode, le schéma partagé et les tests existent**. Ne pas inventer le nom de projet, schéma, configuration ou modèle de simulateur.

1. Événements : `pull_request` vers `main`, `push` sur `main`, éventuellement `workflow_dispatch`.
2. Runner **macOS GitHub Actions** supportant le Xcode retenu : contrôler les images réellement disponibles ; éviter les mises à jour Xcode silencieuses. Journaliser `xcodebuild -version`.
3. Permissions minimales : `permissions: contents: read`. Pour tests sur simulateur, **pas de signature Apple** ni secrets de distribution requis.
4. Inventaire : `xcodebuild -list` et `xcrun simctl list devices available`. Adapter dynamiquement ou fixer une **destination vérifiée** ; ne pas recopier aveuglément un nom de simulateur.
5. Lancer `xcodebuild build` puis `xcodebuild test` sur simulateur avec `CODE_SIGNING_ALLOWED=NO`, en transmettant les paramètres d'un vrai schéma et d'une vraie destination.
6. Ajouter limites de durée (`timeout-minutes`) et `concurrency` adaptée pour éviter des exécutions en doublon.
7. Examiner les logs ; ne jamais transformer un échec en succès via `|| true`, `continue-on-error` injustifié ou skip de test critique.

## Sécurité CI

- Utiliser `actions/checkout` officiel maintenu, de préférence fixé à un **SHA complet validé** ; vérifier toute action tierce avant utilisation. Ne pas ajouter de dépendances de build non nécessaires ni scripts `curl | sh` arbitraires.
- Vérifier absence de secrets en clair, permissions excessives, références réseau non prévues, entitlements et packages externes suspects.
- Verrouiller/contrôler les dépendances si présentes ; préférer aucun package externe.
- Les échanges réseau du runner pour télécharger le code/outils n'autorisent **aucun trafic réseau dans l'application**.
- Vérifier quota/coût des minutes GitHub Actions, surtout sur macOS et dépôts privés ; ne pas présumer des minutes illimitées.
- Ne pas ajouter automatiquement signature, provisioning, publication TestFlight/App Store ou deploy tant que la distribution n'est pas demandée et cadrée.

**Délégation :** Haiku pour inspecter l'environnement et GitHub ; Sonnet pour coder/modifier un workflow standard ; Opus pour architecture CI complexe ou audit sécurité conséquent. Le maître choisit l'effort en fonction du risque.

Références : https://docs.github.com/en/actions/reference/runners/github-hosted-runners et documentation Xcode/Apple correspondant au runner utilisé.
