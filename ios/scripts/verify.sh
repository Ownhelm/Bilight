#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-test}"
code_dir="$(cd .. && pwd)"
local_dir="${BILIGHT_LOCAL_DIR:-$(dirname "$code_dir")/Local}"
mkdir -p "$local_dir/Builds/iOS"
destination="${BILIGHT_DESTINATION:-platform=iOS Simulator,name=iPhone 18 Pro}"
common=(-project Bilight.xcodeproj -configuration Debug -sdk iphonesimulator -destination "$destination" -derivedDataPath "$local_dir/Builds/iOS" CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES)
case "$mode" in
  test) xcodebuild "${common[@]}" -scheme Bilight test ;;
  live) xcodebuild "${common[@]}" -scheme BilightLiveSmoke -only-testing:BilightTests/LiveSmokeTests test ;;
  build) xcodebuild "${common[@]}" -scheme Bilight build ;;
  archive)
    xcodebuild -project Bilight.xcodeproj -scheme Bilight -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$local_dir/Builds/iOS-device" -archivePath "$code_dir/releases/ios/Bilight-unsigned.xcarchive" CODE_SIGNING_ALLOWED=NO archive
    ;;
  *) echo 'Usage: bash ios/scripts/verify.sh {test|live|build|archive}' >&2; exit 2 ;;
esac
