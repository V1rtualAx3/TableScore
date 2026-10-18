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

expect_ok() { # fixture : le contrôle doit réussir (code 0)
  local name="$1" out rc=0
  out="$(bash "$check" "$here/fixtures/$name" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then echo "KO  $name : code $rc au lieu de 0 : $out"; failed=1; return; fi
  echo "ok  $name"
}

expect_ok clean
# Exception P2 (2026-10-18) : appareil photo autorisé (clé NSCameraUsageDescription, AVFoundation, Vision).
expect_ok camera-ok

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
expect_fail config 'NSLocationWhenInUseUsageDescription' 'NSBonjourServices' 'NSAppTransportSecurity' 'UIBackgroundModes' \
  'aps-environment' 'com.apple.developer.icloud-services' 'SystemCapabilities' 'CODE_SIGN_ENTITLEMENTS'
expect_fail entitlements 'App.entitlements'
expect_fail cloudkit 'cloudKitDatabase: .automatic' 'cloudKitDatabase:.private' 'import CloudKit'
# Photothèque, micro, localisation refusés (même à côté de la clé caméra) ; clé caméra hors projet/plist refusée.
expect_fail photo-library 'NSPhotoLibraryUsageDescription' 'NSPhotoLibraryAddUsageDescription' \
  'NSMicrophoneUsageDescription' 'NSCameraUsageDescriptionExtra' 'NSLocationWhenInUseUsageDescription' \
  'Camera.xcconfig:1:INFOPLIST_KEY_NSCameraUsageDescription' 'import Photos' 'import PhotosUI' \
  'PHPhotoLibrary' 'UIImageWriteToSavedPhotosAlbum' 'PHPickerViewController' 'AVCaptureMovieFileOutput' 'AVAudioRecorder' \
  'fileDataRepresentation' 'CGImageDestinationCreateWithURL' 'jpegData' 'pngData' 'heicData' 'UIPasteboard' \
  'UIImagePickerController' 'MLModelCollection' 'import VisionKit' 'import Speech' 'import Translation'
# Plists illisibles par le contrôle textuel, Info.plist externe : refusés.
expect_fail plist-format 'bplist) interdit : ./bin.plist' 'BOM) interdit : ./utf16.plist' 'octet NUL' 'utf16le.plist' \
  'NSMicrophone&#85;sageDescription' 'CDATA[NSLocationWhenInUse' 'INFOPLIST_FILE = TableScore/Info.plist' \
  'GENERATE_INFOPLIST_FILE = NO'

# --- check-binary.sh / check-release-symbols.sh : logique testée avec des outils factices ---
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
stubs="$tmp/stubs"; mkdir -p "$stubs"
printf '#!/usr/bin/env bash\ncat "${STUB_NM_FILE:-/dev/null}"\n' >"$stubs/nm"
printf '#!/usr/bin/env bash\ncat "${STUB_STRINGS_FILE:-/dev/null}"\n' >"$stubs/strings"
printf '#!/usr/bin/env bash\nif [ -n "${STUB_OTOOL_FILE:-}" ]; then cat "$STUB_OTOOL_FILE"; else echo "$1"; fi\n' >"$stubs/otool"
printf '#!/usr/bin/env bash\n[ -n "${STUB_PLUTIL_FAIL:-}" ] && exit 1\ncat "${STUB_PLUTIL_FILE:-/dev/null}"\n' >"$stubs/plutil"
chmod +x "$stubs"/nm "$stubs"/strings "$stubs"/otool "$stubs"/plutil
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

for sym in UITestSeed previewEnvironment simulatesWriteFailure uiTestingPersistentStore resetUITestStore InMemoryGameRepository CardScanFixture scanFixture \
  uiTestingAppearance UITestAppearanceOverride; do
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
printf '_main\n' >"$tmp/nm.txt"
for fw in Photos PhotosUI VisionKit; do
  printf '\t/System/Library/Frameworks/%s.framework/%s (compatibility version 1.0.0)\n' "$fw" "$fw" >"$tmp/otool.txt"
  rc=0; out="$(OTOOL="$stubs/otool" NM="$stubs/nm" STUB_NM_FILE="$tmp/nm.txt" STUB_OTOOL_FILE="$tmp/otool.txt" \
    bash "$here/check-binary.sh" "$tmp/dd" 2>&1)" || rc=$?
  if [ "$rc" -eq 1 ] && grep -qF -- "::error::" <<<"$out"; then echo "ok  binary $fw"; else echo "KO  binary $fw (code $rc)"; failed=1; fi
done
printf '\t/System/Library/Frameworks/Vision.framework/Vision\n\t/System/Library/Frameworks/AVFoundation.framework/AVFoundation\n' >"$tmp/otool.txt"
rc=0; out="$(OTOOL="$stubs/otool" NM="$stubs/nm" STUB_NM_FILE="$tmp/nm.txt" STUB_OTOOL_FILE="$tmp/otool.txt" \
  bash "$here/check-binary.sh" "$tmp/dd" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then echo "ok  binary Vision/AVFoundation permis"; else echo "KO  binary Vision/AVFoundation : $out"; failed=1; fi

