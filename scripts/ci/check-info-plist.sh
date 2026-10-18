#!/usr/bin/env bash
# Contrôle de l'Info.plist RÉELLEMENT produit dans TableScore.app (complète le contrôle textuel
# de check-no-network.sh, qui ne voit que les sources).
#
# Usage : check-info-plist.sh DERIVED_DATA_PATH
#   Exactement un TableScore.app sous DERIVED_DATA_PATH/Build/Products (Debug ou Release selon le
#   dossier passé).
#
# BLOQUANTS :
#  - toute clé *UsageDescription autre que NSCameraUsageDescription (exception P2 « Scanner les
#    cartes », décision utilisateur du 2026-10-18) ;
#  - NSAppTransportSecurity, UIBackgroundModes, NSBonjourServices, NSLocalNetworkUsageDescription ;
#  - NSCameraUsageDescription présente mais vide ou non textuelle ;
#  - Info.plist absent, illisible ou dont la racine n'est pas un dictionnaire.
# Conversion : `plutil -convert xml1 -o - Info.plist` (XML ou binaire en entrée), puis analyse
# awk POSIX (ni jq ni python : absents du job Linux). Hypothèse documentée : la sortie xml1 de
# plutil place une balise <key>…</key> par ligne et la valeur scalaire sur la ligne suivante.
# Variable PLUTIL : substitution de l'outil (tests de la logique hors macOS).
set -euo pipefail

dd="${1:?Usage: check-info-plist.sh DERIVED_DATA_PATH}"
plutil_bin="${PLUTIL:-plutil}"
products="$dd/Build/Products"

apps=()
while IFS= read -r -d '' a; do apps+=("$a"); done < <(find "$products" -type d -name 'TableScore.app' -print0 2>/dev/null)
if [ ${#apps[@]} -ne 1 ]; then
  echo "::error::Attendu exactement un TableScore.app sous $products, trouvé ${#apps[@]}."
  exit 1
fi
plist="${apps[0]}/Info.plist"
echo "Info.plist inspecté : $plist"
if [ ! -f "$plist" ]; then
  echo "::error::Info.plist introuvable : $plist"
  exit 1
fi

# Aucune tolérance : un échec de conversion fait échouer le contrôle.
if ! xml="$("$plutil_bin" -convert xml1 -o - "$plist")"; then
  echo "::error::Info.plist illisible (plutil en échec) : $plist"
  exit 1
fi

# Sortie awk : lignes « ROOT », « FORBIDDEN <clé> » ou « CAMERA ».
report="$(awk '
  function trim(x) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", x); return x }
  BEGIN { inplist = 0; rootseen = 0; cam = 0; camok = 0 }
  {
    line = trim($0)
    if (cam) {                       # ligne suivant NSCameraUsageDescription
      cam = 0
      if (line ~ /^<string>/) {
        v = line; sub(/^<string>/, "", v); sub(/<\/string>$/, "", v)
        if (trim(v) != "") camok = 1
      }
      if (!camok) print "CAMERA"
    }
    if (!rootseen) {
      if (line ~ /^<plist([ >]|$)/) inplist = 1
      else if (inplist && line != "") {
        rootseen = 1
        if (line !~ /^<dict(>|\/>)/) print "ROOT"
      }
    }
    if (line ~ /^<key>.*<\/key>$/) {
      k = line; sub(/^<key>/, "", k); sub(/<\/key>$/, "", k)
      if (k == "NSCameraUsageDescription") cam = 1
      else if (k ~ /UsageDescription$/ || k == "NSAppTransportSecurity" || k == "UIBackgroundModes" \
               || k == "NSBonjourServices" || k == "NSLocalNetworkUsageDescription") print "FORBIDDEN " k
    }
  }
  END {
    if (!rootseen) print "ROOT"
    if (cam) print "CAMERA"       # clé sans valeur
  }' <<<"$xml")"

failures=0
if grep -q '^ROOT$' <<<"$report"; then
  echo "::error::Info.plist illisible ou racine non dictionnaire : $plist"
  failures=$((failures + 1))
fi
forbidden="$(sed -n 's/^FORBIDDEN //p' <<<"$report")"
if [ -n "$forbidden" ]; then
  echo "::error::Clé(s) interdite(s) dans l'Info.plist produit :"
  echo "$forbidden"
  failures=$((failures + 1))
fi
if grep -q '^CAMERA$' <<<"$report"; then
  echo "::error::NSCameraUsageDescription vide ou non textuelle."
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "ÉCHEC : Info.plist produit non conforme ($failures)."
  exit 1
fi
echo "OK : Info.plist produit sans permission hors appareil photo, sans ATS, arrière-plan ni Bonjour."
