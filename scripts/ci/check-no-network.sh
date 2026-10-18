#!/usr/bin/env bash
# Contrôle statique « zéro réseau » de TableScore (heuristique, volontairement STRICT).
#
# Usage : check-no-network.sh [RACINE]   (défaut : répertoire courant)
#
# Choix assumés :
#  - TOUTES les lignes sont analysées, commentaires et littéraux inclus : un filtre
#    de commentaires est contournable (`/* */ let s = URLSession.shared`, blocs `"""`).
#    Conséquence : faux positifs possibles (ex. une URL citée en commentaire) ; il faut
#    alors reformuler le commentaire, pas assouplir le contrôle.
#  - `contentsOf:` est bloquant : `Data(contentsOf:)` sur un fichier local pourra devenir
#    légitime (import/export) ; il faudra alors un correctif explicite et audité ici.
#  - Le dossier scripts/ci/fixtures (cas négatifs de non-régression) est exclu, par chemin
#    exact relatif à la racine, de tous les scans.
#  - Permissions : UNE seule exception, `NSCameraUsageDescription` (prototype P2 « Scanner les
#    cartes », décision utilisateur du 2026-10-18, cahier §2), admise uniquement dans le projet
#    Xcode (*.pbxproj) ou un Info.plist. Toute autre clé *UsageDescription (photothèque, micro,
#    localisation…) reste bloquante, de même que les API d'enregistrement d'images/vidéo/son.
# Limite : une heuristique textuelle n'est pas une preuve ; elle est complétée par
# l'inspection binaire (check-binary.sh) et un test manuel en mode avion.
set -euo pipefail

root="${1:-.}"
cd "$root"

failures=0
LIST=()

fail() {
  echo "::error::$1"
  failures=$((failures + 1))
}

