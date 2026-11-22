#!/usr/bin/env bash
set -euo pipefail

if (( $# > 2 )); then
  printf 'Usage: bash build.sh [debug|release] [derived-data-path]\n' >&2
  exit 64
fi

case "${1:-debug}" in
  debug|Debug) configuration=Debug ;;
  release|Release) configuration=Release ;;
  *) printf 'Expected debug or release configuration.\n' >&2; exit 64 ;;
esac

derived_data="${2:-DerivedData}"
project="$(dirname "${BASH_SOURCE[0]}")/FineTune.xcodeproj"

# Keep Xcode account-based signing disabled; finalize the whole local bundle below.
# Never launch the app, request permissions, or update signing accounts here.
xcodebuild build \
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

app="$derived_data/Build/Products/$configuration/FineTuneRewrite.app"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict --all-architectures "$app"
