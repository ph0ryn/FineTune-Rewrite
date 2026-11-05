#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/FineTune-build-contract.XXXXXX")"
fixture="$scratch/Fixture.app"
mkdir -p "$fixture/Contents/MacOS" "$fixture/Contents/Resources" "$scratch/bin"
printf 'Build-contract artifacts: %s\n' "$scratch"

# A real universal executable, never launched. Only the expensive external Xcode builder is replaced.
printf 'int main(void) { return 0; }\n' > "$scratch/fixture.c"
xcrun --sdk macosx clang -arch arm64 -arch x86_64 -mmacosx-version-min=15.4 \
  "$scratch/fixture.c" -o "$fixture/Contents/MacOS/FineTuneRewrite"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict>' \
  '<key>CFBundleIdentifier</key><string>com.ph0ryn.FineTuneRewrite</string>' \
  '<key>CFBundleExecutable</key><string>FineTuneRewrite</string>' \
  '<key>CFBundlePackageType</key><string>APPL</string>' \
  '<key>CFBundleVersion</key><string>1</string>' \
  '<key>CFBundleShortVersionString</key><string>0.1.0</string>' \
  '</dict></plist>' > "$fixture/Contents/Info.plist"
printf 'A sealed resource.\n' > "$fixture/Contents/Resources/contract.txt"

cat > "$scratch/bin/xcodebuild" <<'BUILDER'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${BUILD_APP_TEST_BUILDER_FAILURE:-0} != 0 ]]; then
  exit "$BUILD_APP_TEST_BUILDER_FAILURE"
fi
configuration= derived_data=
while (( $# )); do
  case "$1" in
    -configuration) configuration="$2"; shift 2 ;;
    -derivedDataPath) derived_data="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$configuration" && -n "$derived_data" ]]
/usr/bin/ditto "${BUILD_APP_TEST_FIXTURE:?}" \
  "$derived_data/Build/Products/$configuration/FineTuneRewrite.app"
BUILDER
# A regression must fail rather than accidentally launch even the harmless fixture.
printf '#!/usr/bin/env bash\nexit 90\n' > "$scratch/bin/open"
chmod +x "$scratch/bin/xcodebuild" "$scratch/bin/open"
export PATH="$scratch/bin:$PATH"
export BUILD_APP_TEST_FIXTURE="$fixture"

failures=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

for configuration in Debug Release; do
  derived_data="$scratch/$configuration output with spaces"
  if ! bash "$root/build.sh" "$configuration" "$derived_data"; then
    fail "$configuration build CLI must succeed before inspecting its artifact"
    continue
  fi
  app="$derived_data/Build/Products/$configuration/FineTuneRewrite.app"
  signature="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)" || true
  [[ "$signature" == *'Identifier=com.ph0ryn.FineTuneRewrite'* ]] \
    || fail "$configuration code identity must match the app bundle identifier"
  [[ "$signature" == *'Info.plist entries='* ]] \
    || fail "$configuration Info.plist must be bound into the signature"
  [[ "$signature" == *'Sealed Resources version='* ]] \
    || fail "$configuration resources must be sealed"
  if ! /usr/bin/codesign --verify --strict --all-architectures "$app"; then
    fail "$configuration output must pass strict verification for every architecture"
  fi

  if [[ "$configuration" == Debug ]]; then
    /usr/libexec/PlistBuddy -c 'Add :BuildContractProbe string changed' "$app/Contents/Info.plist"
  else
    printf 'Tampered.\n' >> "$app/Contents/Resources/contract.txt"
  fi
  if /usr/bin/codesign --verify --strict --all-architectures "$app" > "$scratch/$configuration-tamper.log" 2>&1; then
    fail "$configuration signature must detect changed Info.plist or resource contents"
  fi
done

# A failed builder must remain a failed CLI, not become a successful signing-only invocation.
status=0
BUILD_APP_TEST_BUILDER_FAILURE=23 bash "$root/build.sh" release "$scratch/failed output" \
  > "$scratch/builder-failure.log" 2>&1 || status=$?
[[ "$status" == 23 ]] || fail "builder failure must propagate unchanged (received $status)"
[[ ! -e "$scratch/failed output/Build/Products/Release/FineTuneRewrite.app" ]] \
  || fail 'builder failure must not publish an app artifact'

if (( failures )); then
  printf '%s artifact-contract assertion(s) failed.\n' "$failures" >&2
  exit 1
fi
printf 'PASS: Debug/Release app identity, Info/resource seals, all architectures, tamper detection and builder failure.\n'
