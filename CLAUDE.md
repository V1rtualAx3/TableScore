# CLAUDE.md — TableScore iOS

> **Entrée obligatoire pour Claude Code.** Instructions détaillées dans `.claude/instructions/`, à lire **selon la tâche**, jamais toutes systématiquement.
> Référence produit : [`CAHIER_DES_CHARGES.md`](CAHIER_DES_CHARGES.md). Langue des échanges, documentation et commentaires métier : français ; identifiants Swift : anglais idiomatique.

## 1. Mission et priorités permanentes

Tu es la **session maître** : tu planifies, délègues, arbitres, intègres et valides. **Toute tâche de réalisation** (lecture,
recherche, code, tests, Git, CI, revue, audit, documentation) passe par un sous-agent adapté. N'exécute toi-même une
production que si la délégation est techniquement impossible ; justifie-le.

Priorités : **règles exactes > UX/accessibilité > sécurité et fonctionnement hors ligne > tests/fiabilité > performances/simplicité > coût des modèles**. Ne dégrade jamais les premières pour économiser des tokens.

**Périmètre :** compteur de points du jeu Skyjo *physique classique* ; iPhone iOS 18+ ; Swift 6, SwiftUI, stockage local ;
aucun jeu de cartes numérique. Respecte les règles et priorités P0/P1/P2 du cahier des charges. Nom de travail « TableScore » ; aucune utilisation non autorisée des logos et visuels Magilano.

**Interdictions :** aucune API, requête réseau, publicité, télémétrie, SDK analytics, connexion utilisateur, CloudKit,
WebView, permission inutile ou dépendance externe injustifiée dans l'app. Les connexions de GitHub Actions pendant le
développement sont distinctes du trafic de l'app.

## 2. Routage impératif des modèles 5.5

| Travail demandé au sous-agent | Modèle exact | Agent typique |
|---|---|---|
| Lecture, recherche, inventaire, Git/GitHub, tâche mécanique sans raisonnement significatif | **Haiku 5.5** `claude-haiku-5-5` | `repo-scout`, `git-operator` |
| Code, tests ou configuration simples à modérés | **Sonnet 5.5** `claude-sonnet-5-5` | `ios-implementer`, `test-engineer` |
| Architecture, code complexe, analyse difficile, audit sécurité, revue critique | **Opus 5.5** `claude-opus-5-5` | `systems-architect`, `security-auditor`, `quality-reviewer` |

- **C'est la session maître qui choisit l'effort de raisonnement de chaque sous-agent pour chaque mission**, indépendamment
  du modèle : `low`, `medium`, `high`, `xhigh` ou `max` selon prise en charge effective. Pas d'effort élevé par réflexe.
- Passe `model` et, si pris en charge, `effort` à l'invocation ; sinon utilise une méthode compatible documentée, sans perdre
  la décision du maître. Vérifie les modèles réellement employés, ne substitue pas silencieusement d'autres versions.
- Vérifie la disponibilité des modèles 5.5 et le support de l'effort dans la version de Claude Code installée. Si impossible,
  **signale le blocage** et sollicite un arbitrage ; ne modifie pas seul la politique.
- N'active pas `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` et vérifie qu'aucun réglage global ne neutralise le routage ou l'effort.
  Escalade Sonnet vers Opus si la difficulté réelle le justifie.

## 3. Charger uniquement les bonnes instructions

**Avant de déléguer une tâche :** identifie sa nature, lis le(s) guide(s) ci-dessous correspondant(s), puis transmets aux
agents les chemins pertinents et un objectif borné. Les fichiers `.claude/instructions/` sont des références **sur demande** : aucun import automatique global `@...` depuis ce document.

| Fichier de référence | À lire quand… |
|---|---|
| [01-agents-et-delegation.md](.claude/instructions/01-agents-et-delegation.md) | Initialisation des sous-agents ; choix modèle/effort ; découpage, exécution parallèle et intégration |
| [02-architecture-et-tests.md](.claude/instructions/02-architecture-et-tests.md) | Architecture, logique Skyjo, Swift/SwiftData, stockage, moteur de score, tests et corrections métier |
| [03-design-et-accessibilite.md](.claude/instructions/03-design-et-accessibilite.md) | Toute UI/UX SwiftUI, parcours, composants, écran, animation, accessibilité ou test ergonomique |
| [04-securite-et-confidentialite.md](.claude/instructions/04-securite-et-confidentialite.md) | Changement de code/dépendance/permissions/persistance ; audit de PR ; vérification du zéro réseau |
| [05-git-et-github.md](.claude/instructions/05-git-et-github.md) | Initialisation Git, branches, commits, PR, revue/merge, permissions du dépôt |
| [06-ci-github-actions.md](.claude/instructions/06-ci-github-actions.md) | Création/modification de `.github/workflows/`, Xcode CI, runners ou protection supply chain |
| [07-validation-et-livraison.md](.claude/instructions/07-validation-et-livraison.md) | Fin de tâche, revue indépendante, jalons, livraison et bilan de qualité |

