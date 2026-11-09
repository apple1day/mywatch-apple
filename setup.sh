#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
open_project=true
case "${1:-}" in
  --no-open) open_project=false ;;
  -h|--help)
    cat <<'HELP'
Usage: bash setup.sh [--no-open]

On macOS with full Xcode, generate WatchLink.xcodeproj and open it.
The script installs XcodeGen if Homebrew is already available.
Existing app, unit-test and UI-test signing settings are preserved locally.
After opening, select your Team and an iPhone in Xcode, then Run.
HELP
    exit 0 ;;
  "") ;;
  *) printf 'Unknown option. Use bash setup.sh --help.\n' >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then printf 'Only one optional argument is supported.\n' >&2; exit 2; fi
if [[ "$(uname -s)" != Darwin ]]; then
  printf 'This iOS project requires macOS and full Xcode to build.\n' >&2
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  printf 'Install/open full Xcode and select it with xcode-select before running setup.\n' >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'Python 3 is required to preserve existing Xcode signing settings.\n' >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    printf 'Install XcodeGen (https://github.com/yonaskolb/XcodeGen), then rerun setup.\n' >&2
    exit 1
  fi
  HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen
fi

cd "$project_root"
mkdir -p Config
if [[ ! -f Config/Signing.local.xcconfig ]]; then
  cp Config/Signing.example.xcconfig Config/Signing.local.xcconfig
fi
python3 scripts/preserve-signing.py WatchLink.xcodeproj/project.pbxproj Config
xcodegen generate --spec project.yml
printf '\nReady: %s/WatchLink.xcodeproj\nSelect a signing Team in Xcode to install on your iPhone.\n' "$project_root"
if [[ "$open_project" == true ]]; then open "$project_root/WatchLink.xcodeproj"; fi
