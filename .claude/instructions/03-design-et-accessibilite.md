# 03 — Design, expérience utilisateur et accessibilité

**Usage :** écrans et composants SwiftUI, maquettes de flux, gestuelles, typographie, animations et revues UX.

## Direction artistique et comportement

Créer une expérience **native iOS élégante, moderne, sobre et chaleureuse**, avant tout pratique pendant une partie autour d'une table. Le téléphone peut être partagé entre joueurs ; écran très lisible à distance et sous différentes luminosités.

- Mise en page aérée, hiérarchie marquée, chiffres grands **tabulaires**, typographie SF, couleurs calmes et accents parcimonieux.
- Une action primaire par écran. Navigation courte et prévisible, grands éléments tactiles, retours contextuels discrets et explicites.
- Prioriser le temps de saisie d'une manche et la visibilité du classement ; les fonctions secondaires restent accessibles mais ne polluent pas la vue principale.
- Utilisation possible **d'une main**, y compris aux petits écrans ; état de validation toujours compréhensible.
- Saisies négatives et `0` facilement accessibles avec le clavier natif ; pas de clavier maison créé uniquement pour l'esthétique.
- Interface clair/sombre soignée, compatible Dynamic Type, VoiceOver, contrastes suffisants, Reduce Motion, préférences système.
- Animations courtes et utiles, pas d'effets de verre/transparence coûteux, de confettis envahissants ou de scroll / re-rendu superflu.
- Le design ne doit pas copier les logos, cartes, couleurs identitaires ou éléments protégés de Magilano sans autorisation.

## Parcours de référence

1. Ouvrir l'application et **reprendre** la partie existante, ou en créer une en quelques secondes.
2. Entrer 2–8 prénoms ; pouvoir réutiliser un groupe si cette fonction P1 existe.
3. Enregistrer une manche avec tous les scores signés et désigner clairement le clôturant ; visualiser la pénalité éventuelle **avant validation**.
4. Confirmer et retrouver immédiatement les **totaux**, le leader, les écarts et l'historique.
5. Corriger sans perdre les autres manches ; confirmation pour les opérations destructrices.
6. À la fin, montrer clairement les vainqueurs (y compris égalité), puis proposer nouvelle partie.

## Critères de revue UX

- Tester le flux *accueil → manche → classement* et relever le nombre d'interactions inutiles ; réduire la friction avant les options P2.
- Vérifier un groupe de **8 joueurs**, petits écrans, clavier ouvert, saisie négative, zéro, formulaire inachevé, erreurs, grandes polices, VoiceOver et utilisation sans internet.
- Revue indépendante à chaque changement d'UI important : captures/simulateur lorsque disponible, observations concrètes sur lisibilité, accessibilité, fatigue visuelle, temps de saisie et coût des animations.
- Préférer des composants natifs SwiftUI à un design system complexe. N'ajouter un composant partagé que lorsqu'il évite une duplication réelle ou renforce la cohérence.
- Évaluer mémoire, fluidité des listes de scores et scrolling ; éviter toute optimisation prématurée non mesurée.

**À charger avec** `02-architecture-et-tests.md` lorsque l'interface touche la logique de score, et `04-securite-et-confidentialite.md` pour toute saisie/persistance.