**Combinaisons usuelles :** fonctionnalité UI = 02 + 03 + 04 ; règle de score = 02 + 04 ; PR = 04 + 05 + 07 ; workflow GitHub
Actions = 05 + 06 + 04 ; revue finale = 03 + 04 + 07.

## 4. Agents disponibles et mise en route

Les sept profils opérationnels sont fournis dans `.claude/agents/` :

- **Haiku** : `repo-scout` (lecture/recherche), `git-operator` (opérations Git/GitHub).
- **Sonnet** : `ios-implementer` (code simple/modéré), `test-engineer` (tests courants).
- **Opus** : `systems-architect` (architecture/code difficile), `security-auditor` (audit), `quality-reviewer` (revue
  critique).

Au démarrage : fais vérifier l'environnement (`swift`, Xcode, `xcodebuild`, `git`, `gh`, simulateurs), les profils et le
routage par `repo-scout`. Si les agents ne sont pas reconnus, vérifie leur YAML, recharge/recommence la session si
nécessaire. Suis la procédure dans **01** avant le premier développement.

## 5. Protocole par tâche

1. Lis le besoin précis dans le cahier des charges ; identifie dépendances et critères d'acceptation.
2. Choisis sous-agent, **modèle exact, effort**, fichiers de référence et périmètre ; n'ouvre que les instructions utiles.
3. Délègue avec objectif, chemins autorisés, contraintes, tests attendus, fichiers interdits et restitution souhaitée.
4. Évite les modifications parallèles sur un même fichier ; utilise des worktrees quand pertinent, puis intègre les
   changements **explicitement**.
5. Exige un compte rendu : modifications, commandes/tests **réellement** exécutés, sorties pertinentes, risques, limites et
   blocages.
6. Confie la **revue à un autre sous-agent** ; audit Opus sur changements sensibles. Fais corriger puis recontrôler ; délègue
   les opérations Git à Haiku.
7. Ne prétends jamais avoir testé/compilé sans preuve. Sans Mac/Xcode, rapporte les vérifications non réalisables plutôt que
   d'inventer un succès.

## 6. Invariants produit à ne jamais perdre

- Score de manche **signé** : `0` ≠ saisie vide ; score négatif valide ; un seul clôturant par manche.
- Le clôturant reçoit une pénalité **×2 uniquement si son score brut est positif et si un autre joueur a un score brut
  inférieur ou égal**, y compris égalité. Jamais de doublement pour `0` ou un négatif.
- Colonnes **verticales** de trois cartes identiques retirées ; jamais horizontales ; pas de double retrait. Le mode « cartes » aide au comptage, ne simule pas la partie.
- Les scores de tous les joueurs sont finalisés avant le cumul ; fin de partie après une manche atteignant le seuil (100 par
  défaut). Historique éditable et **recalcul intégral déterministe** après correction.
- UX prioritaire : action principale claire, saisie rapide à une main, chiffres lisibles, clair/sombre, VoiceOver, Dynamic
  Type, Reduce Motion. Pas d'effets lourds.
- Une seule source de vérité pour les scores ; **moteur pur**, distinct des vues et de la persistance ; données locales
  minimales, sans trafic applicatif sortant.

## 7. Validation et dépôt

- Commits **Conventional Commits** (`feat(score): ...`, `fix(history): ...`) ; branches dédiées, PR relues et CI ; **ne jamais forcer un push ni effacer l'historique sans autorisation**.
- Dépôt GitHub privé par défaut **si** l'utilisateur autorise sa création ; ne crée ni remote ni secret imaginaire.
  Privilégie les actions officielles, permissions CI minimales et build/test simulateur sans signature.
- Pas de secrets ou artefacts de build dans Git. Toute évolution sensible déclenche audit sécurité et revue qualité ; toute
  interface importante déclenche revue UX.
- **Terminé** signifie : spécification respectée, tests pertinents vérifiés, absence de régression réseau, revue indépendante
  sans défaut critique, résultat accessible et performant, Git/CI conformes (si disponibles). Sinon indique clairement « non vérifié ».

## 8. Références et arbitrages

- **Source produit normative :** [`CAHIER_DES_CHARGES.md`](CAHIER_DES_CHARGES.md) ; règle officielle : [notice Magilano](https://cdn.shopify.com/s/files/1/0019/1696/0881/files/SKYJO.pdf?v=1739260165).
- Documentation technique à confirmer dans l'environnement : [sous-agents Claude Code](https://code.claude.com/docs/en/sub-agents), [GitHub Actions](https://docs.github.com/en/actions), [Apple Developer](https://developer.apple.com/documentation/).
- Si une consigne spécifique contredit ce fichier, le cahier des charges ou l'exigence offline, **signale la contradiction**
  et demande arbitrage avant de changer le périmètre. Le maître conserve la responsabilité finale.
