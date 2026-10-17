# 04 — Sécurité, confidentialité et zéro réseau applicatif

**Usage :** tout changement de code touchant données, stockage, permissions, dépendances ou communication ; audit de PR avant fusion.

## Politique absolue

L'app doit être **pleinement fonctionnelle dès le premier lancement en mode avion**. Aucun compte, API, CloudKit, analytics, publicité, SDK de crash reporting tiers, trackers, push distant, WebView, achat intégré, téléchargement de ressources, requête réseau ou service externe **initié par le binaire** sans changement de périmètre explicitement autorisé. Utiliser uniquement stockage privé local et frameworks Apple requis.

La confidentialité est à différencier de l'activité réseau de **macOS/Xcode/GitHub Actions** pendant le développement et des sauvegardes système qu'iOS peut gérer hors du contrôle de l'app. Ne pas promettre « aucun trafic iOS » ; garantir ce qui dépend du code de l'application.

## Contrôles à chaque modification sensible

1. Audit des sources/dépendances pour `URLSession`, `NWConnection`, `Network`, `WebKit`, `WKWebView`, `Alamofire`, `Firebase`, `Sentry`, endpoints/URL distants, télémétrie, identifiants, imports suspects, packages et SDK.
2. Audit des entitlements, capabilities Xcode, `Info.plist`, déclarations de confidentialité, permissions système, background modes et configuration de build. Aucun droit non nécessaire.
3. Inspection des fichiers persistés : surnoms et points uniquement ; éviter données personnelles incidentes ; vérifier accès/protection du stockage SwiftData selon le cycle de vie, notamment appareil verrouillé. Ne pas affirmer un chiffrement qui n'a pas été vérifié.
4. Validation : `Int` signés, score vide distinct de zéro, contrôle d'overflow, ID de joueurs stables, un seul clôturant, cohérence du nombre de joueurs, sauvegarde atomique et anti-doublon.
5. Toute suppression/correction historique doit être volontaire, explicite et cohérente après crash/interruption. Signaler les erreurs de persistance de façon compréhensible ; ne jamais afficher de faux succès.
6. Tester **installation fraîche → création → manche → reprise** en mode avion et vérifier l'absence de trafic émis par l'application via des moyens raisonnables, sans installer de SDK de télémétrie pour cela.
7. Inspecter la sécurité de la CI, des dépendances, des journaux, des secrets et des données dans Git ; bloquer les changements non justifiés ou non autorisés.

**Audit indépendant :** `security-auditor` sur Opus 5.5 pour toute PR importante ou modification touchant persistance, permissions, dépendances ou réseau ; niveau d'effort décidé par le maître. Bloquer le merge en présence d'une régression critique non corrigée. Préciser preuves, limites des tests et actions correctives.

**Publication future :** vérifier les exigences Apple Privacy Manifest et les déclarations App Store uniquement en cas de publication ; ne pas affirmer « aucune donnée collectée » sans audit réel des binaires et dépendances.