# list_files GLOB... : remplit LIST (hors .git, .build, DerivedData, fixtures).
list_files() {
  local args=() g
  for g in "$@"; do
    if [ ${#args[@]} -gt 0 ]; then args+=(-o); fi
    args+=(-name "$g")
  done
  LIST=()
  while IFS= read -r -d '' f; do
    LIST+=("$f")
  done < <(find . \( -path ./.git -o -path ./scripts/ci/fixtures -o -name .build -o -name DerivedData \) -prune \
             -o -type f \( "${args[@]}" \) -print0)
}

# scan DESCRIPTION REGEX [OPTIONS_GREP] : grep -E sur LIST ; échec si correspondance.
scan() {
  local desc="$1" re="$2" opts="${3:--}" out rc=0
  if [ ${#LIST[@]} -eq 0 ]; then return 0; fi
  out="$(grep -anHE"${opts#-}" -- "$re" "${LIST[@]}")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$desc"
    echo "$out"
  elif [ "$rc" -gt 1 ]; then
    fail "grep a échoué (code $rc) pour : $desc"
  fi
}

# scan_permissions DESCRIPTION : comme `scan`, pour les clés *UsageDescription, en retirant
# d'abord chaque occurrence EXACTE (bornée) de la clé caméra autorisée ; tout reste bloque
# (autre permission, même sur la même ligne, ou clé voisine comme NSCameraUsageDescriptionX).
scan_permissions() {
  local desc="$1" out line stripped rest="" rc=0
  if [ ${#LIST[@]} -eq 0 ]; then return 0; fi
  # -a : un fichier « binaire » (octets non textuels) est lu comme du texte, jamais ignoré.
  out="$(grep -anHE -- 'UsageDescription' "${LIST[@]}")" || rc=$?
  if [ "$rc" -gt 1 ]; then
    fail "grep a échoué (code $rc) pour : $desc"
    return 0
  fi
  if [ "$rc" -eq 1 ]; then return 0; fi
  # Ligne par ligne ; la ligne d'origine est affichée. Un échec de sed interrompt le script
  # (set -e) : il ne peut pas passer pour « rien trouvé ».
  while IFS= read -r line; do
    stripped="$(sed -E 's/(^|[^[:alnum:]_])(INFOPLIST_KEY_)?NSCameraUsageDescription([^[:alnum:]_]|$)/\1 \3/g' <<<"$line")"
    if [[ "$stripped" == *UsageDescription* ]]; then
      rest+="$line"$'\n'
    fi
  done <<<"$out"
  if [ -n "$rest" ]; then
    fail "$desc"
    printf '%s' "$rest"
  fi
}

# check_plist_format : chaque *.plist de LIST doit être du XML UTF-8 lisible par les scans
# textuels : ni plist binaire (bplist), ni BOM UTF-16/32, ni octet NUL, ni UTF-8 invalide ; aucune
# entité (&#85;…), ni commentaire, ni CDATA dans une clé (contournements du contrôle des clés).
check_plist_format() {
  local f head bad rc
  if [ ${#LIST[@]} -eq 0 ]; then return 0; fi
  for f in "${LIST[@]}"; do
    head="$(od -An -tx1 -N4 -- "$f" | tr -d ' \n')"
    case "$head" in
      62706c69*) fail "Plist binaire (bplist) interdit : $f"; continue ;;
      0000feff*|fffe*|feff*) fail "Plist en UTF-16/UTF-32 (BOM) interdit : $f"; continue ;;
    esac
    if od -An -tx1 -v -- "$f" | grep -qE '(^|[[:space:]])00([[:space:]]|$)'; then
      fail "Plist contenant un octet NUL (UTF-16/32 ou binaire) interdit : $f"
      continue
    fi
    if ! iconv -f UTF-8 -t UTF-8 -- "$f" >/dev/null 2>&1; then
      fail "Plist non UTF-8 interdit : $f"
      continue
    fi
    rc=0
    bad="$(grep -anE -- '<key>[^<]*(&|<!--)|<!\[CDATA\[' "$f")" || rc=$?
    if [ "$rc" -eq 0 ]; then
      fail "Entité, commentaire ou CDATA interdit dans un plist : $f"
      echo "$bad"
    elif [ "$rc" -gt 1 ]; then
      fail "grep a échoué (code $rc) pour : $f"
    fi
  done
}

# 1. Sources Swift ------------------------------------------------------------
list_files '*.swift'
if [ ${#LIST[@]} -eq 0 ]; then
  fail "Aucun fichier Swift trouvé : contrôle inopérant."
fi
swift_count=${#LIST[@]}

api_re='URLSession|URLRequest|NSURLConnection|NSURLSession|CFNetwork|CFStream|CFSocket|NWConnection|NWListener|NWBrowser|NWPathMonitor|WKWebView|WKNavigation|SFSafariViewController|ASWebAuthenticationSession|AsyncImage|CKContainer|CKDatabase|CKRecord|getaddrinfo|socket[[:space:]]*\(|contentsOf:|openURL|(^|[^[:alnum:]_])Link[[:space:]]*\(|UIApplication\.shared\.open|MCSession|GKLocalPlayer|SKPaymentQueue|ASIdentifierManager|ATTrackingManager'
scan "API réseau/sortie externe interdite (sources Swift)" "$api_re"

# Prototype P2 (appareil photo) : l'image reste en mémoire. Aucun enregistrement dans la
# photothèque ni de vidéo/son, aucun sélecteur de photothèque.
# Ni encodage de l'image (fichier, presse-papiers), ni sélecteur système, ni modèles téléchargés.
media_re='UIImageWriteToSavedPhotosAlbum|UISaveVideoAtPathToSavedPhotosAlbum|PHPhotoLibrary|PHAssetCreationRequest|PHPickerViewController|PhotosPicker|UIImagePickerController|AVCaptureMovieFileOutput|AVCaptureAudioDataOutput|AVAssetWriter|AVAudioRecorder|fileDataRepresentation|CGImageDestination|jpegData|pngData|heicData|UIPasteboard|MLModelCollection'
scan "Enregistrement, export ou accès photothèque/vidéo/son interdit (sources Swift)" "$media_re"

import_re='(^|[^[:alnum:]_])import[[:space:]]+([A-Za-z]+[[:space:]]+)?(Network|NetworkExtension|WebKit|SafariServices|CloudKit|MultipeerConnectivity|GameKit|StoreKit|AdSupport|AppTrackingTransparency|AuthenticationServices|MapKit|CFNetwork|Photos|PhotosUI|VisionKit|Speech|Translation|Alamofire|Firebase[A-Za-z]*|Sentry)([^[:alnum:]_]|$)'
scan "Import de framework réseau/tiers interdit" "$import_re"

# Schémas d'URL insensibles à la casse (HTTPS://, Wss://...).
scan "URL distante interdite (http, https, ws, wss, ftp)" '(https?|wss?|ftp)://' -i

# M6 : CloudKit/SwiftData synchronisé interdit (déjà couvert par import/CK*, explicite ici).
scan "Synchronisation CloudKit interdite" 'cloudKitDatabase[[:space:]]*:[[:space:]]*\.(automatic|private)|import[[:space:]]+CloudKit'

# 2. Code natif et chaîne d'approvisionnement -------------------------------------
list_files '*.m' '*.mm' '*.c' '*.cc' '*.cpp' '*.h' '*.hpp'
if [ ${#LIST[@]} -gt 0 ]; then
  fail "Code natif (Objective-C/C/C++) interdit :"
  printf '%s\n' "${LIST[@]}"
fi

list_files '*.pbxproj'
scan "Dépendance distante ou script de build interdits dans le projet Xcode" \
  'XCRemoteSwiftPackageReference|repositoryURL|PBXShellScriptBuildPhase'

# L'Info.plist est GÉNÉRÉ (clés INFOPLIST_KEY_* contrôlées ci-dessous) : aucun fichier Info.plist
# externe ni prétraitement, qui échapperaient au contrôle des clés.
list_files '*.pbxproj' '*.xcconfig'
scan "Info.plist externe ou prétraité interdit (INFOPLIST_FILE, INFOPLIST_PREPROCESS, GENERATE_INFOPLIST_FILE = NO)" \
  '(^|[^[:alnum:]_])INFOPLIST_(FILE|PREPROCESS)[[:space:]]*=|GENERATE_INFOPLIST_FILE[[:space:]]*=[[:space:]]*NO'

list_files 'Package.swift'
scan "Dépendance de package distante interdite (.package(url:) / url:)" \
  '\.package[[:space:]]*\([[:space:]]*url[[:space:]]*:|(^|[^[:alnum:]_])url[[:space:]]*:[[:space:]]*"'

list_files 'Package.resolved'
scan "Package.resolved avec des pins (dépendances verrouillées)" '"identity"|"location"|"repositoryURL"'

# 3. Entitlements, capabilities, ATS, arrière-plan, permissions ---------------------
list_files '*.entitlements'
if [ ${#LIST[@]} -gt 0 ]; then
  fail "Fichier d'entitlements inattendu (aucune capability autorisée) :"
  printf '%s\n' "${LIST[@]}"
fi

list_files '*.pbxproj' '*.plist' '*.xcconfig'
scan "Réglage réseau, capability ou entitlement interdit" \
  'NSBonjourServices|SystemCapabilities|aps-environment|[iI][cC]loud|CODE_SIGN_ENTITLEMENTS|NSAppTransportSecurity|NSAllowsArbitraryLoads|UIBackgroundModes|com\.apple\.developer\.'

# Plists : format texte imposé (sinon les scans textuels seraient aveugles).
list_files '*.plist'
check_plist_format

# Permissions : seule NSCameraUsageDescription (exception P2), dans *.pbxproj / *.plist uniquement.
list_files '*.pbxproj' '*.plist'
scan_permissions "Permission interdite (seule NSCameraUsageDescription est admise, exception P2)"
list_files '*.xcconfig'
scan "Permission interdite dans un .xcconfig (clé caméra admise seulement dans le projet ou un Info.plist)" \
  'UsageDescription'

# Bilan --------------------------------------------------------------------------
if [ "$failures" -gt 0 ]; then
  echo "ÉCHEC : $failures contrôle(s) en défaut (politique hors ligne, cahier des charges §7)."
  exit 1
fi
echo "OK : ${swift_count} fichiers Swift analysés ; aucune API réseau, URL distante, dépendance ni entitlement ; aucune permission hors appareil photo (exception P2)."
