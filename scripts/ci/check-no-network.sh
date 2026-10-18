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
  out="$(grep -nHE"${opts#-}" -- "$re" "${LIST[@]}")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$desc"
    echo "$out"
  elif [ "$rc" -gt 1 ]; then
    fail "grep a échoué (code $rc) pour : $desc"
  fi
}

# 1. Sources Swift ------------------------------------------------------------
list_files '*.swift'
if [ ${#LIST[@]} -eq 0 ]; then
  fail "Aucun fichier Swift trouvé : contrôle inopérant."
fi
swift_count=${#LIST[@]}

api_re='URLSession|URLRequest|NSURLConnection|NSURLSession|CFNetwork|CFStream|CFSocket|NWConnection|NWListener|NWBrowser|NWPathMonitor|WKWebView|WKNavigation|SFSafariViewController|ASWebAuthenticationSession|AsyncImage|CKContainer|CKDatabase|CKRecord|getaddrinfo|socket[[:space:]]*\(|contentsOf:|openURL|(^|[^[:alnum:]_])Link[[:space:]]*\(|UIApplication\.shared\.open|MCSession|GKLocalPlayer|SKPaymentQueue|ASIdentifierManager|ATTrackingManager'
scan "API réseau/sortie externe interdite (sources Swift)" "$api_re"

import_re='(^|[^[:alnum:]_])import[[:space:]]+([A-Za-z]+[[:space:]]+)?(Network|NetworkExtension|WebKit|SafariServices|CloudKit|MultipeerConnectivity|GameKit|StoreKit|AdSupport|AppTrackingTransparency|AuthenticationServices|MapKit|CFNetwork|Alamofire|Firebase[A-Za-z]*|Sentry)([^[:alnum:]_]|$)'
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
scan "Réglage réseau, permission, capability ou entitlement interdit" \
  'UsageDescription|NSBonjourServices|SystemCapabilities|aps-environment|[iI][cC]loud|CODE_SIGN_ENTITLEMENTS|NSAppTransportSecurity|NSAllowsArbitraryLoads|UIBackgroundModes|com\.apple\.developer\.'

# Bilan --------------------------------------------------------------------------
if [ "$failures" -gt 0 ]; then
  echo "ÉCHEC : $failures contrôle(s) en défaut (politique hors ligne, cahier des charges §7)."
  exit 1
fi
echo "OK : ${swift_count} fichiers Swift analysés ; aucune API réseau, URL distante, dépendance, entitlement ni permission."