# --- check-info-plist.sh : plutil factice (renvoie du XML plist fourni), sans jq ---
plist_xml() { # corps_racine -> plist xml1 complet
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n%s\n</plist>\n' "$1"
}
run_plist() { # xml [variables...] -> code dans rc, sortie dans out
  local xml="$1"; shift
  printf '%s\n' "$xml" >"$tmp/plist.xml"
  : >"$tmp/dd/Build/Products/Release-iphonesimulator/TableScore.app/Info.plist"
  rc=0
  out="$(env PLUTIL="$stubs/plutil" STUB_PLUTIL_FILE="$tmp/plist.xml" "$@" bash "$here/check-info-plist.sh" "$tmp/dd" 2>&1)" || rc=$?
}
expect_plist_ok() { # nom xml [variables...]
  local name="$1"; shift
  run_plist "$@"
  if [ "$rc" -eq 0 ] && grep -qF -- "OK : Info.plist produit" <<<"$out"; then echo "ok  info-plist $name"; else echo "KO  info-plist $name (code $rc) : $out"; failed=1; fi
}
expect_plist_fail() { # nom message_attendu xml [variables...]
  local name="$1" msg="$2"; shift 2
  run_plist "$@"
  if [ "$rc" -eq 1 ] && grep -qF -- "$msg" <<<"$out"; then echo "ok  info-plist $name"; else echo "KO  info-plist $name (code $rc, message attendu : $msg) : $out"; failed=1; fi
}
d_open='<dict>'; d_close='</dict>'
expect_plist_ok "caméra seule" "$(plist_xml "$d_open
	<key>CFBundleDisplayName</key>
	<string>TableScore</string>
	<key>NSCameraUsageDescription</key>
	<string>TableScore utilise l appareil photo.</string>
$d_close")"
expect_plist_ok "sans permission" "$(plist_xml "$d_open
	<key>CFBundleDisplayName</key>
	<string>TableScore</string>
$d_close")"
expect_plist_fail "micro" "NSMicrophoneUsageDescription" "$(plist_xml "$d_open
	<key>NSCameraUsageDescription</key>
	<string>x</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>x</string>
$d_close")"
expect_plist_fail "photothèque" "NSPhotoLibraryUsageDescription" "$(plist_xml "$d_open
	<key>NSPhotoLibraryUsageDescription</key>
	<string>x</string>
$d_close")"
expect_plist_fail "réseau local" "NSLocalNetworkUsageDescription" "$(plist_xml "$d_open
	<key>NSLocalNetworkUsageDescription</key>
	<string>x</string>
$d_close")"
expect_plist_fail "ATS" "NSAppTransportSecurity" "$(plist_xml "$d_open
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
$d_close")"
expect_plist_fail "arrière-plan" "UIBackgroundModes" "$(plist_xml "$d_open
	<key>UIBackgroundModes</key>
	<array>
		<string>audio</string>
	</array>
$d_close")"
expect_plist_fail "Bonjour" "NSBonjourServices" "$(plist_xml "$d_open
	<key>NSBonjourServices</key>
	<array>
		<string>_x._tcp</string>
	</array>
$d_close")"
expect_plist_fail "caméra vide" "NSCameraUsageDescription vide" "$(plist_xml "$d_open
	<key>NSCameraUsageDescription</key>
	<string>  </string>
$d_close")"
expect_plist_fail "caméra chaîne vide" "NSCameraUsageDescription vide" "$(plist_xml "$d_open
	<key>NSCameraUsageDescription</key>
	<string></string>
$d_close")"
expect_plist_fail "caméra non textuelle" "NSCameraUsageDescription vide" "$(plist_xml "$d_open
	<key>NSCameraUsageDescription</key>
	<true/>
$d_close")"
expect_plist_fail "racine non dictionnaire" "racine non dictionnaire" "$(plist_xml "<array>
	<string>NSCameraUsageDescription</string>
</array>")"
expect_plist_fail "plutil en échec" "plutil en échec" '' STUB_PLUTIL_FAIL=1
rc=0; out="$(PLUTIL="$stubs/plutil" bash "$here/check-info-plist.sh" "$tmp/absent" 2>&1)" || rc=$?
if [ "$rc" -eq 1 ] && grep -qF -- "Attendu exactement un TableScore.app" <<<"$out"; then echo "ok  info-plist bundle absent"; else echo "KO  info-plist bundle absent (code $rc)"; failed=1; fi

[ "$failed" -eq 0 ] && echo "OK : tous les cas de non-régression passent." || { echo "ÉCHEC"; exit 1; }
