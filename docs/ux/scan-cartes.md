# Prototype P2 — « Scanner les cartes d'un joueur » : décisions

> Décision utilisateur explicite du **2026-10-18** (cahier §2, exception P2) : prise de vue directe dans l'app avec
> autorisation appareil photo, contradiction assumée avec « OCR/caméra » et « aucune permission » pour ce seul périmètre.
> Normatif : `CAHIER_DES_CHARGES.md` §2, §3.3, §6.3, §7. Complète `lot3-cartes.md` (grille, sélecteur, colonnes retirées).

## Parcours

1. Mode « Cartes » d'un joueur → bouton **« Scanner les cartes »** (`camera.viewfinder`, `scan.start.<position>`) au-dessus
   de la grille. **Absent** sans appareil photo (simulateur) : la saisie manuelle reste strictement identique.
2. Écran plein écran : la **première** utilisation déclenche la demande système d'accès à l'appareil photo (statut
   `notDetermined` uniquement). Refus ou restriction : message, chemin « Réglages › TableScore › Appareil photo » **en
   texte**, bouton « Saisir à la main » ; aucune nouvelle demande, aucune donnée modifiée.
3. Aperçu en direct avec **cadre-guide 4 colonnes × 3 rangées** (tirets clairs sur liseré sombre), consigne « vues du
   dessus », un seul bouton **« Prendre la photo »** en bas (zone du pouce).
4. « Lecture des cartes… » : la session caméra est **arrêtée juste après la photo, avant l'analyse** (voyant éteint) ;
   analyse Vision **sur l'iPhone**, hors du main actor, limitée au cadre-guide (`regionOfInterest`, avec marge) ; photo
   ≤ 4032 px de grand côté quand l'appareil le permet. Interruption (appel, autre app) pendant l'aperçu : « Appareil
   photo interrompu », reprise automatique à la fin (ou « Réessayer »).
5. **Vérification** : bilan « N cartes lues sur 12 » + « K cases à vérifier » (symbole + texte), notes (case incertaine
   avec lecture probable « 6 ? », colonne vide « si elle a été retirée, touchez « Colonne retirée » », cases sans
   lecture), puis la **grille éditable** (même `CardGridEditor` : total, triplets et colonnes calculés par le Kit). Cases
   incertaines : **vides**, triangle d'avertissement et « à vérifier » pour VoiceOver.
6. **« Utiliser ces cartes »** → si le joueur avait déjà des cartes ou une colonne retirée : « Remplacer les cartes
   saisies ? » (Remplacer / Annuler). **« Reprendre la photo »** relance l'aperçu. **« Annuler »** ferme sans rien
   modifier. Rien n'est enregistré avant « Enregistrer la manche ».

## Décisions

- **Lien vers Réglages : non ouvert.** `check-no-network.sh` bloque l'ouverture d'URL par l'app (`openURL`,
  `UIApplication.shared.open`) ; plutôt que d'assouplir ce contrôle pour un seul lien système, le chemin est donné en
  texte. Coût : deux touchers de plus pour l'utilisateur qui change d'avis. Réversible si le maître l'arbitre (exception
  auditée limitée à `UIApplication.openSettingsURLString`).
- **AVFoundation plutôt que `UIImagePickerController`** : cadre-guide et bouton dans l'interface de l'app (VoiceOver,
  Dynamic Type, français), arrêt de la session maîtrisé, photo uniquement en mémoire (`AVCapturePhotoOutput`,
  `cgImageRepresentation()`), aucune vidéo ni son.
- **Logique pure `CardGridRecognizer`** (testée sans caméra) : valeurs −2…12 seulement (signes « - », « − », « – »,
  « — »), filtrage par la zone du cadre (cartes d'un voisin ignorées), fusion des doublons, séparation chiffres
  centraux / indices de coin, correction d'une rotation ≤ 20°, regroupement 1D en 4 colonnes puis 3 rangées. Une case
  est **incertaine** (laissée vide) si : confiance < 0,5, autre lecture proche (« 6 »/« 9 »), lectures contradictoires
  (doublon, indice de coin différent), signe moins lu séparément.
- **Place des cartes** : avec le cadre-guide (cas normal), colonne = position dans le cadre (largeur / 4), rangée =
  hauteur / 3, bornées et strictement croissantes ; une grappe déplacée pour respecter cet ordre devient « à vérifier ».
  Sans cadre (photo non cadrée) et grille incomplète sans indice d'écart : places **devinées** ⇒ cases vides « position
  incertaine (5 ?) » + note « Positions à vérifier ». Avec cadre, une rangée entière non lue n'empêche pas de placer les
  autres (les rangées ne sont jamais retirées au Skyjo).
- **Jamais automatique** : aucune colonne marquée retirée (une colonne vide est signalée), aucune validation, aucun
  écrasement silencieux.
- Retour haptique léger au résultat (réglage « Retours haptiques » respecté) ; aucune animation ajoutée (Reduce Motion).
- Tests UI : `-uiTesting -scanFixture complete|partial` (Debug uniquement) injecte des observations simulées qui passent
  par le vrai `CardGridRecognizer`, sans caméra ni demande d'autorisation.

## Contrôles CI liés

- `check-no-network.sh` : seule `NSCameraUsageDescription` (dans `*.pbxproj` / `*.plist`) ; plists en XML UTF-8
  uniquement (pas de bplist, UTF-16/32, entité, commentaire ni CDATA dans une clé) ; `INFOPLIST_FILE`,
  `INFOPLIST_PREPROCESS`, `GENERATE_INFOPLIST_FILE = NO` interdits ; encodage/export d'image, presse-papiers,
  sélecteurs système, `VisionKit`, `Speech`, `Translation`, `MLModelCollection` interdits.
- `check-info-plist.sh <DerivedData>` : Info.plist **produit** (plutil → jq), aucune `*UsageDescription` hors caméra,
  ni ATS, arrière-plan, Bonjour, réseau local ; texte caméra non vide.
- `check-binary.sh` : `Photos`, `PhotosUI`, `VisionKit` liés directement ⇒ échec (Vision et AVFoundation permis).

## Limites connues (prototype)

- **Non vérifiable sans iPhone réel** : demande d'autorisation, aperçu, orientation de la photo, qualité de lecture
  Vision sur de vraies cartes (éclairage, reflets, chiffres stylisés, indices de coin retournés), seuils `Tuning`.
- Photo en forte perspective (cartes vues de biais) : colonnes mal séparées possibles → cases vides ou à vérifier.
- Une ligne lue d'un bloc (« 57 ») est ignorée ; chiffres de cartes adjacentes fusionnés → cases à compléter.
