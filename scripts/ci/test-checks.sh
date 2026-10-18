#!/usr/bin/env bash
# Non-régression du contrôle zéro réseau : chaque fixture négative doit échouer en
# signalant chacun de ses motifs ; la fixture « clean » doit réussir.
# Usage : test-checks.sh   (depuis n'importe où)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
check="$here/check-no-network.sh"
failed=0

expect_fail() { # fixture marqueur...
  local name="$1" out rc=0 m; shift
  out="$(bash "$check" "$here/fixtures/$name" 2>&1)" || rc=$?
  if [ "$rc" -ne 1 ]; then echo "KO  $name : code $rc au lieu de 1"; failed=1; return; fi
  for m in "$@"; do
    if ! grep -qF -- "$m" <<<"$out"; then echo "KO  $name : motif non détecté : $m"; failed=1; fi
  done
  echo "ok  $name"
}

out="$(bash "$check" "$here/fixtures/clean" 2>&1)" || { echo "KO  clean : $out"; failed=1; }
echo "ok  clean"

expect_fail swift-api 'URLSession.shared' 'URLRequest' 'NSURLConnection' 'CFNetworkCopy' 'CFStreamCreate' \
  'NWConnection' 'WKWebView' 'AsyncImage' 'contentsOf:' 'socket(' 'getaddrinfo' 'openURL' 'Link("x"' 'UIApplication.shared.open'
expect_fail swift-imports 'import Network' 'import WebKit' 'import SafariServices' 'import MultipeerConnectivity' \
  'import GameKit' 'import StoreKit' 'import AdSupport' 'import AppTrackingTransparency' \
  'import AuthenticationServices' 'import MapKit' 'import CFNetwork' 'import struct Network.NWEndpoint'
expect_fail swift-url 'Bad.swift:1:' 'Bad.swift:3:' 'HTTPS://' 'Wss://' 'FTP://'
expect_fail native-code 'a.m' 'b.mm' 'c.c' 'd.cpp' 'e.h'
expect_fail pbxproj 'XCRemoteSwiftPackageReference' 'repositoryURL' 'PBXShellScriptBuildPhase'
expect_fail package-swift '.package(url:'
expect_fail package-resolved 'identity'
expect_fail config 'NSCameraUsageDescription' 'NSBonjourServices' 'NSAppTransportSecurity' 'UIBackgroundModes' \
  'aps-environment' 'com.apple.developer.icloud-services' 'SystemCapabilities' 'CODE_SIGN_ENTITLEMENTS'
expect_fail entitlements 'App.entitlements'
expect_fail cloudkit 'cloudKitDatabase: .automatic' 'cloudKitDatabase:.private' 'import CloudKit'

# --- check-binary.sh / check-release-symbols.sh : logique testée avec des outils factices ---
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
stubs="$tmp/stubs"; mkdir -p "$stubs"
printf '#!/usr/bin/env bash\ncat "${STUB_NM_FILE:-/dev/null}"\n' >"$stubs/nm"
printf '#!/usr/bin/env bash\ncat "${STUB_STRINGS_FILE:-/dev/null}"\n' >"$stubs/strings"
printf '#!/usr/bin/env bash\necho "$1"\n' >"$stubs/otool"
chmod +x "$stubs"/nm "$stubs"/strings "$stubs"/otool
mkdir -p "$tmp/dd/Build/Products/Release-iphonesimulator/TableScore.app"
: >"$tmp/dd/Build/Products/Release-iphonesimulator/TableScore.app/TableScore"

run_symbols() { # nm_content strings_content -> code dans rc, sortie dans out
  printf '%s\n' "$1" >"$tmp/nm.txt"; printf '%s\n' "$2" >"$tmp/strings.txt"
  rc=0
  out="$(NM="$stubs/nm" STRINGS="$stubs/strings" STUB_NM_FILE="$tmp/nm.txt" STUB_STRINGS_FILE="$tmp/strings.txt" \
    bash "$here/check-release-symbols.sh" "$tmp/dd" 2>&1)" || rc=$?
}

run_symbols '_main
$s10TableScore7AppRootV' 'Hello'
if [ "$rc" -eq 0 ]; then echo "ok  release-symbols clean"; else echo "KO  release-symbols clean : $out"; failed=1; fi

for sym in UITestSeed previewEnvironment simulatesWriteFailure uiTestingPersistentStore resetUITestStore InMemoryGameRepository; do
  run_symbols "_main $sym" 'Hello'
  if [ "$rc" -eq 1 ] && grep -qF -- "::error::" <<<"$out" && grep -qF -- "$sym" <<<"$out"; then echo "ok  release-symbols nm $sym"; else echo "KO  release-symbols nm $sym (code $rc)"; failed=1; fi
  run_symbols '_main' "-$sym"
  if [ "$rc" -eq 1 ] && grep -qF -- "$sym" <<<"$out"; then echo "ok  release-symbols strings $sym"; else echo "KO  release-symbols strings $sym (code $rc)"; failed=1; fi
done

rc=0; out="$(bash "$here/check-release-symbols.sh" "$tmp/absent" 2>&1)" || rc=$?
if [ "$rc" -eq 1 ]; then echo "ok  release-symbols bundle absent"; else echo "KO  release-symbols bundle absent (code $rc)"; failed=1; fi

# check-binary.sh : symbole réseau non résolu bloquant, sinon OK.
printf '_main\n' >"$tmp/nm.txt"
rc=0; out="$(OTOOL="$stubs/otool" NM="$stubs/nm" STUB_NM_FILE="$tmp/nm.txt" bash "$here/check-binary.sh" "$tmp/dd" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then echo "ok  binary clean"; else echo "KO  binary clean : $out"; failed=1; fi
printf '_OBJC_CLASS_$_NSURLSession\n' >"$tmp/nm.txt"
rc=0; out="$(OTOOL="$stubs/otool" NM="$stubs/nm" STUB_NM_FILE="$tmp/nm.txt" bash "$here/check-binary.sh" "$tmp/dd" 2>&1)" || rc=$?
if [ "$rc" -eq 1 ]; then echo "ok  binary URLSession"; else echo "KO  binary URLSession (code $rc)"; failed=1; fi

[ "$failed" -eq 0 ] && echo "OK : tous les cas de non-régression passent." || { echo "ÉCHEC"; exit 1; }
