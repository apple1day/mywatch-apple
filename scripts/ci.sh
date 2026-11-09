#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_root"
mkdir -p build dist

case "${1:-}" in
  test)
    python3 scripts/test-signing-preservation.py
    python3 scripts/run-bounded.py 120 xcrun simctl list devices available -j \
      > build/simulator-devices.json 2> build/simulator-list.log \
      || { result=$?; cat build/simulator-list.log >&2; exit "$result"; }
    cat build/simulator-list.log
    simulator_id="$(python3 scripts/select-simulator.py < build/simulator-devices.json)"
    printf 'Testing on iPhone simulator: %s\n' "$simulator_id"
    python3 scripts/run-bounded.py 420 xcrun simctl bootstatus "$simulator_id" -b \
      2>&1 | tee build/simulator-boot.log
    result_path="$project_root/build/TestResults.xcresult"
    if [[ -e "$result_path" ]]; then
      result_path="$project_root/build/TestResults-$(date +%Y%m%d-%H%M%S)-$$.xcresult"
    fi
    printf '%s\n' "$result_path" > build/test-result-path.txt
    xcodebuild test -project WatchLink.xcodeproj -scheme WatchLink -configuration Debug \
      -destination "platform=iOS Simulator,id=$simulator_id" -destination-timeout 60 \
      -derivedDataPath build/Simulator -resultBundlePath "$result_path" \
      -parallel-testing-enabled NO -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 120 \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
      | tee build/simulator-test.log
    simulator_app="$project_root/build/Simulator/Build/Products/Debug-iphonesimulator/WatchLink.app"
    [[ -d "$simulator_app" ]] || { printf 'Simulator app missing after successful test.\n' >&2; exit 1; }
    ditto -c -k --sequesterRsrc --keepParent "$simulator_app" dist/WatchLink-iOS-simulator-0.2.1.zip
    ;;
  device)
    xcodebuild build -project WatchLink.xcodeproj -scheme WatchLink -configuration Release \
      -destination 'generic/platform=iOS' -sdk iphoneos -derivedDataPath build/Device \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
      | tee build/device-build.log
    device_app="$project_root/build/Device/Build/Products/Release-iphoneos/WatchLink.app"
    [[ -d "$device_app" ]] || { printf 'Device app missing after successful build.\n' >&2; exit 1; }
    ditto -c -k --sequesterRsrc --keepParent "$device_app" dist/WatchLink-iOS-unsigned-0.2.1.zip
    cat > dist/BUILD-ARTIFACTS.txt <<'INFO'
WatchLink 0.2.1 build artifacts

WatchLink-iOS-simulator-0.2.1.zip contains an iOS Simulator app.
WatchLink-iOS-unsigned-0.2.1.zip contains an UNSIGNED physical-device app.
The device and simulator ZIPs are published as separate CI artifacts.

Neither file is a signed IPA for direct installation on an iPhone.
To install on your own iPhone, clone the repository on a Mac, run
bash setup.sh, select your signing Team and connected iPhone in Xcode,
then Run. No Apple account credentials or signing private keys are in CI.

Build/test success does not establish Bluetooth interoperability with a watch.
INFO
    (cd dist && shasum -a 256 ./*.zip > SHA256SUMS.txt)
    ;;
  attachments)
    if [[ -f build/test-result-path.txt ]]; then
      result_path="$(cat build/test-result-path.txt)"
      if [[ -d "$result_path" ]]; then
        xcrun xcresulttool export attachments --path "$result_path" --output-path build/TestAttachments
      fi
    fi
    ;;
  *) printf 'Usage: bash scripts/ci.sh {test|device|attachments}\n' >&2; exit 2 ;;
esac
