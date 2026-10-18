#!/usr/bin/env bash
# Inspection binaire de TableScore.app (complète le contrôle statique, qui reste heuristique).
#
# Usage : check-binary.sh DERIVED_DATA_PATH
#
# Cibles : exécutable principal et dylib de premier niveau du bundle (en Debug, Xcode 16
# place le code dans TableScore.debug.dylib). PlugIns/ et Frameworks/ (XCTest...) sont
# ignorés pour éviter les faux positifs liés à l'outillage de test.
#  - otool -L (dépendances directes) : Network, WebKit, SafariServices, Photos, PhotosUI, VisionKit
#    BLOQUANTS (prototype P2 caméra : ni photothèque ni VisionKit) ;
#    CFNetwork INFORMATIF (peut être tiré indirectement par des frameworks système).
#  - nm -u (symboles non résolus) : URLSession/NSURLSession, nw_connection, WKWebView BLOQUANTS.
# Variables OTOOL / NM permettent de substituer les outils (tests de la logique hors macOS).
set -euo pipefail

dd="${1:?Usage: check-binary.sh DERIVED_DATA_PATH}"
otool_bin="${OTOOL:-otool}"
nm_bin="${NM:-nm}"
products="$dd/Build/Products"

apps=()
while IFS= read -r -d '' a; do apps+=("$a"); done < <(find "$products" -type d -name 'TableScore.app' -print0 2>/dev/null)
if [ ${#apps[@]} -ne 1 ]; then
  echo "::error::Attendu exactement un TableScore.app sous $products, trouvé ${#apps[@]}."
  exit 1
fi
app="${apps[0]}"
echo "Bundle inspecté : $app"

targets=()
if [ ! -f "$app/TableScore" ]; then
  echo "::error::Exécutable $app/TableScore introuvable."
  exit 1
fi
targets+=("$app/TableScore")
while IFS= read -r -d '' d; do targets+=("$d"); done < <(find "$app" -maxdepth 1 -type f -name '*.dylib' -print0)

failures=0
for bin in "${targets[@]}"; do
  echo "--- $bin"
  libs="$("$otool_bin" -L "$bin")"
  echo "$libs"
  if echo "$libs" | grep -E '/(Network|WebKit|SafariServices|Photos|PhotosUI|VisionKit)\.framework/'; then
    echo "::error::Framework réseau/Web/photothèque/VisionKit lié directement : $bin"
    failures=$((failures + 1))
  fi
  if echo "$libs" | grep -E '/CFNetwork\.framework/'; then
    echo "::warning::CFNetwork lié directement (informatif, à examiner) : $bin"
  fi
  syms="$("$nm_bin" -u "$bin")"
  if echo "$syms" | grep -E 'URLSession|nw_connection|WKWebView'; then
    echo "::error::Symbole réseau/Web non résolu : $bin"
    failures=$((failures + 1))
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "ÉCHEC : inspection binaire en défaut ($failures)."
  exit 1
fi
echo "OK : aucune dépendance Network/WebKit/SafariServices/Photos/PhotosUI/VisionKit ni symbole URLSession/nw_connection/WKWebView."
