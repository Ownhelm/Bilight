#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-test}"
destination="${BILIGHT_DESTINATION:-platform=iOS Simulator,name=iPhone 18 Pro}"
common=(-project Bilight.xcodeproj -configuration Debug -sdk iphonesimulator -destination "$destination" -derivedDataPath .build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES)
case "$mode" in
  test) xcodebuild "${common[@]}" -scheme Bilight test ;;
  live) xcodebuild "${common[@]}" -scheme BilightLiveSmoke -only-testing:BilightTests/LiveSmokeTests test ;;
  build) xcodebuild "${common[@]}" -scheme Bilight build ;;
  archive)
    xcodebuild -project Bilight.xcodeproj -scheme Bilight -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath .build/device -archivePath .artifacts/Bilight-unsigned.xcarchive CODE_SIGNING_ALLOWED=NO archive
    ;;
  *) echo 'Usage: bash ios/scripts/verify.sh {test|live|build|archive}' >&2; exit 2 ;;
esac
