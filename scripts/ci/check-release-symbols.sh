#!/usr/bin/env bash
# Contrôle du binaire RELEASE : aucun code/identifiant de test, de fixture ou de preview ne doit
# subsister dans le produit distribuable.
#
# Usage : check-release-symbols.sh DERIVED_DATA_PATH
#
# Cibles : exécutable principal et dylib de premier niveau de TableScore.app (comme check-binary.sh).
# Sorties inspectées : `nm` (symboles, y compris locaux) et `strings -a` (chaînes littérales).
#  - BLOQUANTS : UITestSeed, previewEnvironment, simulatesWriteFailure, uiTestingPersistentStore,
#    resetUITestStore, InMemoryGameRepository, CardScanFixture, scanFixture, uiTestingAppearance,
#    UITestAppearanceOverride (tout cela doit être sous `#if DEBUG`).
# Variables NM / STRINGS permettent de substituer les outils (tests de la logique hors macOS).
set -euo pipefail

dd="${1:?Usage: check-release-symbols.sh DERIVED_DATA_PATH}"
nm_bin="${NM:-nm}"
strings_bin="${STRINGS:-strings}"
products="$dd/Build/Products"

blocking=(UITestSeed previewEnvironment simulatesWriteFailure uiTestingPersistentStore resetUITestStore InMemoryGameRepository CardScanFixture scanFixture uiTestingAppearance UITestAppearanceOverride)

apps=()
while IFS= read -r -d '' a; do apps+=("$a"); done < <(find "$products" -type d -name 'TableScore.app' -print0 2>/dev/null)
if [ ${#apps[@]} -ne 1 ]; then
  echo "::error::Attendu exactement un TableScore.app sous $products, trouvé ${#apps[@]}."
  exit 1
fi
app="${apps[0]}"
echo "Bundle Release inspecté : $app"

if [ ! -f "$app/TableScore" ]; then
  echo "::error::Exécutable $app/TableScore introuvable."
  exit 1
fi
targets=("$app/TableScore")
while IFS= read -r -d '' d; do targets+=("$d"); done < <(find "$app" -maxdepth 1 -type f -name '*.dylib' -print0)

failures=0
for bin in "${targets[@]}"; do
  echo "--- $bin"
  # Aucune tolérance d'erreur : un échec de nm/strings fait échouer le contrôle (set -e).
  dump="$("$nm_bin" -a "$bin")
$("$strings_bin" -a "$bin")"
  for pattern in "${blocking[@]}"; do
    if grep -F -- "$pattern" <<<"$dump" >/dev/null; then
      echo "::error::Identifiant de test/preview présent dans le binaire Release ($pattern) : $bin"
      failures=$((failures + 1))
    fi
  done
done

if [ "$failures" -gt 0 ]; then
  echo "ÉCHEC : identifiants de test/preview dans le binaire Release ($failures)."
  exit 1
fi
echo "OK : aucun identifiant de test, de fixture ou de preview bloquant dans le binaire Release."
