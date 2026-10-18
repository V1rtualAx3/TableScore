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

[ "$failed" -eq 0 ] && echo "OK : tous les cas de non-régression passent." || { echo "ÉCHEC"; exit 1; }
