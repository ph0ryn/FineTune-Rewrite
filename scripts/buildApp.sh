#!/usr/bin/env bash
set -euo pipefail

if (( $# > 2 )); then
  printf 'Usage: bash scripts/buildApp.sh [debug|release] [derived-data-path]\n' >&2
  exit 64
fi

case "${1:-debug}" in
  debug|Debug) configuration=Debug ;;
  release|Release) configuration=Release ;;
  *) printf 'Expected debug or release configuration.\n' >&2; exit 64 ;;
esac

derived_data="${2:-DerivedData}"
project="$(dirname "${BASH_SOURCE[0]}")/../FineTune.xcodeproj"

# Opt-in only: Xcode registers macOS app bundles even when signing is disabled.
# Never launch the app, request permissions, or update signing accounts here.
printf '%s\n' \
  'This Xcode build registers the output with LaunchServices and execution policy.' \
  'It does not launch the app. Use just check to validate shared sources without an app bundle.' >&2
exec xcodebuild build \
  -project "$project" \
  -scheme FineTuneRewrite \
  -configuration "$configuration" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$derived_data/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile \
  -jobs "${BUILD_JOBS:-2}" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
