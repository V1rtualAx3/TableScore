#!/usr/bin/env bash
# Exporte les captures d'écran des tests UI (TableScoreUITests/ScreenshotTests.swift) d'un
# résultat de tests .xcresult vers un dossier de fichiers image nommés « NN-ecran-theme.ext ».
#
# Usage : export-screenshots.sh RESULT_BUNDLE.xcresult OUTPUT_DIR
#
# Commande Xcode 16.x employée (sous-commande native, sans option « legacy ») :
#   xcrun xcresulttool export attachments --path RESULT_BUNDLE --output-path DIR_TEMPORAIRE
# Elle écrit un fichier par pièce jointe (noms opaques) et un « manifest.json » associant à chacun
# son nom lisible (suggestedHumanReadableName : nom de l'attachement suivi de « _<n>_<UUID> »).
# Le script ne conserve que les attachements nommés « NN-... -clair|-sombre|-ax3 » : les captures
# automatiques de XCTest, enregistrements et pièces « audit-... » (échecs seulement) sont ignorés.
#
# Échec EXPLICITE (code 1, annotation ::error::) si : le bundle est absent, l'export échoue, le
# manifeste est absent ou illisible, aucune capture n'est retenue, une capture est vide, ou moins de
# MIN_CAPTURES captures sont trouvées (défaut 34 = 15 écrans x 2 thèmes + 4 écrans en AX3).
#
# Variables : MIN_CAPTURES (nombre minimal attendu) ; XCRESULTTOOL (commande à la place de
# « xcrun xcresulttool », pour tester la logique hors macOS).
set -euo pipefail

bundle="${1:?Usage: export-screenshots.sh RESULT_BUNDLE.xcresult OUTPUT_DIR}"
out="${2:?Usage: export-screenshots.sh RESULT_BUNDLE.xcresult OUTPUT_DIR}"
min="${MIN_CAPTURES:-34}"
read -r -a tool <<< "${XCRESULTTOOL:-xcrun xcresulttool}"

fail() {
  echo "::error::$1"
  exit 1
}

[ -d "$bundle" ] || fail "Résultat de tests introuvable : $bundle"

raw="$(mktemp -d)"
trap 'rm -rf "$raw"' EXIT

echo "Export des pièces jointes de $bundle"
"${tool[@]}" export attachments --path "$bundle" --output-path "$raw" \
  || fail "xcresulttool export attachments a échoué."

manifest="$raw/manifest.json"
[ -f "$manifest" ] || fail "manifest.json absent de l'export (format xcresulttool inattendu)."

mkdir -p "$out"
rows="$(jq -r '
  (if type == "array" then .[] else . end)
  | .attachments[]?
  | [.exportedFileName, (.suggestedHumanReadableName // .exportedFileName)]
  | @tsv' "$manifest")" || fail "manifest.json illisible ou de structure inattendue."

count=0
while IFS=$'\t' read -r file human; do
  [ -n "${file:-}" ] || continue
  ext="png"
  case "$file" in *.*) ext="${file##*.}" ;; esac
  base="${human%.$ext}"
  # Retire le suffixe « _<n>_<UUID> » ajouté par Xcode au nom de l'attachement.
  base="$(printf '%s' "$base" | sed -E 's/_[0-9]+_[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$//')"
  if ! [[ "$base" =~ ^[0-9]{2}-[a-z0-9-]+-(clair|sombre|ax3)$ ]]; then
    continue
  fi
  dest="$out/$base.$ext"
  if [ -e "$dest" ]; then
    echo "::warning::Capture en double ignorée : $base"
    continue
  fi
  [ -s "$raw/$file" ] || fail "Capture vide : $base ($file)."
  cp "$raw/$file" "$dest"
  count=$((count + 1))
done <<< "$rows"

echo "Captures exportées : $count (minimum attendu : $min)"
[ "$count" -gt 0 ] || fail "Aucune capture d'écran dans le résultat de tests (export vide)."
[ "$count" -ge "$min" ] || fail "Seulement $count capture(s) sur $min attendues : parcours incomplet."
ls -1 "$out"
