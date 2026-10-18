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
# Conversion : `plutil -convert json -o - Info.plist` (XML ou binaire), analyse par `jq`.
# Variables PLUTIL / JQ permettent de substituer les outils (tests de la logique hors macOS).
set -euo pipefail

dd="${1:?Usage: check-info-plist.sh DERIVED_DATA_PATH}"
plutil_bin="${PLUTIL:-plutil}"
jq_bin="${JQ:-jq}"
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

# Aucune tolérance : un échec de conversion fait échouer le contrôle (set -e).
json="$("$plutil_bin" -convert json -o - "$plist")"
if ! "$jq_bin" -e 'type == "object"' >/dev/null <<<"$json"; then
  echo "::error::Info.plist illisible ou racine non dictionnaire : $plist"
  exit 1
fi

failures=0
forbidden="$("$jq_bin" -r '
  keys[]
  | select(
      (endswith("UsageDescription") and . != "NSCameraUsageDescription")
      or . == "NSAppTransportSecurity" or . == "UIBackgroundModes"
      or . == "NSBonjourServices" or . == "NSLocalNetworkUsageDescription"
    )' <<<"$json")"
if [ -n "$forbidden" ]; then
  echo "::error::Clé(s) interdite(s) dans l'Info.plist produit :"
  echo "$forbidden"
  failures=$((failures + 1))
fi

if ! "$jq_bin" -e '
  if has("NSCameraUsageDescription")
  then (.NSCameraUsageDescription | type == "string" and (gsub("\\s"; "") | length) > 0)
  else true end' >/dev/null <<<"$json"; then
  echo "::error::NSCameraUsageDescription vide ou non textuelle."
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "ÉCHEC : Info.plist produit non conforme ($failures)."
  exit 1
fi
echo "OK : Info.plist produit sans permission hors appareil photo, sans ATS, arrière-plan ni Bonjour."
